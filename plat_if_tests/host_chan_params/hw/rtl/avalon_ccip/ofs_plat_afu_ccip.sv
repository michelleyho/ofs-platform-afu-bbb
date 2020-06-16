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

//
// Export the host channel as CCI-P for host memory and Avalon for MMIO.
//

`default_nettype none

`include "ofs_plat_if.vh"

`define RESET_FROM_CLK(clk) clk``_reset_n

module ofs_plat_afu
   (
    // All platform wires, wrapped in one interface.
    ofs_plat_if plat_ifc
    );

    // ====================================================================
    //
    //  Get a CCI-P port from the platform.
    //
    // ====================================================================

    // Instance of a CCI-P interface. The interface wraps usual CCI-P
    // sRx and sTx structs as well as the associated clock and reset.
    ofs_plat_host_ccip_if ccip_to_afu();

    // Use the platform-provided module to map the primary host interface
    // to CCI-P. The "primary" interface is the port that includes the
    // main OPAE-managed MMIO connection.
    ofs_plat_host_chan_as_ccip
      #(
`ifdef TEST_PARAM_AFU_CLK
        .ADD_CLOCK_CROSSING(1),
`endif
`ifdef TEST_PARAM_SORT_RD_RESP
        .SORT_READ_RESPONSES(1),
`endif
`ifdef TEST_PARAM_AFU_REG_STAGES
        .ADD_TIMING_REG_STAGES(`TEST_PARAM_AFU_REG_STAGES)
`endif
        )
      primary_ccip
       (
        .to_fiu(plat_ifc.host_chan.ports[0]),
        .to_afu(ccip_to_afu),

`ifdef TEST_PARAM_AFU_CLK
        .afu_clk(`TEST_PARAM_AFU_CLK),
        .afu_reset_n(`RESET_FROM_CLK(`TEST_PARAM_AFU_CLK))
`else
        .afu_clk(),
        .afu_reset_n()
`endif
        );


    // Split CCI-P into a pair of CCI-P interfaces: one for host memory
    // and the other for MMIO.
    localparam NUM_PORTS_G0 = plat_ifc.host_chan.NUM_PORTS_;
    ofs_plat_host_ccip_if#(.LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)) host_mem_to_afu[NUM_PORTS_G0]();
    ofs_plat_host_ccip_if ccip_to_mmio();

    ofs_plat_shim_ccip_split_mmio ccip_split
       (
        .to_fiu(ccip_to_afu),
        .host_mem(host_mem_to_afu[0]),
        .mmio(ccip_to_mmio)
        );


    // Map the the CCI-P MMIO interface to a 64 bit Avalon interface.
    ofs_plat_avalon_mem_if
      #(
        `HOST_CHAN_AVALON_MMIO_PARAMS(64),
        .LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN)
        )
        mmio64_to_afu();

    ofs_plat_map_ccip_as_avalon_mmio
      #(
        .MAX_OUTSTANDING_MMIO_RD_REQS(ccip_cfg_pkg::MAX_OUTSTANDING_MMIO_RD_REQS)
        )
      av_host_mmio
       (
        .to_fiu(ccip_to_mmio),
        .mmio_to_afu(mmio64_to_afu),

        // Not used (no clock crossing)
        .afu_clk(),
        .afu_reset_n()
        );

    // Are there any more ports in group 0? Map them to host_mem_to_afu.
    genvar p;
    generate
        for (p = 1; p < NUM_PORTS_G0; p = p + 1)
        begin : hc_g0
            ofs_plat_host_chan_as_ccip
              #(
`ifdef TEST_PARAM_SORT_RD_RESP
                .SORT_READ_RESPONSES(1),
`endif
`ifdef TEST_PARAM_AFU_REG_STAGES
                .ADD_TIMING_REG_STAGES(`TEST_PARAM_AFU_REG_STAGES),
`endif
                .ADD_CLOCK_CROSSING(1)
                )
              ccip
               (
                .to_fiu(plat_ifc.host_chan.ports[p]),
                .to_afu(host_mem_to_afu[p]),

                .afu_clk(host_mem_to_afu[0].clk),
                .afu_reset_n(host_mem_to_afu[0].reset_n)
                );
        end
    endgenerate

    //
    // If there is a second group of host channel ports map them too.
    //
`ifndef OFS_PLAT_PARAM_HOST_CHAN_G1_NUM_PORTS

    localparam NUM_PORTS_G1 = 0;
    ofs_plat_host_ccip_if host_mem_g1_to_afu[1]();

`else

    localparam NUM_PORTS_G1 = plat_ifc.host_chan_g1.NUM_PORTS_;
    ofs_plat_host_ccip_if#(.LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN))
        host_mem_g1_to_afu[NUM_PORTS_G1]();

    generate
        for (p = 0; p < NUM_PORTS_G1; p = p + 1)
        begin : hc_g1
            ofs_plat_host_chan_g1_as_ccip
              #(
`ifdef TEST_PARAM_SORT_RD_RESP
                .SORT_READ_RESPONSES(1),
`endif
`ifdef TEST_PARAM_AFU_REG_STAGES
                .ADD_TIMING_REG_STAGES(`TEST_PARAM_AFU_REG_STAGES),
`endif
                .ADD_CLOCK_CROSSING(1)
                )
              ccip
               (
                .to_fiu(plat_ifc.host_chan_g1.ports[p]),
                .to_afu(host_mem_g1_to_afu[p]),

                .afu_clk(host_mem_to_afu[0].clk),
                .afu_reset_n(host_mem_to_afu[0].reset_n)
                );
        end
    endgenerate

`endif // OFS_PLAT_PARAM_HOST_CHAN_G1_NUM_PORTS


    //
    // If there is a third group of host channel ports map them too.
    //
`ifndef OFS_PLAT_PARAM_HOST_CHAN_G2_NUM_PORTS

    localparam NUM_PORTS_G2 = 0;
    ofs_plat_host_ccip_if host_mem_g2_to_afu[1]();

`else

    localparam NUM_PORTS_G2 = plat_ifc.host_chan_g2.NUM_PORTS_;
    ofs_plat_host_ccip_if#(.LOG_CLASS(ofs_plat_log_pkg::HOST_CHAN))
        host_mem_g2_to_afu[NUM_PORTS_G2]();

    generate
        for (p = 0; p < NUM_PORTS_G2; p = p + 1)
        begin : hc_g2
            ofs_plat_host_chan_g2_as_ccip
              #(
`ifdef TEST_PARAM_SORT_RD_RESP
                .SORT_READ_RESPONSES(1),
`endif
`ifdef TEST_PARAM_AFU_REG_STAGES
                .ADD_TIMING_REG_STAGES(`TEST_PARAM_AFU_REG_STAGES),
`endif
                .ADD_CLOCK_CROSSING(1)
                )
              ccip
               (
                .to_fiu(plat_ifc.host_chan_g2.ports[p]),
                .to_afu(host_mem_g2_to_afu[p]),

                .afu_clk(host_mem_to_afu[0].clk),
                .afu_reset_n(host_mem_to_afu[0].reset_n)
                );
        end
    endgenerate

`endif // OFS_PLAT_PARAM_HOST_CHAN_G2_NUM_PORTS


    // ====================================================================
    //
    //  Map pwrState to the AFU clock domain
    //
    // ====================================================================

    t_ofs_plat_power_state afu_pwrState;

    ofs_plat_prim_clock_crossing_reg
      #(
        .WIDTH($bits(t_ofs_plat_power_state))
        )
      map_pwrState
       (
        .clk_src(plat_ifc.clocks.pClk),
        .clk_dst(ccip_to_afu.clk),
        .r_in(plat_ifc.pwrState),
        .r_out(afu_pwrState)
        );


    // ====================================================================
    //
    //  Tie off unused ports.
    //
    // ====================================================================

    ofs_plat_if_tie_off_unused
      #(
`ifdef OFS_PLAT_PARAM_HOST_CHAN_G1_NUM_PORTS
        // If host channel group 1 ports exist, they are all connected
        .HOST_CHAN_G1_IN_USE_MASK(-1),
`endif
`ifdef OFS_PLAT_PARAM_HOST_CHAN_G2_NUM_PORTS
        // If host channel group 2 ports exist, they are all connected
        .HOST_CHAN_G2_IN_USE_MASK(-1),
`endif
        // All host channel group 0 ports are connected
        .HOST_CHAN_IN_USE_MASK(-1)
        )
        tie_off(plat_ifc);


    // ====================================================================
    //
    //  Pass the constructed interfaces to the AFU.
    //
    // ====================================================================

    afu
     #(
       .NUM_PORTS_G0(NUM_PORTS_G0),
       .NUM_PORTS_G1(NUM_PORTS_G1),
       .NUM_PORTS_G2(NUM_PORTS_G2)
       )
     afu_impl
      (
       .host_mem_if(host_mem_to_afu),
       .host_mem_g1_if(host_mem_g1_to_afu),
       .host_mem_g2_if(host_mem_g2_to_afu),
       .mmio64_if(mmio64_to_afu),
       .pClk(plat_ifc.clocks.pClk),
       .pwrState(afu_pwrState)
       );

endmodule // ofs_plat_afu