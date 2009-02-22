#!/bin/bash
#
# Render the cube example scene
#

dir=`dirname $0`
$dir/../trace.sh -g $dir/cube.geom -j 2  -c 5,5,5 -s 3,3,4 -u 0,0,.5 -l $dir/cube.light -x 40 -y 40 -o cube.png $@

