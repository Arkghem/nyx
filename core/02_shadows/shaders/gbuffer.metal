// 02_shadows — G-buffer pass.
//
// Color target 0: (world normal, NDC depth). The depth in alpha is what the
// visibility compute reconstructs the world position from, and it is also what
// the depth debug view shows.
// Color target 1: albedo.

#include "common.h"

struct Varying {
    float4 position [[position]];
    float4 normal;
    float4 albedo;
};

vertex Varying gbuffer_vertex(uint vid [[vertex_id]],
                              device const float* vertices [[buffer(0)]],
                              constant CameraUniforms& camera [[buffer(1)]],
                              constant DrawUniforms& draw [[buffer(2)]]) {
    const uint base = vid * 6u;
    const float3 position = float3(vertices[base + 0], vertices[base + 1], vertices[base + 2]);
    const float3 normal = float3(vertices[base + 3], vertices[base + 4], vertices[base + 5]);

    Varying out;
    out.position = camera.view_proj * float4(position, 1.0);
    out.normal = float4(normalize(normal), 1.0);
    out.albedo = draw.albedo;
    return out;
}

struct GBufferOut {
    float4 normal [[color(0)]];
    float4 albedo [[color(1)]];
};

fragment GBufferOut gbuffer_fragment(Varying in [[stage_in]]) {
    GBufferOut out;
    // `in.position.z` is the rasterized depth in [0, 1] after the viewport
    // transform, which is exactly what the projection writes.
    out.normal = float4(normalize(in.normal.xyz), in.position.z);
    out.albedo = in.albedo;
    return out;
}
