//
// Copyright (c) 2019, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

`include "ofs_plat_if.vh"
`include "afu_json_info.vh"

`define SAFE_IDX(idx) (idx < NUM_ENGINES) ? idx : 0

//
// The CSR manager implements an MMIO master as the primary MMIO space.
//
// The CSR address space (in 64 bit words):
//
//   0x000 - OPAE AFU DFH (device feature header)
//   0x001 - OPAE AFU_ID_L (AFU ID low half)
//   0x002 - OPAE AFU_ID_H (AFU ID high half)
//
//   0x01? - CSR manager control space. The register interpretations are
//           described below.
//
//   0x02? - Global engine CSR space (16 read/write registers). The register
//           interpretations are determined by the AFU.
//
//   0x1?? - Individual engine CSR spaces (16 read/write registers
//           per engine). The low 4 bits are the register index within
//           an engine. Bits 7:4 are the engine index. The register
//           interpretations are determined by the engines.
//

//
// CSR manager control space (0x01?):
//
//  Writes:
//    0x010: Enable engines. Register value is a bit vector, one bit per
//           engine. Each bit enables a specific engine. The enable sequence
//           sets state_reset in each selected engine and then holds
//           state_run.
//
//    0x011: Disable engines. Clear state_run in the selected engines.
//
//  Reads:
//    0x010: Configuration details:
//             [63:16] undefined
//             [23: 8] pClk frequency (MHz)
//             [ 7: 0] number of engines
//    0x011: Engine run flags, one bit per engine.
//    0x012: Engine active flags, one bit per engine. An engine may be active
//           even if not running while outstanding requests are in flight.
//    0x013: Engine execution cycles in clk domain (primary AFU clock).
//    0x014: Engine execution cycles in pClk domain.
//

module csr_mgr
  #(
    parameter NUM_ENGINES = 1,
    parameter MMIO_ADDR_WIDTH = 16,
    parameter MMIO_DATA_WIDTH = 64
    )
   (
    input  logic clk,
    input  logic reset,
    // Passing in pClk allows us to compute the frequency of clk given a
    // known pClk frequency.
    input  logic pClk,

    // CSR read and write commands from the host
    input  logic wr_write,
    input  logic [MMIO_ADDR_WIDTH-1 : 0] wr_address,
    input  logic [MMIO_DATA_WIDTH-1 : 0] wr_writedata,

    input  logic rd_read,
    input  logic [MMIO_ADDR_WIDTH-1 : 0] rd_address,
    output logic rd_readdatavalid,
    output logic [MMIO_DATA_WIDTH-1 : 0] rd_readdata,

    // Global engine interface (write only)
    engine_csr_if.csr_mgr eng_csr_glob,

    // Individual engine CSRs
    engine_csr_if.csr_mgr eng_csr[NUM_ENGINES]
    );

    typedef logic [$clog2(NUM_ENGINES)-1 : 0] t_engine_idx;
    typedef logic [MMIO_ADDR_WIDTH-1 : 0] t_mmio_addr;
    typedef logic [MMIO_DATA_WIDTH-1 : 0] t_mmio_value;

    // The CSR manager uses only a subset of the MMIO space
    typedef logic [11:0] t_csr_idx;


    // The AFU ID is a unique ID for a given program.  Here we generated
    // one with the "uuidgen" program and stored it in the AFU's JSON file.
    // ASE and synthesis setup scripts automatically invoke afu_json_mgr
    // to extract the UUID into afu_json_info.vh.
    logic [127:0] afu_id = `AFU_ACCEL_UUID;

    typedef enum logic [1:0] {
        STATE_READY = 2'h0,
        STATE_HOLD_RESET = 2'h1,
        STATE_ENG_START = 2'h2
    } t_state;

    t_state state;

    logic [47:0] num_pClk_cycles, num_clk_cycles;


    // ====================================================================
    //
    // CSR read
    //
    // ====================================================================

    // In the first cycle of a read each engine's array of CSRs is reduced
    // to a single register. This splits the multiplexing into two cycles.
    logic read_req_q;
    t_csr_idx read_idx_q;
    t_mmio_value eng_csr_data_q[NUM_ENGINES];
    t_mmio_value eng_csr_glob_data_q;

    // Engine states
    logic [NUM_ENGINES-1 : 0] state_reset, state_run, status_active;

    genvar e;
    generate
        always_ff @(posedge clk)
        begin : r_addr
            read_req_q <= rd_read;
            read_idx_q <= t_csr_idx'(rd_address);

            if (reset)
            begin
                read_req_q <= 1'b0;
            end
        end

        // Reduce each individual engine's CSR read vector to the selected entry
        for (e = 0; e < NUM_ENGINES; e = e + 1)
        begin : r_eng_reduce
            always_ff @(posedge clk)
            begin
                eng_csr_data_q[e] <= eng_csr[e].rd_data[rd_address[3:0]];
                status_active[e] <= eng_csr[e].status_active;
            end
        end
    endgenerate

    // Reduce the global CSR read vector to the selected entry
    always_ff @(posedge clk)
    begin
        eng_csr_glob_data_q <= eng_csr_glob.rd_data[rd_address[3:0]];
    end

    // Reduce the mandatory feature header CSRs (read address 12'h00?)
    t_mmio_value dfh_afu_id_q;
    always_ff @(posedge clk)
    begin
        case (rd_address[3:0])
            4'h0: // AFU DFH (device feature header)
                begin
                    // Here we define a trivial feature list.  In this
                    // example, our AFU is the only entry in this list.
                    dfh_afu_id_q <= 64'b0;
                    // Feature type is AFU
                    dfh_afu_id_q[63:60] <= 4'h1;
                    // End of list (last entry in list)
                    dfh_afu_id_q[40] <= 1'b1;
                end

            // AFU_ID_L
            4'h1: dfh_afu_id_q <= afu_id[63:0];
            // AFU_ID_H
            4'h2: dfh_afu_id_q <= afu_id[127:64];
            default: dfh_afu_id_q <= 64'b0;
        endcase
    end

    // Reduce CSR manager control space (read address 12'h01?)
    t_mmio_value csr_mgr_ctrl_q;
    always_ff @(posedge clk)
    begin
        case (rd_address[3:0])
            4'h0: // Configuration details
                begin
                    csr_mgr_ctrl_q <= 64'b0;
                    // pClk frequency (MHz)
                    csr_mgr_ctrl_q[23:8] <= 16'(`OFS_PLAT_PARAM_CLOCKS_PCLK_FREQ);
                    // Number of engines
                    csr_mgr_ctrl_q[7:0] <= 8'(NUM_ENGINES);
                end
            4'h1: csr_mgr_ctrl_q <= 64'(state_run);
            4'h2: csr_mgr_ctrl_q <= 64'(status_active);
            4'h3: csr_mgr_ctrl_q <= 64'(num_clk_cycles);
            4'h4: csr_mgr_ctrl_q <= 64'(num_pClk_cycles);
            default: csr_mgr_ctrl_q <= 64'b0;
        endcase
    end

    // Second cycle selects from among the already reduced groups
    always_ff @(posedge clk)
    begin
        rd_readdatavalid <= read_req_q;

        casez (read_idx_q)
            // AFU DFH (device feature header) and AFU ID
            12'h00?: rd_readdata <= dfh_afu_id_q;

            // CSR manager control space
            12'h01?: rd_readdata <= csr_mgr_ctrl_q;

            // 16 registers in the global CSR space at 'h2?. The value
            // is sampled as soon as the read request arrives.
            12'h02?: rd_readdata <= eng_csr_glob_data_q;

            // 16 registers in each engine's CSR space at 'h1xy, where the 'x'
            // hex digit is the engine index and the 'y' hex digit is the
            // register number. The value is sampled as soon as the read
            // request arrives.
            12'h10?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(0)];
            12'h11?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(1)];
            12'h12?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(2)];
            12'h13?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(3)];
            12'h14?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(4)];
            12'h15?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(5)];
            12'h16?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(6)];
            12'h17?: rd_readdata <= eng_csr_data_q[`SAFE_IDX(7)];

            default: rd_readdata <= 64'h0;
        endcase // casez (read_idx_q)
    end


    // ====================================================================
    //
    // CSR write
    //
    // ====================================================================

    // Use explicit fanout with a two cycle CSR write

    //
    // Global engine CSRs (0x02?)
    //
    logic eng_csr_glob_wr_write;
    t_mmio_addr eng_csr_glob_wr_address;
    t_mmio_value eng_csr_glob_wr_writedata;

    always_ff @(posedge clk)
    begin
        eng_csr_glob_wr_write <= wr_write;
        eng_csr_glob_wr_address <= wr_address;
        eng_csr_glob_wr_writedata <= wr_writedata;

        eng_csr_glob.wr_req <= (eng_csr_glob_wr_write && (eng_csr_glob_wr_address[11:4] == 8'h02));
        eng_csr_glob.wr_idx <= eng_csr_glob_wr_address[3:0];
        eng_csr_glob.wr_data <= eng_csr_glob_wr_writedata;
    end


    //
    // Individual engine CSRs (0x1??)
    //
    logic eng_csr_wr_write;
    t_mmio_addr eng_csr_wr_address;
    t_mmio_value eng_csr_wr_writedata;

    always_ff @(posedge clk)
    begin
        eng_csr_wr_write <= wr_write;
        eng_csr_wr_address <= wr_address;
        eng_csr_wr_writedata <= wr_writedata;
    end

    generate
        for (e = 0; e < NUM_ENGINES; e = e + 1)
        begin : w_eng
            always_ff @(posedge clk)
            begin
                eng_csr[e].wr_req <= (eng_csr_wr_write &&
                                      (eng_csr_wr_address[11:8] == 4'h1) &&
                                      (eng_csr_wr_address[7:4] == 4'(e)));
                eng_csr[e].wr_idx <= eng_csr_wr_address[3:0];
                eng_csr[e].wr_data <= eng_csr_wr_writedata;

                eng_csr[e].state_reset <= state_reset[e];
                eng_csr[e].state_run <= state_run[e];
            end
        end
    endgenerate


    //
    // Keep track of whether some engine is currently running
    //
    logic some_engine_is_enabled, some_engine_is_active;

    always_ff @(posedge clk)
    begin
        some_engine_is_enabled <= |state_run;
        some_engine_is_active <= |status_active;
    end


    //
    // Commands to engines
    //
    logic cmd_wr_write;
    t_mmio_addr cmd_wr_address;
    t_mmio_value cmd_wr_writedata;

    always_ff @(posedge clk)
    begin
        cmd_wr_write <= wr_write;
        cmd_wr_address <= wr_address;
        cmd_wr_writedata <= wr_writedata;
    end

    logic is_cmd;
    assign is_cmd = (state == STATE_READY) &&
                    cmd_wr_write && (cmd_wr_address[11:4] == 8'h01);
    logic is_eng_enable_cmd;
    assign is_eng_enable_cmd = is_cmd && (cmd_wr_address[3:0] == 4'h0);
    logic is_eng_disable_cmd;
    assign is_eng_disable_cmd = is_cmd && (cmd_wr_address[3:0] == 4'h1);

    generate
        for (e = 0; e < NUM_ENGINES; e = e + 1)
        begin : cmd_eng
            always_ff @(posedge clk)
            begin
                if (state == STATE_ENG_START)
                begin
                    // Engines that were commanded to be in reset can now run
                    state_run[e] <= state_reset[e] || state_run[e];
                    state_reset[e] <= 1'b0;
                end
                else if (cmd_wr_writedata[e] && is_eng_enable_cmd)
                begin
                    state_reset[e] <= 1'b1;
                    $display("%t: Starting engine %0d", $time, e);
                end
                else if (cmd_wr_writedata[e] && is_eng_disable_cmd)
                begin
                    state_run[e] <= 1'b0;
                    $display("%t: Stopping engine %0d", $time, e);
                end

                if (reset)
                begin
                    state_reset[e] <= 1'b0;
                    state_run[e] <= 1'b0;
                end
            end
        end
    endgenerate

    logic cycle_counter_reset;
    logic cycle_counter_enable;
    assign cycle_counter_enable = some_engine_is_active;
    logic [3:0] eng_reset_hold_cnt;

    always_ff @(posedge clk)
    begin
        case (state)
          STATE_READY:
            begin
                if (is_eng_enable_cmd)
                begin
                    state <= STATE_HOLD_RESET;
                    eng_reset_hold_cnt <= 4'b1;

                    // If no engines are running yet then reset the cycle counters
                    if (! some_engine_is_enabled)
                    begin
                        cycle_counter_reset <= 1'b1;
                    end
                end
            end
          STATE_HOLD_RESET:
            begin
                // Hold reset for clock crossing counters
                eng_reset_hold_cnt <= eng_reset_hold_cnt + 4'b1;
                if (eng_reset_hold_cnt == 4'b0)
                begin
                    state <= STATE_ENG_START;
                    cycle_counter_reset <= 1'b0;
                end
            end
          STATE_ENG_START:
            begin
                state <= STATE_READY;
            end
        endcase // case (state)
            
        if (reset)
        begin
            state <= STATE_READY;
            cycle_counter_reset <= 1'b1;
        end
    end

    //
    // Cycle counters. These run when any engine is active and are reset as
    // engines transition from no engines running to at least one engine running.
    //
    clock_counter#(.COUNTER_WIDTH($bits(num_pClk_cycles)))
      count_pClk_cycles
       (
        .clk,
        .count_clk(pClk),
        .sync_reset(cycle_counter_reset),
        .enable(cycle_counter_enable),
        .count(num_pClk_cycles)
        );

    clock_counter#(.COUNTER_WIDTH($bits(num_clk_cycles)))
      count_clk_cycles
       (
        .clk,
        .count_clk(clk),
        .sync_reset(cycle_counter_reset),
        .enable(cycle_counter_enable),
        .count(num_clk_cycles)
        );

endmodule // csr_mgr