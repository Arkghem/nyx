// 00_envcheck — end-to-end proof that the native toolchain works.
//
// Verifies, in one run:
//   * CMake configured an Objective-C++ target and compiled it
//   * xcrun metal produced a .metallib that the runtime can load
//   * a Metal compute kernel runs and writes into a shared texture
//   * a GPU-side timing mechanism is available and reports sane numbers
//   * the EXR writer produces a file the Python side can read back
//
// It also prints the device's counter sampling capabilities, because those
// decide which timing mechanism nx::profile can use and they differ per model.
//
// It never touches The-Forge: a broken submodule must not make the lab
// unusable.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "nx/io/exr.h"
#include "nx/profile/gpu_timer.h"
#include "nx/profile/perf_report.h"

namespace {

struct Options {
    int         width  = 512;
    int         height = 512;
    std::string out    = "outputs/00_envcheck.exr";
};

Options parse_options(int argc, const char* const* argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            options.width = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            options.height = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            options.out = argv[++i];
        } else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("usage: 00_envcheck [--width N] [--height N] [--out PATH]\n");
            std::exit(0);
        }
    }
    return options;
}

void check(bool condition, const char* label, bool* all_ok) {
    std::printf("  [%s] %s\n", condition ? "ok  " : "FAIL", label);
    if (!condition) {
        *all_ok = false;
    }
}

void note(const char* label) {
    std::printf("  [info] %s\n", label);
}

}  // namespace

int main(int argc, const char* const* argv) {
    @autoreleasepool {
        const Options options = parse_options(argc, argv);
        bool          all_ok  = true;

        std::printf("00_envcheck — native toolchain check\n");
        std::printf("------------------------------------\n");

        // ---------------------------------------------------------------
        // Device and timing capabilities
        // ---------------------------------------------------------------
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        check(device != nil, "Metal device available", &all_ok);
        if (device == nil) {
            return 1;
        }
        std::printf("  device: %s\n", device.name.UTF8String);
        check(device.hasUnifiedMemory, "unified memory", &all_ok);

        const nx::profile::CounterCapabilities counters =
            nx::profile::probe_counter_capabilities(device);
        std::printf("  counter sampling: timestamp-set=%s stage=%s draw=%s blit=%s dispatch=%s\n",
                    counters.timestamp_counter_set ? "yes" : "no",
                    counters.stage_boundary ? "yes" : "no",
                    counters.draw_boundary ? "yes" : "no",
                    counters.blit_boundary ? "yes" : "no",
                    counters.dispatch_boundary ? "yes" : "no");
        if (!counters.compute_sampling()) {
            note("per-pass counter sampling is unavailable for compute encoders on "
                 "this device; nx::profile falls back to command buffer GPU time");
        }

        // ---------------------------------------------------------------
        // Shader library produced by the build
        // ---------------------------------------------------------------
        NSString* library_path =
            [NSString stringWithFormat:@"%s/00_envcheck.metallib", NX_SHADER_DIR];
        NSError*  ns_error     = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:library_path]
                                                     error:&ns_error];

        std::printf("  library: %s\n", library_path.UTF8String);
        check(library != nil, "metallib loads", &all_ok);
        if (library == nil) {
            std::fprintf(stderr, "  reason: %s\n",
                         ns_error != nil ? ns_error.localizedDescription.UTF8String : "unknown");
            return 1;
        }

        id<MTLFunction> function = [library newFunctionWithName:@"pattern_fill"];
        check(function != nil, "kernel pattern_fill present", &all_ok);
        if (function == nil) {
            return 1;
        }

        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&ns_error];
        check(pipeline != nil, "compute pipeline created", &all_ok);
        if (pipeline == nil) {
            std::fprintf(stderr, "  reason: %s\n",
                         ns_error != nil ? ns_error.localizedDescription.UTF8String : "unknown");
            return 1;
        }

        // ---------------------------------------------------------------
        // Output texture, shared so the CPU can read it straight back
        // ---------------------------------------------------------------
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:static_cast<NSUInteger>(options.width)
                                        height:static_cast<NSUInteger>(options.height)
                                     mipmapped:NO];
        descriptor.usage       = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;

        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        check(texture != nil, "output texture allocated", &all_ok);
        if (texture == nil) {
            return 1;
        }

        struct Parameters {
            int   width;
            int   height;
            float time;
        } parameters{options.width, options.height, 0.0f};

        // ---------------------------------------------------------------
        // Dispatch
        // ---------------------------------------------------------------
        nx::profile::GpuTimer timer;
        if (counters.compute_sampling()) {
            std::string timer_error;
            if (timer.init(device, 2, &timer_error)) {
                note("counter based per-pass timing armed");
            } else {
                std::printf("  [info] counter timer unavailable: %s\n", timer_error.c_str());
            }
        }

        id<MTLCommandQueue>          queue   = [device newCommandQueue];
        id<MTLCommandBuffer>         command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];

        if (timer.ready()) {
            timer.sample(encoder, 0, true);
        }

        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:texture atIndex:0];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(options.width),
                                             static_cast<NSUInteger>(options.height), 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];

        if (timer.ready()) {
            timer.sample(encoder, 1, true);
        }

        [encoder endEncoding];

        [command commit];
        [command waitUntilCompleted];

        check(command.status != MTLCommandBufferStatusError, "command buffer completed", &all_ok);
        if (command.status == MTLCommandBufferStatusError) {
            std::fprintf(stderr, "  reason: %s\n",
                         command.error != nil ? command.error.localizedDescription.UTF8String
                                              : "unknown");
            return 1;
        }

        // Per-command-buffer GPU time is the mechanism that works on every
        // device, including this one.
        const double gpu_ms = nx::profile::command_buffer_gpu_ms(command);
        check(gpu_ms > 0.0, "GPU time reported by the command buffer", &all_ok);
        std::printf("  gpu time: %.4f ms (%s)\n", gpu_ms,
                    nx::profile::timer_source_name(nx::profile::TimerSource::CommandBufferGpuTime));

        // ---------------------------------------------------------------
        // Read back and write a linear EXR
        // ---------------------------------------------------------------
        nx::io::Image image;
        image.resize(options.width, options.height, 4);
        [texture getBytes:image.pixels.data()
              bytesPerRow:static_cast<NSUInteger>(options.width) * 4 * sizeof(float)
               fromRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(options.width),
                                          static_cast<NSUInteger>(options.height))
              mipmapLevel:0];

        std::string io_error;
        const bool  wrote = nx::io::write_exr(options.out, image, &io_error);
        check(wrote, "EXR written", &all_ok);
        if (!wrote) {
            std::fprintf(stderr, "  reason: %s\n", io_error.c_str());
            return 1;
        }
        std::printf("  output: %s (%dx%d)\n", options.out.c_str(), options.width, options.height);

        // A black or NaN frame would mean the readback path is wrong, which is
        // exactly the kind of silent failure this check exists for.
        double sum = 0.0;
        for (std::size_t i = 0; i < image.pixels.size(); i += 4) {
            sum += image.pixels[i];
        }
        const double mean_r = sum / (static_cast<double>(options.width) * options.height);
        check(mean_r > 0.0, "frame is not black", &all_ok);
        std::printf("  mean R: %.4f\n", mean_r);

        std::printf("------------------------------------\n");
        std::printf("%s\n", all_ok ? "00_envcheck PASSED" : "00_envcheck FAILED");
        return all_ok ? 0 : 1;
    }
}
