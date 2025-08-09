#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, binding = 0) uniform image2D image_render;

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = imageSize(image_render);
    vec4 colour = vec4(float(pos.x) / float(image_size.x), float(pos.y) / float(image_size.y), 0, 1);
    imageStore(image_render, pos, colour);
}