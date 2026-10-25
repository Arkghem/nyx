// 02_shadows — realtime Metal renderer implementation.
//
// Resource lifetime is process lifetime: this is a headless lab tool, not a
// renderer that survives device loss or scene reloads. If that changes, the
// Objective-C objects need explicit release under MRR.

#import "renderer.h"

#import <Foundation/Foundation.h>

#include "mesh_format.h"
#include "nx/profile/gpu_timer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>

#ifndef NX_SHADER_DIR
#error "NX_SHADER_DIR is not defined; build through the experiment CMake target"
#endif

namespace nx::shadow {
namespace {

// ---------------------------------------------------------------------------
// Uniform payloads. Field order and padding must match shaders/common.h.
// ---------------------------------------------------------------------------

struct Vertex {
    float position[3];
    float normal[3];
};

struct alignas(16) CameraUniforms {
    Mat4 view_proj;
};

struct alignas(16) DrawUniforms {
    Vec4 albedo;
};

struct alignas(16) VisibilityUniforms {
    Mat4 inv_view_proj;
    Mat4 light_view_proj;
    Vec4 light_direction;
    Vec4 film;
    Vec4 params0;
    Vec4 params1;
};

struct alignas(16) ShadingUniforms {
    Vec4 light_direction;
    Vec4 irradiance;
    Vec4 params;
};

struct alignas(16) DebugUniforms {
    Vec4 params;
};

std::string ns_error_text(NSError* error) {
    return error != nil ? error.localizedDescription.UTF8String : std::string("unknown error");
}

double elapsed_ms(std::chrono::steady_clock::time_point start) {
    const auto end = std::chrono::steady_clock::now();
    return std::chrono::duration<double, std::milli>(end - start).count();
}

id<MTLTexture> make_texture(id<MTLDevice> device, int width, int height, MTLPixelFormat format,
                            MTLTextureUsage usage, MTLStorageMode storage, const char* label) {
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:format
                                     width:static_cast<NSUInteger>(width)
                                    height:static_cast<NSUInteger>(height)
                                 mipmapped:NO];
    descriptor.usage = usage;
    descriptor.storageMode = storage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    texture.label = [NSString stringWithUTF8String:label];
    return texture;
}

}  // namespace

// ---------------------------------------------------------------------------
// Pipeline and resource creation
// ---------------------------------------------------------------------------

bool Renderer::create_pipelines(std::string* error) {
    NSError* ns_error = nil;

    // The vertex shaders read a raw float array (six floats per vertex), so no
    // MTLVertexDescriptor is needed. See shaders/common.h for the layout.
    static_assert(sizeof(Vertex) == 24, "vertex buffers must stay six floats per vertex");

    auto make_render = [&](const char* vertex_name, const char* fragment_name, int color_count,
                           MTLPixelFormat color_format) -> id<MTLRenderPipelineState> {
        id<MTLFunction> vertex = [library_ newFunctionWithName:
                                                    [NSString stringWithUTF8String:vertex_name]];
        id<MTLFunction> fragment = [library_ newFunctionWithName:
                                                      [NSString stringWithUTF8String:fragment_name]];
        if (vertex == nil || fragment == nil) {
            *error = std::string("metallib is missing ") + vertex_name + " or " + fragment_name;
            return nil;
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.label = [NSString stringWithUTF8String:vertex_name];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.rasterSampleCount = 1;
        for (int i = 0; i < color_count; ++i) {
            descriptor.colorAttachments[i].pixelFormat = color_format;
        }
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        return [device_ newRenderPipelineStateWithDescriptor:descriptor error:&ns_error];
    };

    gbuffer_pipeline_ = make_render("gbuffer_vertex", "gbuffer_fragment", 2,
                                    MTLPixelFormatRGBA32Float);
    if (gbuffer_pipeline_ == nil) {
        *error = "cannot create the G-buffer pipeline: " + ns_error_text(ns_error);
        return false;
    }

    shadow_pipeline_ = make_render("depth_vertex", "depth_fragment", 0,
                                   MTLPixelFormatRGBA32Float);
    if (shadow_pipeline_ == nil) {
        *error = "cannot create the depth-only pipeline: " + ns_error_text(ns_error);
        return false;
    }

    auto make_compute = [&](const char* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> function =
            [library_ newFunctionWithName:[NSString stringWithUTF8String:name]];
        if (function == nil) {
            *error = std::string("metallib is missing ") + name;
            return nil;
        }
        return [device_ newComputePipelineStateWithFunction:function error:&ns_error];
    };

    visibility_pipeline_ = make_compute("visibility_main");
    if (visibility_pipeline_ == nil) {
        *error = "cannot create the visibility pipeline: " + ns_error_text(ns_error);
        return false;
    }
    visibility_fill_pipeline_ = make_compute("visibility_fill");
    if (visibility_fill_pipeline_ == nil) {
        *error = "cannot create the visibility_fill pipeline: " + ns_error_text(ns_error);
        return false;
    }
    shading_pipeline_ = make_compute("shading_main");
    if (shading_pipeline_ == nil) {
        *error = "cannot create the shading pipeline: " + ns_error_text(ns_error);
        return false;
    }
    debug_pipeline_ = make_compute("debug_main");
    if (debug_pipeline_ == nil) {
        *error = "cannot create the debug pipeline: " + ns_error_text(ns_error);
        return false;
    }

    MTLDepthStencilDescriptor* depth_descriptor = [MTLDepthStencilDescriptor new];
    depth_descriptor.depthCompareFunction = MTLCompareFunctionLess;
    depth_descriptor.depthWriteEnabled = YES;
    gbuffer_depth_state_ = [device_ newDepthStencilStateWithDescriptor:depth_descriptor];
    shadow_depth_state_ = [device_ newDepthStencilStateWithDescriptor:depth_descriptor];
    if (gbuffer_depth_state_ == nil || shadow_depth_state_ == nil) {
        *error = "cannot create the depth-stencil state";
        return false;
    }

    MTLSamplerDescriptor* sampler_descriptor = [MTLSamplerDescriptor new];
    sampler_descriptor.minFilter = MTLSamplerMinMagFilterNearest;
    sampler_descriptor.magFilter = MTLSamplerMinMagFilterNearest;
    sampler_descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    sampler_descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    // No compare function: the shader compares the returned depth itself, which
    // keeps the PCF kernel explicit and identical across tap counts.
    shadow_sampler_ = [device_ newSamplerStateWithDescriptor:sampler_descriptor];
    if (shadow_sampler_ == nil) {
        *error = "cannot create the shadow sampler";
        return false;
    }
    return true;
}

bool Renderer::create_textures(std::string* error) {
    gbuffer_depth_ = make_texture(device_, width_, height_, MTLPixelFormatDepth32Float,
                                  MTLTextureUsageRenderTarget, MTLStorageModePrivate,
                                  "gbuffer.depth");
    gbuffer_normal_ = make_texture(device_, width_, height_, MTLPixelFormatRGBA32Float,
                                   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead,
                                   MTLStorageModePrivate, "gbuffer.normal_depth");
    gbuffer_albedo_ = make_texture(device_, width_, height_, MTLPixelFormatRGBA32Float,
                                   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead,
                                   MTLStorageModePrivate, "gbuffer.albedo");
    visibility_texture_ = make_texture(device_, width_, height_, MTLPixelFormatR32Float,
                                       MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                                       MTLStorageModeShared, "visibility");
    color_texture_ = make_texture(device_, width_, height_, MTLPixelFormatRGBA32Float,
                                  MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                                  MTLStorageModeShared, "color");

    if (use_shadow_) {
        shadow_map_ = make_texture(device_, shadow_size_, shadow_size_,
                                   MTLPixelFormatDepth32Float,
                                   MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead,
                                   MTLStorageModePrivate, "shadow_map.depth");
    }

    if (gbuffer_depth_ == nil || gbuffer_normal_ == nil || gbuffer_albedo_ == nil ||
        visibility_texture_ == nil || color_texture_ == nil ||
        (use_shadow_ && shadow_map_ == nil)) {
        *error = "cannot allocate render targets";
        return false;
    }
    return true;
}

bool Renderer::create_meshes(const Scene& scene, std::string* error) {
    static_assert(sizeof(Vertex) == 6 * sizeof(float),
                  "a .nxmesh vertex must be six floats");

    meshes_.reserve(scene.meshes.size());
    stats_.triangles = 0.0;
    stats_.draw_calls = 0.0;

    auto upload = [&](const void* vertex_data, std::size_t vertex_count,
                      const std::uint32_t* index_data, std::size_t index_count,
                      Vec3 albedo) -> bool {
        if (vertex_count == 0 || index_count == 0 || (index_count % 3) != 0) {
            *error = "mesh has an empty or non-triangle index buffer";
            return false;
        }
        GpuMesh gpu_mesh;
        gpu_mesh.vertices =
            [device_ newBufferWithBytes:vertex_data
                                 length:vertex_count * sizeof(Vertex)
                                options:MTLResourceStorageModeShared];
        gpu_mesh.indices =
            [device_ newBufferWithBytes:index_data
                                 length:index_count * sizeof(std::uint32_t)
                                options:MTLResourceStorageModeShared];
        if (gpu_mesh.vertices == nil || gpu_mesh.indices == nil) {
            *error = "cannot upload mesh buffers";
            return false;
        }
        gpu_mesh.index_count = index_count;
        gpu_mesh.albedo = Vec4(albedo, 1.0f);
        meshes_.push_back(gpu_mesh);

        stats_.triangles += static_cast<double>(index_count / 3);
        stats_.draw_calls += 1.0;
        return true;
    };

    for (const Mesh& mesh : scene.meshes) {
        if (mesh.is_binary()) {
            // Large meshes are never materialized as CPU triangles; the
            // sidecar is read straight into the two Metal buffers.
            MeshFileHeader header{};
            std::string mesh_error;
            if (!read_mesh_header(mesh.mesh_path, &header, &mesh_error)) {
                *error = mesh_error;
                return false;
            }
            if (header.vertex_count != mesh.vertex_count ||
                header.index_count != mesh.index_count) {
                *error = mesh.mesh_path + ": header does not match the .nxscene";
                return false;
            }
            std::vector<float> vertices;
            std::vector<std::uint32_t> indices;
            if (!read_mesh_payload(mesh.mesh_path, header, &vertices, &indices,
                                   &mesh_error)) {
                *error = mesh_error;
                return false;
            }
            if (!upload(vertices.data(), header.vertex_count, indices.data(),
                        header.index_count, mesh.albedo)) {
                return false;
            }
            continue;
        }

        std::vector<Vertex> vertices;
        std::vector<std::uint32_t> indices;
        vertices.reserve(mesh.triangles.size() * 3);
        indices.reserve(mesh.triangles.size() * 3);

        for (const Triangle& triangle : mesh.triangles) {
            for (int vertex = 0; vertex < 3; ++vertex) {
                Vertex gpu_vertex{};
                gpu_vertex.position[0] = triangle.position[vertex].x;
                gpu_vertex.position[1] = triangle.position[vertex].y;
                gpu_vertex.position[2] = triangle.position[vertex].z;
                gpu_vertex.normal[0] = triangle.normal[vertex].x;
                gpu_vertex.normal[1] = triangle.normal[vertex].y;
                gpu_vertex.normal[2] = triangle.normal[vertex].z;
                vertices.push_back(gpu_vertex);
                indices.push_back(static_cast<std::uint32_t>(indices.size()));
            }
        }

        if (!upload(vertices.data(), vertices.size(), indices.data(), indices.size(),
                    mesh.albedo)) {
            return false;
        }
    }

    if (meshes_.empty()) {
        *error = "scene has no drawable geometry";
        return false;
    }
    return true;
}

bool Renderer::build_light(const Scene& scene, const Options& options, std::string* error) {
    const Light* light = scene.primary_light();
    if (light == nullptr) {
        *error = "scene has no light";
        return false;
    }
    if (light->kind != Light::Kind::Directional) {
        *error = "P0 only supports directional lights; area lights arrive with PCSS";
        return false;
    }

    light_direction_ = light->direction;
    light_irradiance_ = light->irradiance;

    if (!use_shadow_) {
        return true;
    }
    if (!scene.bounds.valid) {
        *error = "scene bounds are empty";
        return false;
    }

    const Vec3 center = scene.bounds.center();
    const float radius = std::max(scene.bounds.radius(), 0.5f);
    const Vec3 up = std::fabs(light_direction_.y) > 0.99f ? Vec3(0.0f, 0.0f, 1.0f)
                                                          : Vec3(0.0f, 1.0f, 0.0f);
    const Vec3 eye = center - light_direction_ * (radius * 2.0f + 1.0f);
    const Mat4 view = look_at(eye, center, up);

    float left = 1e30f;
    float right = -1e30f;
    float bottom = 1e30f;
    float top = -1e30f;
    float min_z = 1e30f;
    float max_z = -1e30f;

    for (int corner = 0; corner < 8; ++corner) {
        const Vec3 point{(corner & 1) ? scene.bounds.maximum.x : scene.bounds.minimum.x,
                         (corner & 2) ? scene.bounds.maximum.y : scene.bounds.minimum.y,
                         (corner & 4) ? scene.bounds.maximum.z : scene.bounds.minimum.z};
        const Vec3 view_point = transform_point(view, point);
        left = std::fmin(left, view_point.x);
        right = std::fmax(right, view_point.x);
        bottom = std::fmin(bottom, view_point.y);
        top = std::fmax(top, view_point.y);
        min_z = std::fmin(min_z, view_point.z);
        max_z = std::fmax(max_z, view_point.z);
    }

    const float padding = std::max(0.05f * std::max(right - left, top - bottom), 0.01f);
    left -= padding;
    right += padding;
    bottom -= padding;
    top += padding;

    // The light looks down -Z in view space, so the closest point has the
    // largest z (least negative) and the farthest has the smallest z.
    float near_plane = -max_z - padding;
    float far_plane = -min_z + padding;
    if (near_plane < 0.01f) {
        near_plane = 0.01f;
    }
    if (far_plane <= near_plane) {
        far_plane = near_plane + 1.0f;
    }

    // Snap the projection to whole texels. The scene is static in P0, but this
    // is the property that keeps a moving camera from making the shadow edges
    // crawl, and it costs nothing to do now.
    const float texel = (right - left) / static_cast<float>(shadow_size_);
    left = std::floor(left / texel) * texel;
    right = left + texel * static_cast<float>(shadow_size_);
    bottom = std::floor(bottom / texel) * texel;
    top = bottom + texel * static_cast<float>(shadow_size_);
    texel_world_ = texel;

    const Mat4 projection = ortho(left, right, bottom, top, near_plane, far_plane);
    light_view_proj_ = projection * view;

    if (options.bias_mode == BiasMode::None) {
        bias_ = 0.0f;
        normal_offset_ = 0.0f;
        depth_bias_ = 0.0f;
        slope_bias_ = 0.0f;
    } else if (options.bias_mode == BiasMode::NormalOffset) {
        normal_offset_ = options.normal_offset > 0.0f
                             ? options.normal_offset
                             : 1.5f * texel_world_;
    } else {
        normal_offset_ = options.normal_offset;
    }

    return true;
}

bool Renderer::init(const Scene& scene, const Options& options, std::string* error) {
    width_ = scene.camera.width;
    height_ = scene.camera.height;
    shadow_size_ = options.shadow_size;
    near_plane_ = scene.camera.near_plane;
    far_plane_ = scene.camera.far_plane;

    const std::string& variant = options.variant;
    if (variant == "sm" || variant == "pcf") {
        use_shadow_ = true;
        use_visibility_ = true;
        taps_ = (variant == "pcf") ? options.pcf_taps : 1;
    } else if (variant == "lit") {
        use_visibility_ = true;
        use_visibility_fill_ = true;
        taps_ = 1;
    } else if (variant == "albedo" || variant == "depth") {
        use_debug_ = true;
        debug_mode_ = (variant == "albedo") ? 0 : 2;
        taps_ = 1;
    } else {
        *error = "unknown variant '" + variant + "'";
        return false;
    }

    if (!options.debug.empty()) {
        use_debug_ = true;
        use_shadow_ = false;
        use_visibility_ = false;
        use_visibility_fill_ = false;
        if (options.debug == "albedo") {
            debug_mode_ = 0;
        } else if (options.debug == "normal") {
            debug_mode_ = 1;
        } else if (options.debug == "depth") {
            debug_mode_ = 2;
        } else if (options.debug == "visibility") {
            debug_mode_ = 3;
            use_shadow_ = true;
            use_visibility_ = true;
        } else {
            *error = "unknown --debug mode '" + options.debug +
                     "' (albedo|normal|depth|visibility)";
            return false;
        }
    }

    if (options.cull == "front") {
        cull_mode_ = MTLCullModeFront;
    } else if (options.cull == "back") {
        cull_mode_ = MTLCullModeBack;
    } else {
        cull_mode_ = MTLCullModeNone;
    }

    bias_ = options.bias;
    normal_offset_ = options.normal_offset;
    depth_bias_ = options.depth_bias;
    slope_bias_ = options.slope_bias;

    stats_.width = width_;
    stats_.height = height_;
    stats_.shadow_size = shadow_size_;
    stats_.taps = taps_ * taps_;
    stats_.cascades = 1;
    stats_.gbuffer_bytes = static_cast<double>(width_) * height_ * (16.0 + 16.0 + 4.0);

    device_ = MTLCreateSystemDefaultDevice();
    if (device_ == nil) {
        *error = "no Metal device available";
        return false;
    }
    queue_ = [device_ newCommandQueue];
    if (queue_ == nil) {
        *error = "cannot create a command queue";
        return false;
    }

    NSString* library_path =
        [NSString stringWithFormat:@"%s/02_shadows.metallib", NX_SHADER_DIR];
    NSError* ns_error = nil;
    library_ = [device_ newLibraryWithURL:[NSURL fileURLWithPath:library_path]
                                   error:&ns_error];
    if (library_ == nil) {
        *error = std::string("cannot load ") + library_path.UTF8String + ": " +
                 ns_error_text(ns_error) + " (run ./scripts/build.sh 02_shadows)";
        return false;
    }

    if (!create_pipelines(error)) {
        return false;
    }
    if (!create_textures(error)) {
        return false;
    }
    if (!create_meshes(scene, error)) {
        return false;
    }
    // Albedo/normal/depth are debug views of the G-buffer and do not shade;
    // requiring a directional light for them would reject a valid area-light
    // scene for no reason.
    const bool needs_light = use_shadow_ || use_visibility_fill_ || !use_debug_;
    if (needs_light && !build_light(scene, options, error)) {
        return false;
    }

    camera_view_proj_ = scene.camera.view_projection();
    camera_inv_view_proj_ = inverse(camera_view_proj_);

    stats_.shadow_map_texels = use_shadow_
                                   ? static_cast<double>(shadow_size_) * shadow_size_
                                   : 0.0;
    stats_.shadow_map_bytes = use_shadow_ ? stats_.shadow_map_texels * 4.0 : 0.0;
    stats_.texel_world = texel_world_;
    return true;
}

// ---------------------------------------------------------------------------
// Pass encoding
// ---------------------------------------------------------------------------

void Renderer::encode_gbuffer(id<MTLCommandBuffer> command) {
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = gbuffer_normal_;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[1].texture = gbuffer_albedo_;
    pass.colorAttachments[1].loadAction = MTLLoadActionClear;
    pass.colorAttachments[1].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    pass.colorAttachments[1].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = gbuffer_depth_;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    // The NDC depth lives in the normal target's alpha, so the depth
    // attachment does not need to be stored.
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    encoder.label = @"gbuffer";
    [encoder setRenderPipelineState:gbuffer_pipeline_];
    [encoder setDepthStencilState:gbuffer_depth_state_];
    // Mitsuba winds triangles counter-clockwise when viewed from their front
    // side, and the renderer preserves that order. This was calibrated with the
    // albedo AOV: with the opposite winding the single-sided ground plane
    // disappears and every cube shows its back faces.
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setCullMode:MTLCullModeBack];
    [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(width_),
                                     static_cast<double>(height_), 0.0, 1.0}];

    CameraUniforms camera{camera_view_proj_};
    [encoder setVertexBytes:&camera length:sizeof(camera) atIndex:1];

    for (const GpuMesh& mesh : meshes_) {
        [encoder setVertexBuffer:mesh.vertices offset:0 atIndex:0];
        DrawUniforms draw{mesh.albedo};
        [encoder setVertexBytes:&draw length:sizeof(draw) atIndex:2];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                           indexCount:mesh.index_count
                            indexType:MTLIndexTypeUInt32
                          indexBuffer:mesh.indices
                    indexBufferOffset:0];
    }
    [encoder endEncoding];
}

void Renderer::encode_shadow(id<MTLCommandBuffer> command) {
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = shadow_map_;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    encoder.label = @"shadow";
    [encoder setRenderPipelineState:shadow_pipeline_];
    [encoder setDepthStencilState:shadow_depth_state_];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setCullMode:cull_mode_];
    [encoder setDepthBias:depth_bias_ slopeScale:slope_bias_ clamp:0.0f];
    [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(shadow_size_),
                                     static_cast<double>(shadow_size_), 0.0, 1.0}];

    CameraUniforms camera{light_view_proj_};
    [encoder setVertexBytes:&camera length:sizeof(camera) atIndex:1];

    for (const GpuMesh& mesh : meshes_) {
        [encoder setVertexBuffer:mesh.vertices offset:0 atIndex:0];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                           indexCount:mesh.index_count
                            indexType:MTLIndexTypeUInt32
                          indexBuffer:mesh.indices
                    indexBufferOffset:0];
    }
    [encoder endEncoding];
}

void Renderer::encode_visibility(id<MTLCommandBuffer> command) {
    VisibilityUniforms uniforms{};
    uniforms.inv_view_proj = camera_inv_view_proj_;
    uniforms.light_view_proj = light_view_proj_;
    uniforms.light_direction = Vec4(light_direction_, 0.0f);
    uniforms.film = Vec4(static_cast<float>(width_), static_cast<float>(height_),
                         1.0f / static_cast<float>(width_),
                         1.0f / static_cast<float>(height_));
    uniforms.params0 = Vec4(bias_, normal_offset_, static_cast<float>(shadow_size_), 0.0f);
    uniforms.params1 = Vec4(static_cast<float>(taps_), 0.0f, near_plane_, far_plane_);

    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    encoder.label = @"visibility";
    if (use_visibility_fill_) {
        [encoder setComputePipelineState:visibility_fill_pipeline_];
        [encoder setTexture:visibility_texture_ atIndex:0];
    } else {
        [encoder setComputePipelineState:visibility_pipeline_];
        [encoder setTexture:gbuffer_normal_ atIndex:0];
        [encoder setTexture:shadow_map_ atIndex:1];
        [encoder setTexture:visibility_texture_ atIndex:2];
    }
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(width_),
                                         static_cast<NSUInteger>(height_), 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder endEncoding];
}

void Renderer::encode_output(id<MTLCommandBuffer> command) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    encoder.label = @"shading";
    if (use_debug_) {
        DebugUniforms uniforms{};
        uniforms.params = Vec4(static_cast<float>(debug_mode_), near_plane_, far_plane_, 0.0f);
        [encoder setComputePipelineState:debug_pipeline_];
        [encoder setTexture:gbuffer_albedo_ atIndex:0];
        [encoder setTexture:gbuffer_normal_ atIndex:1];
        [encoder setTexture:visibility_texture_ atIndex:2];
        [encoder setTexture:color_texture_ atIndex:3];
        [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    } else {
        ShadingUniforms uniforms{};
        uniforms.light_direction = Vec4(light_direction_, 0.0f);
        uniforms.irradiance = Vec4(light_irradiance_, 1.0f);
        uniforms.params = Vec4(0.0f, 0.0f, 0.0f, 0.0f);
        [encoder setComputePipelineState:shading_pipeline_];
        [encoder setTexture:gbuffer_albedo_ atIndex:0];
        [encoder setTexture:gbuffer_normal_ atIndex:1];
        [encoder setTexture:visibility_texture_ atIndex:2];
        [encoder setTexture:color_texture_ atIndex:3];
        [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    }
    [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(width_),
                                         static_cast<NSUInteger>(height_), 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder endEncoding];
}

// ---------------------------------------------------------------------------
// Frame submission and timing
// ---------------------------------------------------------------------------

std::string Renderer::device_name() const {
    return device_ != nil ? std::string(device_.name.UTF8String) : std::string();
}

bool Renderer::render_frame(bool per_pass, int iterations, FrameTiming* timing,
                            std::string* error) {
    iterations = std::max(1, iterations);
    timing->gpu_ms = 0.0;
    timing->cpu_ms = 0.0;
    timing->passes.clear();

    auto encode_all = [&](id<MTLCommandBuffer> command) {
        encode_gbuffer(command);
        if (use_shadow_) {
            encode_shadow(command);
        }
        if (use_visibility_) {
            encode_visibility(command);
        }
        encode_output(command);
    };

    auto submit_pass = [&](const char* name,
                           const std::function<void(id<MTLCommandBuffer>)>& encode) -> bool {
        const auto start = std::chrono::steady_clock::now();
        id<MTLCommandBuffer> command = [queue_ commandBuffer];
        command.label = [NSString stringWithUTF8String:name];
        encode(command);
        [command commit];
        timing->cpu_ms += elapsed_ms(start);
        [command waitUntilCompleted];

        if (command.status == MTLCommandBufferStatusError) {
            *error = std::string(name) + " pass failed: " +
                     (command.error != nil ? command.error.localizedDescription.UTF8String
                                           : "unknown error");
            return false;
        }
        double gpu_ms = nx::profile::command_buffer_gpu_ms(command);
        if (gpu_ms <= 0.0) {
            gpu_time_available_ = false;
            gpu_ms = nx::profile::command_buffer_wall_ms(command);
        }
        timing->gpu_ms += gpu_ms;
        timing->passes[name] = gpu_ms;
        return true;
    };

    if (per_pass) {
        // A per-pass breakdown only makes sense for one frame; the caller is
        // expected to pass 1 here. Batching would interleave the passes.
        iterations = 1;
        if (!submit_pass("gbuffer", [&](id<MTLCommandBuffer> c) { encode_gbuffer(c); })) {
            return false;
        }
        if (use_shadow_ &&
            !submit_pass("shadow", [&](id<MTLCommandBuffer> c) { encode_shadow(c); })) {
            return false;
        }
        if (use_visibility_ &&
            !submit_pass("visibility", [&](id<MTLCommandBuffer> c) { encode_visibility(c); })) {
            return false;
        }
        if (!submit_pass("shading", [&](id<MTLCommandBuffer> c) { encode_output(c); })) {
            return false;
        }
        return true;
    }

    const auto start = std::chrono::steady_clock::now();
    id<MTLCommandBuffer> command = [queue_ commandBuffer];
    command.label = @"frame";
    // N frames back to back in one command buffer: the GPU time per frame is
    // total/N, which is far more stable than a single sub-millisecond frame.
    for (int iteration = 0; iteration < iterations; ++iteration) {
        encode_all(command);
    }
    [command commit];
    timing->cpu_ms = elapsed_ms(start) / static_cast<double>(iterations);
    [command waitUntilCompleted];

    if (command.status == MTLCommandBufferStatusError) {
        *error = "frame command buffer failed: " +
                 (command.error != nil ? command.error.localizedDescription.UTF8String
                                       : std::string("unknown error"));
        return false;
    }

    double gpu_ms = nx::profile::command_buffer_gpu_ms(command);
    if (gpu_ms <= 0.0) {
        gpu_time_available_ = false;
        gpu_ms = nx::profile::command_buffer_wall_ms(command);
    }
    timing->gpu_ms = gpu_ms / static_cast<double>(iterations);
    return true;
}

}  // namespace nx::shadow
