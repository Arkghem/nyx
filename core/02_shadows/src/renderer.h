// 02_shadows — the realtime Metal renderer.
//
// The renderer is intentionally small and fixed: a G-buffer pass, a shadow
// data pass, a visibility resolve and a shared Lambertian shading pass. All
// variants differ only in the shadow/visibility stages, which is what makes the
// timing and quality comparison meaningful.
//
// The G-buffer's normal target stores (world normal, NDC depth) in its four
// channels. Keeping the depth there means the visibility compute never has to
// read a depth attachment and the debug view gets the same value the shadow
// lookup used.

#pragma once

#import <Metal/Metal.h>

#include "math.h"
#include "options.h"
#include "scene.h"

#include <functional>
#include <map>
#include <string>
#include <vector>

namespace nx::shadow {

struct ShadowStats {
    int    width = 0;
    int    height = 0;
    int    shadow_size = 0;
    int    taps = 1;
    int    cascades = 1;
    double triangles = 0.0;
    double draw_calls = 0.0;
    double shadow_map_bytes = 0.0;
    double shadow_map_texels = 0.0;
    double gbuffer_bytes = 0.0;
    double texel_world = 0.0;
};

struct FrameTiming {
    double gpu_ms = 0.0;
    double cpu_ms = 0.0;
    std::map<std::string, double> passes;
};

class Renderer {
public:
    Renderer() = default;
    ~Renderer() = default;

    bool init(const Scene& scene, const Options& options, std::string* error);
    bool render_frame(bool per_pass, int iterations, FrameTiming* timing,
                      std::string* error);

    id<MTLTexture> color_texture() const { return color_texture_; }
    id<MTLTexture> visibility_texture() const { return visibility_texture_; }
    std::string    device_name() const;
    bool           has_visibility() const { return use_visibility_; }
    bool           gpu_time_available() const { return gpu_time_available_; }
    int            width() const { return width_; }
    int            height() const { return height_; }
    const ShadowStats& stats() const { return stats_; }
    const Mat4&    light_view_projection() const { return light_view_proj_; }

private:
    struct GpuMesh {
        id<MTLBuffer> vertices = nil;
        id<MTLBuffer> indices = nil;
        NSUInteger    index_count = 0;
        Vec4          albedo;
    };

    bool create_pipelines(std::string* error);
    bool create_textures(std::string* error);
    bool create_meshes(const Scene& scene, std::string* error);
    bool build_light(const Scene& scene, const Options& options, std::string* error);

    void encode_gbuffer(id<MTLCommandBuffer> command);
    void encode_shadow(id<MTLCommandBuffer> command);
    void encode_visibility(id<MTLCommandBuffer> command);
    void encode_output(id<MTLCommandBuffer> command);

    id<MTLDevice>                  device_ = nil;
    id<MTLCommandQueue>            queue_ = nil;
    id<MTLLibrary>                 library_ = nil;

    id<MTLRenderPipelineState>     gbuffer_pipeline_ = nil;
    id<MTLRenderPipelineState>     shadow_pipeline_ = nil;
    id<MTLComputePipelineState>    visibility_pipeline_ = nil;
    id<MTLComputePipelineState>    visibility_fill_pipeline_ = nil;
    id<MTLComputePipelineState>    shading_pipeline_ = nil;
    id<MTLComputePipelineState>    debug_pipeline_ = nil;

    id<MTLDepthStencilState>       gbuffer_depth_state_ = nil;
    id<MTLDepthStencilState>       shadow_depth_state_ = nil;
    id<MTLSamplerState>            shadow_sampler_ = nil;

    id<MTLTexture>                 gbuffer_depth_ = nil;
    id<MTLTexture>                 gbuffer_normal_ = nil;
    id<MTLTexture>                 gbuffer_albedo_ = nil;
    id<MTLTexture>                 shadow_map_ = nil;
    id<MTLTexture>                 visibility_texture_ = nil;
    id<MTLTexture>                 color_texture_ = nil;

    std::vector<GpuMesh>           meshes_;

    Mat4 light_view_proj_ = Mat4::identity();
    Mat4 camera_view_proj_ = Mat4::identity();
    Mat4 camera_inv_view_proj_ = Mat4::identity();
    Vec3 light_direction_{0.0f, -1.0f, 0.0f};
    Vec3 light_irradiance_{1.0f, 1.0f, 1.0f};

    int    width_ = 0;
    int    height_ = 0;
    int    shadow_size_ = 0;
    int    taps_ = 1;
    float  bias_ = 1e-3f;
    float  normal_offset_ = 0.0f;
    float  depth_bias_ = 0.0f;
    float  slope_bias_ = 0.0f;
    float  near_plane_ = 0.1f;
    float  far_plane_ = 100.0f;
    float  texel_world_ = 0.0f;
    MTLCullMode cull_mode_ = MTLCullModeFront;

    bool   use_shadow_ = false;
    bool   use_visibility_ = false;
    bool   use_visibility_fill_ = false;
    bool   use_debug_ = false;
    int    debug_mode_ = 0;  // 0 albedo, 1 normal, 2 depth, 3 visibility
    bool   gpu_time_available_ = true;

    ShadowStats stats_;
};

}  // namespace nx::shadow
