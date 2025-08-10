class_name RenderOutput extends TextureRect

var image_size: Vector2i

func init_texture():
	var image = Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGBAF)
	var image_texture = ImageTexture.create_from_image(image)
	texture = image_texture


func display_render(data: PackedByteArray):
	var render_image := Image.create_from_data(image_size.x, image_size.y, false, Image.FORMAT_RGBAF, data)
	texture.update(render_image)
