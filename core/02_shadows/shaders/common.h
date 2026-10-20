// 02_shadows — shared MSL declarations.
//
// Every struct here has a matching C++ struct in src/renderer.mm. Keep the
// field order identical: the uniforms are uploaded with setBytes, so the GPU
// sees the C++ memory layout directly.

#ifndef NX_SHADOW_COMMON_H
#define NX_SHADOW_COMMON_H

#include <metal_stdlib>
using namespace metal;

// Vertex buffers are raw arrays of six floats per vertex:
//   [px, py, pz, nx, ny, nz]
// The shaders index them explicitly instead of casting to a struct. A struct
// layout mismatch between C++ and MSL is invisible in review and produces
// spectacularly skewed triangles; explicit offsets make it impossible.

struct CameraUniforms {
    float4x4 view_proj;
};

struct DrawUniforms {
    float4 albedo;
};

// params0 = (bias_ndc, normal_offset_world, shadow_size, unused)
// params1 = (taps, filter_mode, near, far)
struct VisibilityUniforms {
    float4x4 inv_view_proj;
    float4x4 light_view_proj;
    float4   light_direction;  // propagation direction, Mitsuba convention
    float4   film;             // width, height, 1/width, 1/height
    float4   params0;
    float4   params1;
};

struct ShadingUniforms {
    float4 light_direction;
    float4 irradiance;
    float4 params;  // ambient, unused, unused, unused
};

struct DebugUniforms {
    float4 params;  // mode, near, far, unused
};

#endif
