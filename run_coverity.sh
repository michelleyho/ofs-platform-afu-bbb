#!/bin/bash
#set -x

# Running coverity for ofs-platform-afu-bbb
#	- cov-configure --gcc --config output.xml
#	- cov-build --config output.xml --dir coverity_results make
#	- cov-analyze --config output.xml --dir coverity_results --concurrency --security --rule --enable-constraint-fpp --enable-fnptr --enable-virtual
#	- cov-format-errors --dir results --html-output html
#   - cov-commit-defects --dir coverity_results --stream "Ofs-platform-afu-bbb-master" --user <username> --url <coverity project server>


top_level_dir=${PWD}

# Configure coverity run
cov-configure -gcc --config output.xml


# Find all examples to build
# Run coverity while building examples
for i in $(find . -name "Makefile" -type f)
do (
  cd $(dirname $(realpath $i));
  echo "Script executed from: ${PWD}"
  echo "cov-build --config ${top_level_dir}/output.xml --dir ${top_level_dir}/coverity_results make"
  cov-build --config ${top_level_dir}/output.xml --dir ${top_level_dir}/coverity_results make
)
done

cd ${top_level_dir}

# Run coverity analysis
cov-analyze --config output.xml --dir coverity_results --concurrency --security --rule --enable-constraint-fpp --enable-fnptr --enable-virtual
