// 01_perf_probe shaders.
//
// Two kernels whose cost is controlled by the host, so the benchmark has a
// tunable signal instead of measuring an empty dispatch.

#include <metal_stdlib>
using namespace metal;

struct Parameters {
    int   width;
    int   height;
    int   iterations;
    float seed;
};

// A dependent chain of multiply-adds: not optimised away, and its runtime scales
// linearly with `iterations`.
static inline float burn(float value, int iterations)
{
    float accumulator = value;
    for (int i = 0; i < iterations; ++i) {
        accumulator = fma(accumulator, 1.000001f, 0.000001f);
    }
    return accumulator;
}

kernel void probe_pass_a(device float4*       target [[buffer(0)]],
                         constant Parameters& params [[buffer(1)]],
                         uint2                gid    [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }
    const uint index = gid.y * uint(params.width) + gid.x;
    const float value = burn(params.seed + float(index), params.iterations);
    target[index] = float4(value, value * 0.5f, 0.25f, 1.0f);
}

kernel void probe_pass_b(device float4*       target [[buffer(0)]],
                         constant Parameters& params [[buffer(1)]],
                         uint2                gid    [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) {
        return;
    }
    const uint index = gid.y * uint(params.width) + gid.x;
    const float value = burn(params.seed * 2.0f + float(index), params.iterations);
    target[index] = float4(0.25f, value * 0.5f, value, 1.0f);
}
