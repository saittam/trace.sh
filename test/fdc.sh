#!/bin/bash
#
# Render the FDC logo scene
#

dir=`dirname $0`
$dir/../trace.sh -g $dir/fdc.geom -j 2  -c 0,-4,4 -s 0,0,0 -u 0,0,4 -l $dir/fdc.light -x 40 -y 40 -o fdc.png -a 0.3,0.3,0.3 $@

