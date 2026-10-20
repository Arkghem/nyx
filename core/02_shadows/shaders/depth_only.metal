// 02_shadows — depth-only pass used to build the shadow map.
//
// There is no color attachment. The fragment function is intentionally empty;
// if a driver ever rejects a pipeline without a fragment output, the fallback
// is a one-pixel dummy target, which would show up immediately in the stats.

#include "common.h"

struct DepthVarying {
    float4 position [[position]];
};

vertex DepthVarying depth_vertex(uint vid [[vertex_id]],
                                 device const float* vertices [[buffer(0)]],
                                 constant CameraUniforms& camera [[buffer(1)]]) {
    const uint base = vid * 6u;
    const float3 position = float3(vertices[base + 0], vertices[base + 1], vertices[base + 2]);

    DepthVarying out;
    out.position = camera.view_proj * float4(position, 1.0);
    return out;
}

fragment void depth_fragment(DepthVarying in [[stage_in]]) {
    (void)in;
}
