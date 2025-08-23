class_name Sphere extends Node3D

@export var radius := 1.0
@export var albedo: Color
@export var specular: float

func get_data() -> PackedByteArray:
	return PackedFloat32Array([global_position.x, global_position.y, global_position.z, radius, albedo.r, albedo.g, albedo.b, specular]).to_byte_array()
