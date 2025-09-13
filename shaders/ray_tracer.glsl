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
layout(set = 0, binding = 3, std430) restrict buffer SceneInfo {
    vec4 directional_light;
    float seed;
}
scene_info;

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
    vec3 emission;
    float smoothness;
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
    float smoothness;
    vec3 emission;
};

const float PI = 3.14159265f;
const float INF = 99999999.0;

float rand()
{
    float result = fract(sin(scene_info.seed / INF * dot(vec2(gl_GlobalInvocationID.xy), vec2(12.9898f, 78.233f))) * 43758.5453f);
    scene_info.seed += 1.0f;
    return result;
}

float energy(vec3 colour) {
    float third = 1.0f / 3.0f;
    return dot(colour, vec3(third, third, third));
}

float SmoothnessToPhongAlpha(float s)
{
    return pow(1000.0f, s * s);
}

mat3 GetTangentSpace(vec3 normal) {
    // Choose a helper vector for the cross product
    vec3 helper = vec3(1, 0, 0);
    if (abs(normal.x) > 0.99f)
        helper = vec3(1, 0, 0);
    
    // Generate vectors
    vec3 tangent = normalize(cross(normal, helper));
    vec3 binormal = normalize(cross(normal, tangent));
    return mat3(tangent, binormal, normal);
}

vec3 SampleHemisphere(vec3 normal, float alpha) {
    // Uniformly sample hemisphere direction, where alpha determines the kind of the sampling
    float cos_theta = pow(rand(), 1.0f/ (alpha + 1.0f));
    float sin_theta = sqrt(1.0f - cos_theta * cos_theta);
    float phi = 2 * PI * rand();
    vec3 tangent_space_dir = vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
    // Transform direction to world space
    return GetTangentSpace(normal) * tangent_space_dir;
}

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
    hit.smoothness = 0.0f;
    hit.emission = vec3(0.0f, 0.0f, 0.0f);
    return hit;
}

void IntersectGroundPlane(Ray ray, inout RayHit bestHit) {
    // Calculate distance along the ray where the ground plane is intersected
    float t = -ray.origin.y / ray.direction.y;
    if (t > 0 && t < bestHit.distance) {
        bestHit.distance = t;
        bestHit.position = ray.origin + t * ray.direction;
        bestHit.normal = vec3(0.0f, 1.0f, 0.0f);
        bestHit.albedo = vec3(0.5f, 0.5f, 0.5f);
        bestHit.specular = vec3(0.0f, 0.0f, 0.0f);
        bestHit.smoothness = 0.25f;
        bestHit.emission = vec3(0.0f, 0.0f, 0.0f);
    }
}

void IntersectSphere(Ray ray, inout RayHit bestHit, Sphere sphere) {
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
        bestHit.smoothness = sphere.smoothness;
        bestHit.emission = sphere.emission;
    }
}

RayHit Trace(Ray ray) {
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

float sdot(vec3 x, vec3 y)
{
    float f = 1.0f;
    return clamp(dot(x, y) * f,  0.0f, 1.0f);
}

float sdot(vec3 x, vec3 y, float f)
{
    return clamp(dot(x, y) * f,  0.0f, 1.0f);
}

vec3 Shade(inout Ray ray, RayHit hit) {
    if (hit.distance < INF) {
        // Calculate chance of diffuse and specular reflection
        hit.albedo = min(1.0f - hit.specular, hit.albedo);
        float spec_chance = energy(hit.specular);
        float diff_chance = energy(hit.albedo);
        float sum = spec_chance + diff_chance;
        spec_chance /= sum;
        diff_chance /= sum;

        // Roulette-select the ray's path
        float roulette = rand();
        if (roulette < spec_chance) {
            // Specular reflection
            float alpha = SmoothnessToPhongAlpha(hit.smoothness);
            ray.origin = hit.position + hit.normal + 0.001f;
            ray.direction = SampleHemisphere(reflect(ray.direction, hit.normal), alpha);
            float f = (alpha + 2) / (alpha + 1);
            ray.energy *= (1.0f/ spec_chance) * hit.specular * sdot(hit.normal, ray.direction, f);
        }
        else {
            // Diffuse reflection
            ray.origin = hit.position + hit.normal * 0.001f;
            ray.direction = SampleHemisphere(hit.normal, 1.0f);
            ray.energy *= (1.0f / diff_chance) * hit.albedo;
        }

        return hit.emission;
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

void ConvergeSamples(inout vec4 pixel, ivec2 pos) {
    vec4 texel = imageLoad(image_render, pos);
    vec4 a = texel * float(aa_data.current_sample - 1) / float(aa_data.current_sample);
    vec4 b = pixel * 1.0f / float(aa_data.current_sample);
    pixel = a + b;
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = imageSize(image_render);
    
    // Transform pixels to [-1, 1] range
    vec2 uv = vec2(vec2(pos.xy + aa_data.offset) / vec2(image_size) * 2.0f - 1.0f);

    // Create a ray for the UVs
    Ray ray = CreateCameraRay(uv);

    vec3 result = vec3(0, 0, 0);
    for (int i = 0; i < 8; i++)
    {
        RayHit hit = Trace(ray);
        result += ray.energy * Shade(ray, hit);
        if (!any(bvec3(ray.energy)))
            break;
    }

    vec4 pixel = vec4(result, 1.0f);

    if (aa_data.current_sample > 1) {
        ConvergeSamples(pixel, pos);
    }

    imageStore(image_render, pos, pixel);
    //imageStore(image_render, pos, vec4(rand(), rand(), rand(), 1.0));
}

