// 02_shadows — shared Lambertian direct lighting.
//
// The light unit convention is Mitsuba's: a directional emitter's irradiance is
// measured on a surface perpendicular to the light, so the outgoing radiance of
// a diffuse surface is albedo/pi * irradiance * max(dot(n, -direction), 0).
// Visibility only scales that term; the shading model is never changed between
// variants, which is what makes the comparison about shadows rather than about
// lighting.

#include "common.h"

kernel void shading_main(texture2d<float, access::read> albedo [[texture(0)]],
                         texture2d<float, access::read> normal [[texture(1)]],
                         texture2d<float, access::read> visibility [[texture(2)]],
                         texture2d<float, access::write> color [[texture(3)]],
                         constant ShadingUniforms& u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    const float3 a = albedo.read(gid).rgb;
    const float3 n = normal.read(gid).xyz;
    const float v = visibility.read(gid).r;
    const float ndotl = saturate(dot(n, -u.light_direction.xyz));
    const float3 radiance = a / M_PI_F * u.irradiance.xyz * ndotl * v;
    color.write(float4(radiance, 1.0), gid);
}
