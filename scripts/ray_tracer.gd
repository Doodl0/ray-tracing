extends Node

@export var skybox_texture: Texture
var viewport_dimensions: Vector2i
@onready var output_display: RenderOutput = $%"Output Display"

# Create local rendering device to run compute shaders on
var rd := RenderingServer.create_local_rendering_device()
var shader_rid: RID
@export_file("*.glsl") var shader_file: String
var render_rid: RID
var skybox_rid: RID
var uniform_set: RID
var pipeline: RID
var uniform_bindings: Array[RDUniform]

func _ready() -> void:
	# Set the render dimensions to the viewport dimensions so that the image is not stretched
	viewport_dimensions.x = ProjectSettings.get_setting("display/window/size/viewport_width")
	viewport_dimensions.y = ProjectSettings.get_setting("display/window/size/viewport_height")
	
	# Set the display image size to the same as the viewport
	output_display.image_size = viewport_dimensions
	# Create the texture so that data can be added later
	output_display.init_texture()
	
	setup_compute()
	render()


func _process(delta: float) -> void:
	update_compute()
	render()

func render():
	# Validate that the pipeline has been created so to avoid errors
	if pipeline == null:
		setup_compute()
	
	# Create a compute list and bind uniforms and pipeline
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	# Dispatch one workgroup for every 8x8 block of pixels here
	# Ignore integer division to avoid warnings as both viewport and 8 are ints
	@warning_ignore("integer_division")
	rd.compute_list_dispatch(compute_list, viewport_dimensions.x / 8, viewport_dimensions.y / 8, 1)
	rd.compute_list_end()
	
	rd.submit()
	# Wait for the GPU to finish.
	rd.sync()
	
	# Retrieve render data.
	var render_bytes := rd.texture_get_data(render_rid, 0)
	output_display.display_render(render_bytes)


func setup_compute():
	# Prepare the shader.
	shader_rid = load_shader(rd, shader_file)
	
	# Create a format for the render image
	var render_format = RDTextureFormat.new()
	render_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	render_format.height = viewport_dimensions.y
	render_format.width = viewport_dimensions.x
	# Set usage bits. Can add the required bits together
	render_format.usage_bits = \
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	# Prepare render texture now and set the data later.
	render_rid = rd.texture_create(render_format, RDTextureView.new())
	
	var render_uniform := RDUniform.new()
	render_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	# Set binding to matching binding in the shader
	render_uniform.binding = 0
	render_uniform.add_id(render_rid)
	
	# Create matrix from camera transform
	var camera_to_world := get_viewport().get_camera_3d().global_transform
	var basis := camera_to_world.basis
	var origin := camera_to_world.origin
	var camera_to_world_matrix := PackedFloat32Array([
		basis.x.x, basis.x.y, basis.x.z, 1.0,
		basis.y.x, basis.y.y, basis.y.z, 1.0,
		basis.z.x, basis.z.y, basis.z.z, 1.0,
		origin.x, origin.y, origin.z, 1.0
	]).to_byte_array()
	
	# Create a projection matrix from camera projection
	var projection := (get_viewport().get_camera_3d().get_camera_projection().inverse() * Projection.create_depth_correction(true))
	print(projection)
	var projection_matrix := PackedFloat32Array([
		projection.x.x, projection.x.y, projection.x.z, projection.x.w,
		projection.y.x, projection.y.y, projection.y.z, projection.y.w,
		projection.z.x, projection.z.y, projection.z.z, projection.z.w,
		projection.w.x, projection.w.y, projection.w.z, projection.w.w,
	]).to_byte_array()
	
	var camera_data_bytes := PackedByteArray()
	camera_data_bytes.append_array(camera_to_world_matrix)
	camera_data_bytes.append_array(projection_matrix)
	var camera_data_buffer := rd.storage_buffer_create(camera_data_bytes.size(), camera_data_bytes)
	var camera_data_uniform := RDUniform.new()
	camera_data_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	camera_data_uniform.binding = 1
	camera_data_uniform.add_id(camera_data_buffer)
	
	uniform_bindings = [render_uniform, camera_data_uniform]
	
	# Create the set of uniforms from list of created uniforms and shader RID
	uniform_set = rd.uniform_set_create(uniform_bindings, shader_rid, 0)
	# Create compute shader pipeline
	pipeline = rd.compute_pipeline_create(shader_rid)

func update_compute():
	# Create matrix from camera transform
	var camera_to_world := get_viewport().get_camera_3d().global_transform
	var basis := camera_to_world.basis
	var origin := camera_to_world.origin
	var camera_to_world_matrix := PackedFloat32Array([
		basis.x.x, basis.x.y, basis.x.z, 1.0,
		basis.y.x, basis.y.y, basis.y.z, 1.0,
		basis.z.x, basis.z.y, basis.z.z, 1.0,
		origin.x, origin.y, origin.z, 1.0
	]).to_byte_array()
	
	# Create a projection matrix from camera projection
	var projection := (get_viewport().get_camera_3d().get_camera_projection().inverse() * Projection.create_depth_correction(true))
	print(projection)
	var projection_matrix := PackedFloat32Array([
		projection.x.x, projection.x.y, projection.x.z, projection.x.w,
		projection.y.x, projection.y.y, projection.y.z, projection.y.w,
		projection.z.x, projection.z.y, projection.z.z, projection.z.w,
		projection.w.x, projection.w.y, projection.w.z, projection.w.w,
	]).to_byte_array()
	
	var camera_data_bytes := PackedByteArray()
	camera_data_bytes.append_array(camera_to_world_matrix)
	camera_data_bytes.append_array(projection_matrix)
	var camera_data_buffer := rd.storage_buffer_create(camera_data_bytes.size(), camera_data_bytes)
	var camera_data_uniform := RDUniform.new()
	camera_data_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	camera_data_uniform.binding = 1
	camera_data_uniform.add_id(camera_data_buffer)
	
	uniform_bindings[1] = camera_data_uniform
	uniform_set = rd.uniform_set_create(uniform_bindings, shader_rid, 0)

# Import, compile and load shader, return reference.
func load_shader(p_rd: RenderingDevice, path: String) -> RID:
	var shader_file_data: RDShaderFile = load(path)
	var shader_spirv: RDShaderSPIRV = shader_file_data.get_spirv()
	return p_rd.shader_create_from_spirv(shader_spirv)
