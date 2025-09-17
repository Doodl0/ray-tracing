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
    float current_sample;
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

struct MeshObject {
    // Make sure struct is a multiple of 16 bytes for memory alignment
    mat4 local_to_world_matrix; // 64 bytes
    vec3 albedo; // 12 bytes - 76 total
    float specular; // 4 bytes - 80 total
    vec3 emission;  // 12 bytes - 92 total
    float smoothness; // 4 bytes - 96 total
    vec4 bboxpos; // 16 bytes - 120 total
    vec4 bboxend; // 16 bytes - 120 total
    uint vertices_index; // 4 bytes - 124 total
    uint vertices_length; // 4 bytes - 128 total
    int padding[2];
};

layout(set = 0, binding = 5, std430) restrict buffer Spheres {
    Sphere spheres[];
}
spheres;

layout(set = 0, binding = 6, std430) restrict buffer MeshObjects {
    MeshObject meshes[];
}
mesh_objects;

layout(set = 0, binding = 7, std430) restrict buffer Vertices {
    vec4 triangles[];
}
vertices;

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
const float EPSILON = 1e-8;

float rand()
{
    scene_info.seed += 1.0f;
    float result = fract(sin(float(scene_info.seed) / 1000.0f * dot(vec2(gl_GlobalInvocationID.xy), vec2(12.9898f, 78.233f))) * 43758.5453f);
    return result;
}

float energy(vec3 colour) {
    float third = 1.0f / 3.0f;
    return dot(colour, vec3(third, third, third));
}

float sdot(vec3 x, vec3 y)
{
    float f = 1.0f;
    return clamp(dot(x, y) * f,  0.0, 1.0);
}

float sdot(vec3 x, vec3 y, float f)
{
    return clamp(dot(x, y) * f,  0.0, 1.0);
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
        bestHit.specular = vec3(1.0f, 1.0f, 1.0f);
        bestHit.smoothness = 1.0f;
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

bool IntersectTriangle_MT97(Ray ray, vec3 vert0, vec3 vert1, vec3 vert2, inout float t, inout float u, inout float v) {
    // Find vectors for 2 edges sharing vert0
    vec3 edge1 = vert1 - vert0;
    vec3 edge2 = vert2 - vert0;

    // Begin calculating determinant - also used to calculate U parameter
    vec3 pvec = cross(ray.direction, edge2);

    // If determinant is near zero, ray lies in plane of triangle
    float det = dot(edge1, pvec);

    // Use backface culling
    if (det < EPSILON) {
        return false;
    }
    float inv_det = 1.0 / det;

    // Calculate distance from vert0 to ray origin
    vec3 tvec = ray.origin - vert0;

    // Calculate U parameter and test bounds
    u = dot(tvec, pvec) * inv_det;
    if (u < 0.0 || u > 1.0) {
        return false;
    }

    // Prepare to test V parameter
    vec3 qvec = cross(tvec, edge1);

    // Calculate V parameter and test bounds
    v = dot(ray.direction, qvec) * inv_det;
    if (v < 0.0 || u + v > 1.0) {
        return false;
    }

    // Calculate t, ray interects triangle
    t = dot(edge2, qvec) * inv_det;

    return true;
}

bool IntersectAABB(Ray ray, MeshObject meshObject) {
    vec3 dirfrac;
    dirfrac.x = 1.0f / ray.direction.x;
    dirfrac.y = 1.0f / ray.direction.y;
    dirfrac.z = 1.0f / ray.direction.z;

    vec4 lb = meshObject.local_to_world_matrix * vec4(meshObject.bboxpos.x, meshObject.bboxpos.y, meshObject.bboxpos.z, 1.0);
    vec4 rt = meshObject.local_to_world_matrix * vec4(meshObject.bboxend.x, meshObject.bboxend.y, meshObject.bboxend.z, 1.0);

    float t1 = (lb.x - ray.origin.x)*dirfrac.x;
    float t2 = (rt.x - ray.origin.x)*dirfrac.x;
    float t3 = (lb.y - ray.origin.y)*dirfrac.y;
    float t4 = (rt.y - ray.origin.y)*dirfrac.y;
    float t5 = (lb.z - ray.origin.z)*dirfrac.z;
    float t6 = (rt.z - ray.origin.z)*dirfrac.z;

    float tmin = max(max(min(t1, t2), min(t3, t4)), min(t5, t6));
    float tmax = min(min(max(t1, t2), max(t3, t4)), max(t5, t6));

    // if tmax < 0, the ray is intersecting AABB, but the whole AABB is behind us
    if (tmax < 0)
    {
        return false;
    }

    // if tmin > tmax, ray doesn't intersect AABB
    if (tmin > tmax)
    {
        return false;
    }

    return true;
}

void IntersectMesh(Ray ray, inout RayHit bestHit, MeshObject meshObject) {
    // AABB intersection before checking every triangle for perfomance
    if (!IntersectAABB(ray, meshObject)) {
        return;
    }

    uint vindex = meshObject.vertices_index;
    uint vlength = vindex + meshObject.vertices_length;

    for(uint i = vindex; i < vlength; i += 3) {
        // Godot renders triangles clockwise so inverse order
        vec3 v0 = (meshObject.local_to_world_matrix * vertices.triangles[i + 2]).xyz;
        vec3 v1 = (meshObject.local_to_world_matrix * vertices.triangles[i + 1]).xyz;
        vec3 v2 = (meshObject.local_to_world_matrix * vertices.triangles[i]).xyz;

        float t, u, v;

        if (IntersectTriangle_MT97(ray, v0, v1, v2, t, u, v)) {
            if (t > 0 && t < bestHit.distance) {
                bestHit.distance = t;
                bestHit.position = ray.origin + t * ray.direction;
                bestHit.normal = normalize(cross(v1 - v0, v2 - v0));
                bestHit.albedo = meshObject.albedo;
                bestHit.specular = vec3(meshObject.specular, meshObject.specular, meshObject.specular);
                bestHit.smoothness = meshObject.smoothness;
                bestHit.emission = meshObject.emission;
            }
        }
    }
}

RayHit Trace(Ray ray) {
    RayHit bestHit = CreateRayHit();
    IntersectGroundPlane(ray, bestHit);
    // Trace spheres
    for (uint i = 0; i <= spheres.spheres.length(); i++) {
		Sphere sphere = spheres.spheres[i];
		IntersectSphere(ray, bestHit, sphere);
	}

    // Trace meshes
    for (uint i = 0; i <= mesh_objects.meshes.length(); i++) {
        MeshObject mesh = mesh_objects.meshes[i];
        IntersectMesh(ray, bestHit, mesh);
    }

    return bestHit;
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
    // Troubleshooting - Pixels sometimes return completely black and stay so, think it's due to texel. so just return original colour instead
    if (isnan(texel.x) || isnan(texel.y) || isnan(texel.z) || isnan(texel.w)) {
        return;
    }
    vec4 a = texel * (aa_data.current_sample - 1.0f) / aa_data.current_sample;
    vec4 b = pixel / aa_data.current_sample;
    pixel = a + b;
    
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = imageSize(image_render);
    
    // Transform pixels to [-1, 1] range
    vec2 uv = vec2(vec2(pos.xy + aa_data.offset) / vec2(image_size) * 2.0f - 1.0f);

    // Create a ray for the UVs
    Ray ray = CreateCameraRay(uv);
    RayHit hit = Trace(ray);

    vec3 result = Shade(ray, hit);
    for (int i = 0; i < 8; i++)
    {
        hit = Trace(ray);
        result += ray.energy * Shade(ray, hit);
        if (!any(bvec3(ray.energy))) {
            break;
        }
    }

    vec4 pixel = vec4(result, 1.0);
    pixel.x = clamp(pixel.x, 0.0, 1.0);
    pixel.y = clamp(pixel.y, 0.0, 1.0);
    pixel.z = clamp(pixel.z, 0.0, 1.0);
    
    if (aa_data.current_sample > 1.0) {
        ConvergeSamples(pixel, pos);
    }

    //pixel = vec4(mesh_objects.meshes[0].emission, 1.0);

    imageStore(image_render, pos, pixel);
    //imageStore(image_render, pos, vec4(rand(), rand(), rand(), 1.0));
}

