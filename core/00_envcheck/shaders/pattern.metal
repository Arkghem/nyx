// 00_envcheck — proves the native toolchain works end to end.
//
// Renders a procedural pattern with a Metal compute kernel into a shared
// texture, reads it back, writes a linear EXR, and reports which optional
// capabilities this machine actually has (GPU timestamp counters in
// particular, since nx::profile degrades to wall-clock timing without them).

#include <metal_stdlib>
using namespace metal;

struct Parameters {
    int   width;
    int   height;
    float time;
};

kernel void pattern_fill(texture2d<float, access::write> target [[texture(0)]],
                         constant Parameters&               params [[buffer(0)]],
                         uint2                              gid    [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }

    const float2 uv = (float2(gid) + 0.5f) / float2(params.width, params.height);

    // A radial gradient multiplied by a checkerboard: smooth enough that a
    // wrong colour pipeline shows up, structured enough that a wrong sampling
    // convention shows up as well.
    const float2 centred = uv * 2.0f - 1.0f;
    const float  radial  = saturate(1.0f - length(centred));
    const float  checker = fmod(floor(uv.x * 16.0f) + floor(uv.y * 16.0f), 2.0f);

    const float3 colour = float3(radial, radial * checker, 0.5f + 0.5f * checker);

    // Alpha stays 1: nyx compares linear light and alpha is not a signal.
    target.write(float4(colour, 1.0f), gid);
}
