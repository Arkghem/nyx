// 02_shadows — visibility resolve.
//
// The receiver's world position is reconstructed from the G-buffer normal/depth
// target, projected into light space, and compared against the shadow map.
// A box of `taps x taps` depth comparisons produces either the binary hard
// shadow (taps = 1) or the PCF estimate (taps = 3, 5, ...).
//
// Important convention: the shadow map was rendered through a Metal render
// pass, whose viewport flips y. Texture v therefore runs opposite to the light
// projection's y. `map_uv.y = 1 - ...` below is that flip, not a bug.

#include "common.h"

kernel void visibility_main(texture2d<float, access::read> normal_depth [[texture(0)]],
                            depth2d<float, access::sample> shadow_map [[texture(1)]],
                            texture2d<float, access::write> visibility [[texture(2)]],
                            constant VisibilityUniforms& u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const int width = int(u.film.x + 0.5);
    const int height = int(u.film.y + 0.5);
    if (int(gid.x) >= width || int(gid.y) >= height) {
        return;
    }

    const float4 normal_depth_value = normal_depth.read(gid);
    const float depth = normal_depth_value.w;

    // Cleared alpha means background: no receiver, so it is not shadowed.
    if (depth <= 0.0) {
        visibility.write(float4(1.0), gid);
        return;
    }

    const float2 uv = (float2(gid) + 0.5) / float2(u.film.x, u.film.y);
    const float3 ndc = float3(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth);
    const float4 world_h = u.inv_view_proj * float4(ndc, 1.0);
    float3 world = world_h.xyz / world_h.w;

    const float3 normal = normalize(normal_depth_value.xyz);
    if (u.params0.y > 0.0 && dot(normal, -u.light_direction.xyz) > 0.0) {
        world += normal * u.params0.y;
    }

    const float4 light_clip = u.light_view_proj * float4(world, 1.0);
    if (light_clip.w <= 0.0) {
        // Behind the light's near plane: no occluder information, treat as lit.
        visibility.write(float4(1.0), gid);
        return;
    }

    const float3 light_ndc = light_clip.xyz / light_clip.w;
    float2 map_uv = light_ndc.xy * 0.5 + 0.5;
    map_uv.y = 1.0 - map_uv.y;
    if (map_uv.x < 0.0 || map_uv.x > 1.0 || map_uv.y < 0.0 || map_uv.y > 1.0) {
        visibility.write(float4(1.0), gid);
        return;
    }

    const sampler shadow_sampler = sampler(coord::normalized,
                                           address::clamp_to_edge,
                                           filter::nearest);
    const float receiver = light_ndc.z;
    const int taps = int(u.params1.x + 0.5);
    const int radius = taps / 2;
    const float inv_shadow_size = 1.0 / u.params0.z;

    float lit = 0.0;
    float samples = 0.0;
    for (int y = -radius; y <= radius; ++y) {
        for (int x = -radius; x <= radius; ++x) {
            const float2 sample_uv = map_uv + float2(float(x), float(y)) * inv_shadow_size;
            const float stored = shadow_map.sample(shadow_sampler, sample_uv);
            lit += (receiver <= stored + u.params0.x) ? 1.0 : 0.0;
            samples += 1.0;
        }
    }

    visibility.write(float4(lit / samples, 0.0, 0.0, 1.0), gid);
}

// Used by the `lit` calibration variant: everything is visible.
kernel void visibility_fill(texture2d<float, access::write> visibility [[texture(0)]],
                            constant VisibilityUniforms& u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const int width = int(u.film.x + 0.5);
    const int height = int(u.film.y + 0.5);
    if (int(gid.x) >= width || int(gid.y) >= height) {
        return;
    }
    visibility.write(float4(1.0), gid);
}
