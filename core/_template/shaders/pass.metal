// Template experiment shader.
//
// Writes a cheap procedural pattern so that a freshly created experiment both
// compiles and produces visibly non-trivial output.
//
// Output goes to a device buffer of float4. For shading work the natural next
// step is to swap this for a texture2d<float, access::write> render target.

#include <metal_stdlib>
using namespace metal;

struct Parameters {
    int width;
    int height;
};

kernel void template_fill(device float4*                 target [[buffer(0)]],
                          constant Parameters&           params [[buffer(1)]],
                          uint2                          gid    [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    const float2 uv = float2(gid.x, gid.y) / float2(params.width, params.height);
    const float  checker = fmod(floor(uv.x * 8.0f) + floor(uv.y * 8.0f), 2.0f);

    target[gid.y * uint(params.width) + gid.x] = float4(uv.x, uv.y, checker, 1.0f);
}
