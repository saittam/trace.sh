#!/bin/bash
# vim: tw=100 fo=2croqlt
#
# trace.sh - A simple raytracer implemented as a bash script
# Copyright (C) 2009 Mattias Nissler <mattias.nissler@gmx.de>
#
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU
# General Public License as published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
# even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program. If
# not, see <http://www.gnu.org/licenses/>.
#
# -------------------------------------------------------------------------------------------------
#
# This is a simple raytracer implemented as a bash script. It reads geometry from a text file and
# writes a rendition of the scene to an image file. bc is used for geometry and lighting
# calculations, which means the raytracer can potentially operate at arbitrary precision.
#
# Geometry is stored in a text file. Each line contains 9 fields, seperated by spaces:
#
# 	<vertex1> <normal1> <color1> <vertex2> <normal2> <color2> <vertex3> <normal3> <color3>
#
# The fields give the vertex position, normals and color values for 3 vertices making up a triangle.
# Each of the fields specifies a vector in R^3, formatted as <x>,<y>,<z>. The color vectors are
# interpreted as normalized RGB values, i.e. full saturation at value 1. There is a geometry export
# script for blender that can export blender meshes in the correct format.
#
# Parallelization is supported, the raytracer can start and control several render processes in
# subshells. The number of render processes can be adjusted throug the -j option.
# 
# Only the very basic rendering code is implemented. Prominent missing features include oversampling
# (i.e. no anti-aliasing), reflection and refraction (can easily be added but is potentially
# expensive). Also missing is a space partitioning scheme that speeds up the rendering process. I'm
# open to suggestions on how to implement this cleverly using bash variables and the file system.

# Help text
help_text="This is a very simple raytracer implemented in bash.
Copyright (C) 2009 Mattias Nissler <mattias.nissler@gmx.de>

Usage: $0 [options]

Options include:
	-a <vec>	--ambient-light <vec>		Ambient light color and intensity
	-b <vec>	--background-color <vec>	Background color value (normalized RGB)
	-c <vec>	--camera-position <vec>		Location of the camera
	-f <format>	--output-format <format>	Output file format. One of (png, jpeg)
	-g <file>	--geometry-file <file>		File containing geometry data
	-h		--help				Print this help message
	-j <int>	--num-threads <int>		Number of parallel render threads
	-l <file>	--lights <file>			File containing light definitions
	-o <file>	--output-file <file>		File to write the output to
	-s <vec>	--screen-origin <vec>		Screen origin
	-t <dir>	--temp-dir <dir>		Temporary files directory
	-u <vec>	--up <vec>			Up vector for the screen
	-x <num>	--x-resolution <num>		Horizontal resolution in pixels
	-y <num>	--y-resolution <num>		Horizontal resolution in pixels

where <int> and <num> indicate integral and a floating point number arguments, respectively, and
<vec> is a vector in 3D space of the format <num>,<num>,<num>.
"

# Variables section. Each variable should have a sensible default, s.t. you can just run the script
# without any arguments and get a nice picture :-)

# Output file name, construct default name if zero
output_file=""
# Output file format
output_format="png"
# Camera position
cam_position="0,0,1"
# Screen origin
screen_origin="0,0,0"
# Up vector. Length determines screen size
up="0,1,0"
# Horizontal resolution in pixels
xres="40"
# Vertical resolution in pixels
yres="40"
# Geometry file name, use default geometry if zero
geometry_file=""
# Lighting file name, use default lighting if zero
lighting_file=""
# Number of parallel render threads
num_threads="1"
# Background color
background_color="1,1,1"
# Ambient light
ambient_light="0.2,0.2,0.2"
# temporary directory, use autocreated if zero
tempdir=""

# Constants section

# Size of the pixel batches
batch_size="100"
# Color scale
color_scale="255"
# Default geometry
default_geometry="\
1,-1,-1 0,0,1 1,0,0	1,1,-1 0,0,1 0,1,0	-1,1,-1 0,0,1 0,0,1
1,-1,-1 0,0,1 1,0,0	-1,-1,-1 0,0,1 1,1,0	-1,1,-1 0,0,1 0,0,1
"
# Default lights
default_lighting="\
0,1,1	0.8,0.8,0.8
"
# Directory we're running from
basedir=`dirname $0`

# Whether to delete the temporary directory
deltemp=0

# bc function library we use for geometry calculations
bc_functions=$(cat "$basedir/functions.bc")

# Parse command line options
parse_options() {

	local opt 

	while test -n "$1"; do
		opt="$1"
		shift
		case "$opt" in 
			-a|--ambient-light)
				ambient_light="$1"
				shift
				;;
			-b|--background-color)
				background_color="$1"
				shift
				;;
			-c|--camera-position)
				cam_position="$1"
				shift
				;;
			-f|--output-format)
				output_format="$1"
				shift
				;;
			-g|--geometry-file)
				geometry_file="$1"
				shift
				;;
			-h|--help)
				echo "$help_text" >&2
				exit 1;
				;;
			-j|--num-threads)
				num_threads="$1"
				shift
				;;
			-l|--lights)
				lighting_file="$1"
				shift
				;;
			-o|--output-file)
				output_file="$1"
				shift
				;;
			-s|--screen-origin)
				screen_origin="$1"
				shift
				;;
			-t|--temp-dir)
				tempdir="$1"
				shift
				;;
			-u|--up)
				up="$1"
				shift
				;;
			-x|--x-resolution)
				xres="$1"
				shift
				;;
			-y|--y-resolution)
				yres="$1"
				shift
				;;
			*)
				echo "Unknown option $opt" >&2
				echo "$help_text" >&2
				exit 1;
				;;
		esac
	done
}

# Setup a temporary directory in which we store our intermediate data
setup_tempdir() {

	if test -n "$tempdir"; then

		if test ! -d "$tempdir"; then
			echo "Bad temporary directory $tempdir" >&2
			exit 1
		fi

		echo "Tempdir is $tempdir" >&2

		rm -rf $tempdir/*
	else
		tempdir=`mktemp -d`
		deltemp=1
	fi

	# Create directories within tempdir
	mkdir "$tempdir/bc_fifos"
	mkdir "$tempdir/locks"
	mkdir "$tempdir/pixels"
}

# Start a bc slave process for geometry computations. This starts the bc process in the background
# and sets up file descriptors 3 and 4 for writing commands to bc and reading results back,
# respectively.
start_computation_helper() {

	local to_bc_fifo from_bc_fifo bc_pid

	# make the fifos
	to_bc_fifo="$tempdir/bc_fifos/to.$1"
	from_bc_fifo="$tempdir/bc_fifos/from.$1"

	mkfifo "$to_bc_fifo"
	mkfifo "$from_bc_fifo"

	# start bc
	bc -l <"$to_bc_fifo" >"$from_bc_fifo" &
	bc_pid=$!

	# open file descriptors
	exec 3>"$to_bc_fifo" 4<"$from_bc_fifo"

	# Load the helper function library
	echo "$bc_functions" >&3
}

# Sends a command to the computation helper and reads a single result line
compute() {

	local line

	#echo "bc > $1" >&2

	echo "$1" >&3
	read line <&4

	#echo "bc < $line" >&2

	echo "$line"
}

# Compute some helper geometry values
compute_screen_vectors() {

	local dir temp_scrh temp_scrv

	# cam to screen origin vector
	dir=$(compute "v_diff($screen_origin, $cam_position)")

	# compute horizontal and vectical screen vector (unscaled)
	temp_scrh=$(compute "v_outerprod($dir, $up)")
	temp_scrv=$(compute "v_outerprod($temp_scrh, $dir)")
	temp_scrv=$(compute "v_scale(1 / s_len($temp_scrv), $temp_scrv)")

	# scale the vectors to half the screen size
	temp_scrv=$(compute "v_scale(0.5 * s_innerprod($up, $temp_scrv), $temp_scrv)")
	temp_scrh=$(compute "v_scale(1 / s_len($temp_scrh), $temp_scrh)")
	temp_scrh=$(compute "v_scale(s_len($temp_scrv) * $xres / $yres, $temp_scrh)")

	# compute lower left of screen
	scrll=$(compute "v_diff($screen_origin, $temp_scrh)")
	scrll=$(compute "v_diff($scrll, $temp_scrv)")

	# scale the horizontal and vertical vectors to pixel distance
	scrh=$(compute "v_scale(2 / $xres, $temp_scrh)")
	scrv=$(compute "v_scale(2 / $yres, $temp_scrv)")
}

# Read geometry from the input file, preprocess it and write it back to the geometry temp file. We
# parse the input file, sort the triangles w.r.t. their maximum z coordinate and write the result to
# the geometry file used for rendering
prepare_geometry() {

	local p1 n1 c1 p2 n2 c2 p3 n3 c3

	# Check whether we have an input file. If not, use default geometry
	if test -z "$geometry_file"; then
		echo "$default_geometry"
	else
		# See whether we can read the file
		if test ! -r "$geometry_file"; then
			echo "Cannot read geometry file \"$geometry_file\", aborting!" >&2
			exit 1;
		fi

		cat "$geometry_file"
	fi |
	# Pipe it all into the read loop
        while read p1 n1 c1 p2 n2 c2 p3 n3 c3; do
                # Strip blank lines
                if test -z "$p1"; then
                        continue;
                fi
		n1=$(compute "fix_normal($n1, $p1, $p2, $p3)")
		n2=$(compute "fix_normal($n2, $p1, $p2, $p3)")
		n3=$(compute "fix_normal($n3, $p1, $p2, $p3)")
                echo "$p1 $n1 $c1 $p2 $n2 $c2 $p3 $n3 $c3"
        done > "$tempdir/geom_work_file"
}

# Load the file containing lighting information. The lighting information is stored to the lighting
# work file
prepare_lighting() {

	local pos color

	# Check whether we have an input file. If not, use default lighting definition
	if test -z "$lighting_file"; then
		echo "$default_lighting"
	else
		# See whether we can read the file
		if test ! -r "$lighting_file"; then
			echo "Cannot read lighting file \"$lighting_file\", aborting!" >&2
			exit 1;
		fi

		cat "$lighting_file"
	fi |
	# Pipe it all into the read loop
        while read pos color; do
                # Strip blank lines
                if test -z "$pos"; then
                        continue;
                fi
                echo "$pos $color"
        done > "$tempdir/lighting_work_file"
}

# Find an intersection point and print the result
compute_intersection() {

	local xpix ypix stat t pi b n
	local p1 n1 c1 p2 n2 c2 p3 n3 c3

	# Go through the geometry and look for intersections
	cat "$tempdir/geom_work_file" |
	while read p1 n1 c1 p2 n2 c2 p3 n3 c3; do
		# Check for intersection
		read stat t pi b n < <(compute "intersect($1, $2, $p1, $n1, $p2, $n2, $p3, $n3)")

		case "$stat" in
			hit)
				echo "$t $pi $b $n $p1 $n1 $c1 $p2 $n2 $c2 $p3 $n3 $c3"
				;;
			miss)
				# No hit
				;;
		esac
	done | sort -k 1n
}

# Compute color value for a single ray. This is the workhorse function that casts a ray, finds the
# intersection point with the geometry and calculates the final color.
cast_ray() {

	local color t pi b n p1 n1 c1 p2 n2 c2 p3 n3 c3 rest

	# compute ray direction
	dir=$(compute "pix_pos($scrll, $scrh, $scrv, $1, $2)")

	# compute the intersection point and save the parameters
	read t pi b n p1 n1 c1 p2 n2 c2 p3 n3 c3 < <(compute_intersection $cam_position $dir)

	if test -n "$t"; then
		# We found a hit, compute the material color and the normal
		matcolor=$(compute "v_comb($b, $c1, $c2, $c3)")

		# compute ambient color component
		color=$(compute "v_compprod($matcolor, $ambient_light)")
		exec 5<"$tempdir/lighting_work_file"
		while read -u 5 pos col; do
			# Check whether the light is visible
			read t rest < <(compute_intersection $pi $pos)
			if test -z "$t"; then
				# No obstacles, add diffuse and specular component
				color=$(compute "lighting($color, $col, $matcolor, \
								$pi, $pos, $n, $cam_position)");
			fi
		done

	else
		# otherwise return the background color
		color="$background_color"
	fi

	# announce the computed color
	echo "$color"
}

# Take the lock indicated by the first argument (may be an arbitrary string identifying the lock).
# This function loops until it can create the lock file. Once it suceeded, it will return to the
# caller. Make sure you call unlock() !
lock() {

	while true; do
		bash -c "set -o noclobber; echo \$\$ > \"$tempdir/locks/$1\"" 1>/dev/null 2>&1
		if test "$?" -eq "0"; then
			return
		fi
		# Try again
		sleep .1
	done
}

# Unlock the given lock. This simply deletes the lock file.
unlock() {

	rm -f "$tempdir/locks/$1"
}

# Get the next batch of pixels to render
get_next_batch() {

	local old_value new_value batch_file percent_complete

	lock "current_batch"
	batch_file="$tempdir/current_batch"

	old_value="0";
	if test -r "$batch_file"; then
		old_value=$(cat "$tempdir/current_batch")
	fi

	echo $old_value

	new_value=$((old_value + batch_size))
	echo "$new_value" > "$tempdir/current_batch"

	# Write status information
	percent_complete=$(((old_value * 100) / (xres * yres)))
	echo -ne "\x0d${percent_complete}%" >&2

	unlock "current_batch"
}

# This is the entry point for each of the render threads
render_thread() {

	local color xpix ypix bs i color threadid

	threadid=$1

	# start a local computation helper
	start_computation_helper "$threadid"

	# Render pixels one after another until we're done
	while true; do
		bs=$(get_next_batch)
		
		for ((i = 0; i < batch_size; i++)); do
			ypix=$(((bs + i) / xres))
			xpix=$(((bs + i) % xres))

			if let "ypix >= yres"; then
				return;
			fi

			color=$(cast_ray $xpix $ypix)

			echo "$xpix $ypix $color" >> "$tempdir/pixels/out.$threadid"
		done
	done
}

# Collects the results of the render threads and writes the output image
collect_results() {

	local xpix ypix color ppmfile cs

	cs=$color_scale
	ppmfile="$tempdir/ppmimage"

	# Write the ppm header
	echo "P3 $xres $yres $color_scale" > $ppmfile

	# Merge all output, sort it by pixel (reverse y here!) and bring it into ppm format
	cat $tempdir/pixels/* | sort -k 2rn -k 1n |
	awk -F '[ ,]' "{ print \$3 * $cs \" \" \$4 * $cs \" \" \$5 * $color_scale }" |
	# strip the decimal part (note: rounding would be better)
	sed -re 's/([0-9]+)(\.[0-9]+)?/\1/g' -e 's/\.[0-9]+/0/g' -e 's/-?[0-9]+[eE]-?[0-9]+/0/' \
	>> $ppmfile

	# Determine output file name
	if test -z "$output_file"; then
		output_file="image.$output_format"
	fi

	echo "Saving image to file $output_file" >&2 

	# Convert to the requested output format
	pnmgamma -lineartobt709 $ppmfile |
	case "$output_format" in
		png)
			pnmtopng
			;;
		jpeg)
			pnmtojpeg
			;;
		*)
			echo "Unknown output format \"$output_format\, writing png instead" >&2
			pnmtopng
	esac > "$output_file"
}

# exit handler called upon shell exit
cleanup() {

	echo -e "\x0dExit!"

	# kill all render threads
	children=`jobs -p`
	if test -n "$children"; then
		kill $children 2>/dev/null
	fi

	# kill bc slave
	exec 3<&-
	exec 3<&-
	
	# Delete temporary directory if necessary
	if test "$tempdel" == "1"; then
		rm -rf "$tempdir" 2>/dev/null
	fi
}

#
# Main program
#

# Install the exit trap
trap cleanup EXIT

parse_options $@
setup_tempdir
start_computation_helper

echo "Preprocessing data..." >&2

compute_screen_vectors
prepare_geometry
prepare_lighting

echo "Start rendering..." >&2

# Run the render threads
pids=""
for ((i = 0; i < num_threads; i++)); do
	render_thread "rt$i" &
	pids="$! $pids"
done

# Wait for all the render threads to complete
wait $pids

echo -e "\x0d100%"

# Format the output image
collect_results

# Done!
echo "Finished." >&2

