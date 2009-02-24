#
# Blender export script that generates the geometry file in the correct format
#

import Blender;
import Blender.Mesh;

def geomExport(filename):

	file = open(filename, 'wb')

	try :
		doExport(file)
	finally :
		file.close()

def doExport(file):

	scene = Blender.Scene.GetCurrent()
	
	# Iterate over all objects and export
	for obj in scene.objects:

		# Only export selected objects
		if not obj.isSelected():
			continue

		try :
			mesh = Blender.Mesh.Get(obj.name)
		except :
			continue

		if not mesh:
			continue

		mesh.transform(obj.matrixWorld)

		# Iterate over all faces and write the vertices
		for face in mesh.faces:

			# Determine color
			mi = face.mat 
			if mi < len(mesh.materials):
				col = mesh.materials[face.mat].rgbCol
			else :
				col = [1.0, 1.0, 1.0]

			# Write geometry
			verts = face.v
			nverts = len(verts)
			if nverts == 3 :
				writeTri(file, verts, col)
			elif nverts == 4 :
				writeTri(file, (verts[3], verts[1], verts[0]), col)
				writeTri(file, (verts[1], verts[2], verts[3]), col)
			else :
				print "Skipping face that is neither tri nor quad!"
				continue


def writeTri(file, verts, col) :

	for v in verts:
		# Write the information to the file
		file.write('%f,%f,%f ' % tuple(v.co))
		file.write('%f,%f,%f ' % tuple(v.no))
		file.write('%f,%f,%f ' % tuple(col))

	file.write('\n')

def main():
	Blender.Window.FileSelector(geomExport, 'trace.sh export',
		Blender.sys.makename(ext='.geom'))


if __name__=='__main__':
	main()

