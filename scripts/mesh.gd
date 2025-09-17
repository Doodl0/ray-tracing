class_name RayTracedMesh extends Node3D

@export var mesh: ArrayMesh
@export var albedo: Color
@export var specular: float
@export var smoothness: float
@export var emission: Vector3

func get_vertex_data() -> PackedByteArray:
	# Add an extra 4 bytes of padding for memory alignment
	var faces = mesh.get_faces()
	var data = PackedVector4Array()
	for face in faces:
		data.append(Vector4(face.x, face.y, face.z, 1.0))
	
	return data.to_byte_array()

func get_mesh_object_data() -> PackedByteArray:
	# create a transformation matrix
	var basis = self.global_transform.basis
	var origin = self.global_transform.origin
	var local_to_world_matrix := PackedFloat32Array([
		basis.x.x, basis.x.y, basis.x.z, 1.0,
		basis.y.x, basis.y.y, basis.y.z, 1.0,
		basis.z.x, basis.z.y, basis.z.z, 1.0,
		origin.x, origin.y, origin.z, 1.0
	])
	
	# pack material data as bytes
	var material_data := PackedFloat32Array([albedo.r, albedo.g, albedo.b, specular, emission.x, emission.y, emission.z, smoothness])
	
	# pack aabb as bytes
	var bbox := mesh.get_aabb()
	var bbox_data := PackedFloat32Array([bbox.position.x, bbox.position.y, bbox.position.z, 0.0, bbox.end.x, bbox.end.y, bbox.end.z, 0.0])
	
	local_to_world_matrix.append_array(material_data)
	local_to_world_matrix.append_array(bbox_data)
	
	return local_to_world_matrix.to_byte_array()
