#!/bin/bash

# vim: tw=100 fo=2croqlt
#
# A simple raytracer implemented as a bash script. It reads geometry from text file and writes a
# rendition of the scene to an image file. bc is used for geometry and lighting calculations.
#
# Geometry is stored in a text file. Each line contains 9 fields, seperated by spaces:
#
# 	<vertex1> <normal1> <color1> <vertex2> <normal2> <color2> <vertex3> <normal3> <color3>
#
# The fields give the vertex position, normals and color values for 3 vertices making up a triangle.
# Each of the fields specifies a vector in R^3, formatted as <x>,<y>,<z>. The color vectors are
# interpreted as normalized RGB values, i.e. full saturation at value 1.

# Help text
help_text="This is a very simply raytracer implemented in bash.

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
yres="30"
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
0,1,1	1,1,1
"

# bc function library we use for geometry calculations
bc_functions=$(cat "functions.bc")

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

	tempdir=`mktemp -d`

	echo "Tempdir is $tempdir" >&2

	# Install a trap that deletes $tempdir on exit
	#trap "rm -rf $tempdir" EXIT

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

	# clean up when done
	trap "echo quit >&3 && rm \"$to_bc_fifo\" \"$from_bc_fifo\"" EXIT

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

# Compute the global transformation we apply to the scene. Everything is transformed s.t. the camera
# is at 0,0,1, screen origin at 0,0,0 and the x-y plane is essentially the screen in pixel
# coordinates
compute_transformation() {

	local vec m mtemp cam_vec m_up_vec parallel_up_comp fixed_up_vec

	# First, move the screen origin into the coordinate system origin
	vec=$(compute "v_scale(-1, $screen_origin)")
	m=$(compute "m_translate($vec)")

	# Rotate the camera onto the negative z axis
	cam_vec=$(compute "v_diff($cam_position, $screen_origin)")
	mtemp=$(compute "m_roty(pi - s_atan2(-s_pz($cam_vec), -s_px($cam_vec)))")
	m=$(compute "m_chain($m, $mtemp)")
	mtemp=$(compute "m_rotx(-s_asin(s_py($cam_vec)))")
	m=$(compute "m_chain($m, $mtemp)")

	# Scale z axis s.t. the camera is located at 1,0,0
	mtemp=$(compute "m_scale(1, 1, 1 / s_len($cam_vec))")
	m=$(compute "m_chain($m, $mtemp)")

	# Rotate around the z axis, making sure that the up vector coincides with the y axis
	parallel_up_comp=$(compute "v_scale(s_innerprod($cam_vec, $up), $cam_vec)")
	fixed_up_vec=$(compute "v_diff($up, $parallel_up_comp)")
	m_up_vec=$(compute "v_transform($fixed_up_vec, $m)")
	mtemp=$(compute "m_rotz(pi / 2 - s_atan2(s_px($m_up_vec), s_py($m_up_vec)))")
	m=$(compute "m_chain($m, $mtemp)")

	# Scale x and y axis s.t. the pixels can be addressed as coordinates
	mtemp=$(compute "m_scale($yres / s_len($m_up_vec), $yres / s_len($m_up_vec), 1)")
	m=$(compute "m_chain($m, $mtemp)")

	global_transform="$m"
}

# Read geometry from the input file, preprocess it and write it back to the geometry temp file. We
# parse the input file, sort the triangles w.r.t. their maximum z coordinate and write the result to
# the geometry file used for rendering
prepare_geometry() {

	local p1 p2 p3 n1 n2 n3 c1 c2 c3 maxz

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
		# Skip over blank lines
		if test -z "$p1"; then
			continue;
		fi

		# Transform and compute the maximum z coordinate
		p1=$(compute "v_transform($p1, $global_transform)")
		p2=$(compute "v_transform($p2, $global_transform)")
		p3=$(compute "v_transform($p3, $global_transform)")
		n1=$(compute "v_transform($n1, $global_transform)")
		n2=$(compute "v_transform($n2, $global_transform)")
		n3=$(compute "v_transform($n3, $global_transform)")
		maxz=$(compute "s_max3(s_pz($p1), s_pz($p2), s_pz($p3))")

		echo "$p1 $n1 $c1 $p2 $n2 $c2 $p3 $n3 $c3 $maxz"
	done |
	# Sort by the generated max z coordinate and write to the geometry work file
	sort -k 10n > "$tempdir/geom_work_file"
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
			echo "Cannot read lighting file \"$geometry_file\", aborting!" >&2
			exit 1;
		fi

		cat "$lighting_file"
	fi |
	# Pipe it all into the read loop
	while read pos color; do
		# Skip over blank lines
		if test -z "$pos"; then
			continue;
		fi

		# Transform position and save result in the lighting variable
		pos=$(compute "v_transform($pos, $global_transform)")
		echo "$pos $color"
	done > "$tempdir/lighting_work_file"
}

# Find an intersection point and print the result
compute_intersection() {

	local xpix ypix curz color stat z b1 b2 b3
	local p1 n1 c1 p2 n2 c2 p3 n3 c3 maxz

	xpix=$1
	ypix=$2
	curz="1"

	# Go through the geometry and look for intersections
	cat "$tempdir/geom_work_file" |
	while read p1 n1 c1 p2 n2 c2 p3 n3 c3 maxz; do
		# Check for intersection
		read stat z b1 b2 b3 < \
			<(compute "intersect($xpix, $ypix, $xres, $yres, $p1, $p2, $p3, $curz)")

		case "$stat" in
			hit)
				echo "$z $b1 $b2 $b3 $p1 $n1 $c1 $p2 $n2 $c2 $p3 $n3 $c3"
				;;
			miss)
				# No hit
				;;
			abort)
				# Subsequent tris won't match due to maxz
				break
				;;
		esac
	done | sort -k 1n | head -1
}

# Compute color value for a single ray. This is the workhorse function that casts a ray, finds the
# intersection point with the geometry and calculates the final color.
cast_ray() {

	local color
	local p1 n1 c1 p2 n2 c2 p3 n3 c3

	# compute the intersection point and save the parameters
	read z b1 b2 b3 p1 n1 c1 p2 n2 c2 p3 n3 c3 < <(compute_intersection $1 $2)

	if test -n "$z"; then
		# We found a hit, compute the material color and the normal
		matcolor=$(compute "v_comb($b1, $c1, $b2, $c2, $b3, $c3)")
		normal=$(compute "v_comb($b1, $n1, $b2, $n2, $b3, $n3)")

		# compute ambient color component
		color=$(compute "v_compprod($matcolor, $ambient_light)")
		#while read pos col "$tempdir/lighting_work_file"; do
		#	diffuse=$(compute "")
		#	specular=$(compute "")
		#done

	else
		# otherwise return the background color
		color="$background_color"
	fi

	# Write the color to the output file
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
	sed -re 's/([0-9]+)(\.[0-9]+)?/\1/g' -e 's/\.[0-9]+/0/g' >> $ppmfile

	# Determine output file name
	if test -z "$output_file"; then
		output_file="image.$output_format"
	fi

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

#
# Main program
#

# Install a trap that kills all child processes when this shell quits
trap "kill -KILL `jobs -p`" EXIT

parse_options $@
setup_tempdir
start_computation_helper

echo "Preprocessing data..." >&2

compute_transformation
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
echo "Saving image..." >&2

collect_results

# Done!
echo "Finished." >&2

