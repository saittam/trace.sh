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

		mesh.sel = True
		mesh.quadToTriangle()
		mesh.transform(obj.matrixWorld)

		# Iterate over all faces and write the vertices
		for face in mesh.faces:

			if len(face.verts) != 3:
				print "Skipping non-triangle face!"
				continue

			for v in face.verts:
				
				# Write the information to the file
				file.write('%f,%f,%f ' % tuple(v.co))
				file.write('%f,%f,%f ' % tuple(v.no))
				if mesh.vertexColors :
					file.write('%f,%f,%f ' % (col.r, col.b, col.g))
				else :
					mi = face.mat 
					if mi < len(mesh.materials):
						col = mesh.materials[face.mat].rgbCol
					else :
						col = [1.0, 1.0, 1.0]
					file.write('%f,%f,%f ' % tuple(col))

			file.write('\n')

def main():
	Blender.Window.FileSelector(geomExport, 'trace.sh export',
		Blender.sys.makename(ext='.geom'))


if __name__=='__main__':
	main()

