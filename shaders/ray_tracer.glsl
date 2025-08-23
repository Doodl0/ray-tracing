#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Uniform to render image to write and read
layout(rgba32f, binding = 0) uniform image2D image_render;

// Binding to camera data buffer
layout(set = 0, binding = 1, std430) restrict buffer CameraData {
    mat4 camera_to_world;
    mat4 camera_projection;
}
camera_data;

// Sky sampler uniform
layout(set = 0, binding = 2) uniform sampler2D sky_texture;

// Directional light data
layout(set = 0, binding = 3, std430) restrict buffer DirectionalLight {
    vec4 data;
}
directional_light;

// Antialiasing data buffer
layout(set = 0, binding = 4, std430) restrict buffer AntialiasData {
    vec2 offset;
    int current_sample;
}
aa_data;

struct Sphere
{
    vec3 position;
    float radius;
    vec3 albedo;
    float specular;
};

layout(set = 0, binding = 5, std430) restrict buffer Spheres {
    Sphere spheres[];
}
spheres;

struct Ray {
    vec3 origin;
    vec3 direction;
    vec3 energy;
};

struct RayHit
{
    vec3 position;
    float distance;
    vec3 normal;
    vec3 albedo;
    vec3 specular;
};

const float PI = 3.14159265f;
const float INF = 99999999.0;

Ray CreateRay(vec3 origin, vec3 direction) {
    Ray ray;
    ray.origin = origin;
    ray.direction = direction;
    ray.energy = vec3(1.0f, 1.0f, 1.0f);
    return ray;
}

Ray CreateCameraRay(vec2 uv) {
    // Transform the camera origin to world space
    vec3 origin = camera_data.camera_to_world[3].xyz;
    
    // Invert the perspective projection of the view-space position
    vec3 direction = (camera_data.camera_projection * vec4(uv, 0.0, 1.0)).xyz;
    // Transform the direction from camera to world space and normalize
    direction = (camera_data.camera_to_world * vec4(direction, 0.0)).xyz;
    direction = normalize(direction);
    return CreateRay(origin, direction);
}

RayHit CreateRayHit() {
    RayHit hit;
    hit.position = vec3(0.0f, 0.0f, 0.0f);
    hit.distance = INF;
    hit.normal = vec3(0.0f, 0.0f, 0.0f);
    hit.albedo = vec3(0.0f, 0.0f, 0.0f);
    hit.specular = vec3(0.0f, 0.0f, 0.0f);
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

void IntersectSphere(Ray ray, inout RayHit bestHit, Sphere sphere)
{
    // Calculate distance along the ray where the sphere is intersected
    vec3 d = ray.origin - sphere.position;
    float p1 = -dot(ray.direction, d);
    float p2sqr = p1 * p1 - dot(d, d) + sphere.radius * sphere.radius;
    if (p2sqr < 0)
        return;
    float p2 = sqrt(p2sqr);
    float t = p1 - p2 > 0 ? p1 - p2 : p1 + p2;
    if (t > 0 && t < bestHit.distance)
    {
        bestHit.distance = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = normalize(bestHit.position - sphere.position);
        bestHit.albedo = sphere.albedo;
        vec3 specular = vec3(sphere.specular, sphere.specular, sphere.specular);
        bestHit.specular = specular;
    }
}

RayHit Trace(Ray ray)
{
    RayHit bestHit = CreateRayHit();
    //IntersectGroundPlane(ray, bestHit);
    // Add a floating unit sphere
    for (int i = 0; i <= spheres.spheres.length(); i++)
	{
		Sphere sphere = spheres.spheres[i];
		IntersectSphere(ray, bestHit, sphere);
	}
    return bestHit;
}

vec3 Shade(inout Ray ray, RayHit hit) {
    if (hit.distance < INF) {
        // Reflect the ray and multiply energy with specular reflection
        ray.origin = hit.position + hit.normal * 0.001f;
        ray.direction = reflect(ray.direction, hit.normal);
        ray.energy *= hit.specular;

        // Shadow test ray
        bool shadow = false;
        Ray shadowRay = CreateRay(hit.position + hit.normal * 0.001f, -1 * directional_light.data.xyz);
        RayHit shadowHit = Trace(shadowRay);
        if (shadowHit.distance != INF)
        {
            return vec3(0.0f, 0.0f, 0.0f);
        }
        
        // Return a diffuse-shaded color
        return clamp(dot(hit.normal, directional_light.data.xyz) * -1, 0.0f, 1.0f) * directional_light.data.w * hit.albedo;
    }
    else {
        // Erase the ray's energy - the sky doesn't reflect anything
        ray.energy = vec3(0.0f, 0.0f, 0.0f);
        float theta = acos(ray.direction.y) / -PI;
        float phi = atan(ray.direction.x, -ray.direction.z) / -PI * 0.5f;
        vec4 result = texture(sky_texture, vec2(phi, -theta));
        return result.xyz;
    }
}

vec4 aa(vec4 pixel, ivec2 pos) {
    if (aa_data.current_sample < 1) {
        return pixel;
    }
	vec4 frame_sample = imageLoad(image_render, pos);
    float alpha = 1.0f / float(aa_data.current_sample + 1);
	return mix(frame_sample, pixel, alpha);
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

    for (int i = 0; i < 8; i++)
    {
        RayHit hit = Trace(ray);
        result += ray.energy * Shade(ray, hit);
        if (!any(bvec3(ray.energy)))
            break;
    }

    imageStore(image_render, pos, aa(vec4(result, 1.0), pos.xy));
}

