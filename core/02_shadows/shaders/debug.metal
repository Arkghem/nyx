// 02_shadows — debug output.
//
// mode 0: albedo
// mode 1: world normal
// mode 2: linearized camera depth
// mode 3: visibility
//
// This is how the camera/geometry/lighting calibration is inspected before any
// shadow number is trusted.

#include "common.h"

kernel void debug_main(texture2d<float, access::read> albedo [[texture(0)]],
                       texture2d<float, access::read> normal [[texture(1)]],
                       texture2d<float, access::read> visibility [[texture(2)]],
                       texture2d<float, access::write> color [[texture(3)]],
                       constant DebugUniforms& u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    const int mode = int(u.params.x + 0.5);
    float3 value = float3(0.0);

    if (mode == 0) {
        value = albedo.read(gid).rgb;
    } else if (mode == 1) {
        value = normal.read(gid).xyz * 0.5 + 0.5;
    } else if (mode == 2) {
        const float depth = normal.read(gid).w;
        const float near_plane = u.params.y;
        const float far_plane = u.params.z;
        const float linear = (near_plane * far_plane) /
                             (depth * (near_plane - far_plane) + far_plane);
        value = float3(linear / far_plane);
    } else {
        value = float3(visibility.read(gid).r);
    }

    color.write(float4(clamp(value, 0.0, 1.0), 1.0), gid);
}
