extends Node

var viewport_dimensions: Vector2i
@onready var output_display: RenderOutput = $"Camera3D/Output Display"

# Create local rendering device to run compute shaders on
var rd := RenderingServer.create_local_rendering_device()
var shader_rid: RID
@export_file("*.glsl") var shader_file: String
var render_rid: RID
var uniform_set: RID
var pipeline: RID

func _ready() -> void:
	viewport_dimensions.x = ProjectSettings.get_setting("display/window/size/viewport_width")
	viewport_dimensions.y = ProjectSettings.get_setting("display/window/size/viewport_height")
	
	output_display.image_size = viewport_dimensions
	output_display.init_texture()
	
	setup_compute()
	render()
	
func _process(delta: float) -> void:
	pass

func render():
	if pipeline == null:
		setup_compute()
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	# Dispatch one workgroup for every 8x8 block of pixels here. This ratio is highly tunable, and performance may vary.
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
	
	# Create the set of uniforms from list of created uniforms and shader RID
	uniform_set = rd.uniform_set_create([render_uniform], shader_rid, 0)
	# Create compute shader pipeline
	pipeline = rd.compute_pipeline_create(shader_rid)

# Import, compile and load shader, return reference.
func load_shader(p_rd: RenderingDevice, path: String) -> RID:
	var shader_file_data: RDShaderFile = load(path)
	var shader_spirv: RDShaderSPIRV = shader_file_data.get_spirv()
	return p_rd.shader_create_from_spirv(shader_spirv)
