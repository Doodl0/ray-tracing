#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Uniform to render image to write and read
layout(rgba32f, binding = 0) uniform image2D image_render;

// Binding to camera data buffer
layout(set = 0, binding = 1, std430) restrict buffer CameraData {
    mat4 CameraToWorld;
    mat4 CameraProjection;
}
camera_data;

// Antialiasing data buffer
layout(set = 0, binding = 2, std430) restrict buffer AntialiasData {
    vec2 offset;
    int current_sample;
}
aa_data;

struct Ray {
    vec3 origin;
    vec3 direction;
};

struct RayHit
{
    vec3 position;
    float distance;
    vec3 normal;
};

const float PI = 3.14159265f;
const float INF = 99999999.0;
const vec3 sky_color = vec3(0.761, 0.965, 1);

Ray CreateRay(vec3 origin, vec3 direction) {
    Ray ray;
    ray.origin = origin;
    ray.direction = direction;
    return ray;
}

Ray CreateCameraRay(vec2 uv) {
    // Transform the camera origin to world space
    vec3 origin = camera_data.CameraToWorld[3].xyz;
    
    // Invert the perspective projection of the view-space position
    vec3 direction = (camera_data.CameraProjection * vec4(uv, 0.0, 1.0)).xyz;
    // Transform the direction from camera to world space and normalize
    direction = (camera_data.CameraToWorld * vec4(direction, 0.0)).xyz;
    direction = normalize(direction);
    return CreateRay(origin, direction);
}

RayHit CreateRayHit() {
    RayHit hit;
    hit.position = vec3(0.0f, 0.0f, 0.0f);
    hit.distance = INF;
    hit.normal = vec3(0.0f, 0.0f, 0.0f);
    return hit;
}

void IntersectGroundPlane(Ray ray, inout RayHit bestHit) {
    // Calculate distance along the ray where the ground plane is intersected
    float t = -ray.origin.y / ray.direction.y;
    if (t > 0 && t < bestHit.distance) {
        bestHit.distance = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = vec3(0.0f, 1.0f, 0.0f);
    }
}

void IntersectSphere(Ray ray, inout RayHit bestHit, vec4 sphere)
{
    // Calculate distance along the ray where the sphere is intersected
    vec3 d = ray.origin - sphere.xyz;
    float p1 = -dot(ray.direction, d);
    float p2sqr = p1 * p1 - dot(d, d) + sphere.w * sphere.w;
    if (p2sqr < 0)
        return;
    float p2 = sqrt(p2sqr);
    float t = p1 - p2 > 0 ? p1 - p2 : p1 + p2;
    if (t > 0 && t < bestHit.distance)
    {
        bestHit.distance = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = normalize(bestHit.position - sphere.xyz);
    }
}

RayHit Trace(Ray ray)
{
    RayHit bestHit = CreateRayHit();
    IntersectGroundPlane(ray, bestHit);
    // Add a floating unit sphere
    IntersectSphere(ray, bestHit, vec4(0, 3.0f, 0, 1.0f));
    return bestHit;
}

vec3 Shade(inout Ray ray, RayHit hit) {
    if (hit.distance < INF) {
        // Return the normal
        return hit.normal;
    }
    else {
        return sky_color;
    }
}

void aa(ivec2 pos) {
	vec4 overlay = vec4(imageLoad(image_render, pos).rgb, (1.0f / float(aa_data.current_sample + 1)));
	imageStore(image_render, pos, overlay);;
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = imageSize(image_render);
    
    // Transform pixels to [-1, 1] range
    vec2 uv = vec2((pos.xy + aa_data.offset) / vec2(image_size) * 2.0f - 1.0f);

    // Create a ray for the UVs
    Ray ray = CreateCameraRay(uv);

    RayHit hit = Trace(ray);
    vec3 result = Shade(ray, hit);

    imageStore(image_render, pos, vec4(result, 1.0));

    aa(pos);
}

