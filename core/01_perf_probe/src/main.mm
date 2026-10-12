// 01_perf_probe — reference implementation of the benchmark contract.
//
// What it measures
//   * frame_ms : GPU time of one frame, where a frame is the two passes
//                submitted back to back
//   * passes   : GPU time of each pass
//   * counters : dispatch and traffic counts, so the report has something to
//                correlate the timings with
//
// Why each pass gets its own command buffer
//   Per-pass GPU timestamps need MTLCounterSampleBuffer, which on this machine
//   (Apple M3 Max) cannot sample compute encoders: only
//   MTLCounterSamplingPointAtStageBoundary is supported, and that is a render
//   encoder feature. Splitting passes across command buffers is the portable
//   workaround. It adds submission gaps, so the sum of the pass times is an
//   upper bound on a single-buffer frame.
//
// Usage
//   ./01_perf_probe                                  # smoke run, no report
//   ./01_perf_probe --bench-frames 300 --bench-out reports/bench/x.json
//   NYX_BENCH="60,300,reports/bench/x.json" ./01_perf_probe

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "nx/io/exr.h"
#include "nx/profile/bench_options.h"
#include "nx/profile/gpu_timer.h"
#include "nx/profile/perf_report.h"

namespace {

struct Options {
    int         width      = 1920;
    int         height     = 1080;
    // Enough arithmetic per dispatch that the measurement is dominated by GPU
    // work rather than by submission overhead. Sub-millisecond dispatches
    // measured poorly here: at ~0.6 ms the p95/p50 ratio was 3.5, at ~1.2 ms it
    // was 1.4.
    int         iterations = 1024;
    std::string image_out;  // empty: do not write an image
};

Options parse_options(int argc, const char* const* argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            options.width = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            options.height = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--iterations") == 0 && i + 1 < argc) {
            options.iterations = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            options.image_out = argv[++i];
        } else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf(
                "usage: 01_perf_probe [--width N] [--height N] [--iterations N] [--out IMAGE]\n"
                "       [--bench-warmup N] [--bench-frames N] [--bench-out JSON]\n");
            std::exit(0);
        }
    }
    return options;
}

struct Parameters {
    int   width;
    int   height;
    int   iterations;
    float seed;
};

// One pass, one command buffer, GPU-measured. Returns the pass time in
// milliseconds and falls back to wall clock when the driver reports no window.
double run_pass(id<MTLCommandQueue>            queue,
                id<MTLComputePipelineState>    pipeline,
                id<MTLBuffer>                  buffer,
                const Parameters&              parameters,
                const char*                    label,
                std::string*                   error,
                bool*                          used_gpu_time) {
    @autoreleasepool {
        id<MTLCommandBuffer>         command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];

        command.label = [NSString stringWithUTF8String:label];

        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:buffer offset:0 atIndex:0];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(parameters.width),
                                             static_cast<NSUInteger>(parameters.height), 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding];

        [command commit];
        [command waitUntilCompleted];

        if (command.status == MTLCommandBufferStatusError) {
            if (error != nullptr) {
                *error = command.error != nil ? command.error.localizedDescription.UTF8String
                                              : "command buffer failed";
            }
            return -1.0;
        }

        const double gpu_ms = nx::profile::command_buffer_gpu_ms(command);
        if (gpu_ms > 0.0) {
            *used_gpu_time = true;
            return gpu_ms;
        }
        *used_gpu_time = false;
        return nx::profile::command_buffer_wall_ms(command);
    }
}

}  // namespace

int main(int argc, const char* const* argv) {
    @autoreleasepool {
        const Options     options = parse_options(argc, argv);
        const auto        bench   = nx::profile::BenchOptions::parse(argc, argv);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            std::fprintf(stderr, "error: no Metal device\n");
            return 1;
        }

        NSString* library_path =
            [NSString stringWithFormat:@"%s/01_perf_probe.metallib", NX_SHADER_DIR];
        NSError* ns_error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:library_path]
                                                     error:&ns_error];
        if (library == nil) {
            std::fprintf(stderr, "error: cannot load %s: %s\n", library_path.UTF8String,
                         ns_error != nil ? ns_error.localizedDescription.UTF8String : "unknown");
            return 1;
        }

        struct Pass {
            const char*                 name;
            id<MTLComputePipelineState> pipeline;
            id<MTLBuffer>               buffer;
        };

        Pass passes[2] = {{"pass_a", nil, nil}, {"pass_b", nil, nil}};
        const NSUInteger pixel_count = static_cast<NSUInteger>(options.width) * options.height;

        for (Pass& pass : passes) {
            id<MTLFunction> function =
                [library newFunctionWithName:[NSString stringWithUTF8String:
                                                           (std::string("probe_") + pass.name).c_str()]];
            if (function == nil) {
                std::fprintf(stderr, "error: kernel for %s not found\n", pass.name);
                return 1;
            }
            pass.pipeline = [device newComputePipelineStateWithFunction:function error:&ns_error];
            if (pass.pipeline == nil) {
                std::fprintf(stderr, "error: pipeline for %s failed: %s\n", pass.name,
                             ns_error != nil ? ns_error.localizedDescription.UTF8String : "unknown");
                return 1;
            }
            pass.buffer = [device newBufferWithLength:pixel_count * 4 * sizeof(float)
                                              options:MTLResourceStorageModeShared];
            if (pass.buffer == nil) {
                std::fprintf(stderr, "error: cannot allocate buffer for %s\n", pass.name);
                return 1;
            }
        }

        const Parameters parameters{options.width, options.height, options.iterations, 0.5f};
        id<MTLCommandQueue> queue = [device newCommandQueue];

        std::printf("01_perf_probe\n");
        std::printf("  device     : %s\n", device.name.UTF8String);
        std::printf("  resolution : %dx%d, %d iterations\n", options.width, options.height,
                    options.iterations);

        std::string error;

        // ------------------------------------------------------------------
        // Smoke run: one frame, so `cmake --build --target 01_perf_probe` plus a
        // manual run does something observable.
        // ------------------------------------------------------------------
        if (!bench.enabled) {
            bool gpu_time_used = false;
            double total_ms    = 0.0;
            for (Pass& pass : passes) {
                const double ms = run_pass(queue, pass.pipeline, pass.buffer, parameters, pass.name,
                                           &error, &gpu_time_used);
                if (ms < 0.0) {
                    std::fprintf(stderr, "error: %s failed: %s\n", pass.name, error.c_str());
                    return 1;
                }
                std::printf("  %-8s : %.4f ms\n", pass.name, ms);
                total_ms += ms;
            }
            std::printf("  frame    : %.4f ms (%s)\n", total_ms,
                        nx::profile::timer_source_name(
                            gpu_time_used ? nx::profile::TimerSource::CommandBufferGpuTime
                                          : nx::profile::TimerSource::WallClock));
            std::printf("  hint     : pass --bench-frames N --bench-out PATH for a real report\n");

            if (!options.image_out.empty()) {
                nx::io::Image image;
                image.resize(options.width, options.height, 4);
                std::memcpy(image.pixels.data(), passes[0].buffer.contents,
                            image.pixels.size() * sizeof(float));
                if (!nx::io::write_exr(options.image_out, image, &error)) {
                    std::fprintf(stderr, "error: %s\n", error.c_str());
                    return 1;
                }
                std::printf("  image    : %s\n", options.image_out.c_str());
            }
            return 0;
        }

        // ------------------------------------------------------------------
        // Benchmark run
        // ------------------------------------------------------------------
        nx::profile::PerfReport report;
        report.experiment   = "01_perf_probe";
        report.renderer     = "metal";
        report.vsync        = false;  // headless: there is no display to sync to
        report.width        = options.width;
        report.height       = options.height;
        report.warmup_frames = bench.warmup;

        bool gpu_time_used = false;
        report.frame_ms.reserve(static_cast<std::size_t>(bench.frames));
        for (Pass& pass : passes) {
            report.passes[pass.name].reserve(static_cast<std::size_t>(bench.frames));
        }

        std::printf("  warmup     : %d frames\n", bench.warmup);
        std::printf("  measuring  : %d frames\n", bench.frames);

        const int total_frames = bench.warmup + bench.frames;
        for (int frame = 0; frame < total_frames; ++frame) {
            const bool measuring = frame >= bench.warmup;
            double     frame_ms  = 0.0;

            for (Pass& pass : passes) {
                const double ms = run_pass(queue, pass.pipeline, pass.buffer, parameters, pass.name,
                                           &error, &gpu_time_used);
                if (ms < 0.0) {
                    std::fprintf(stderr, "error: %s failed: %s\n", pass.name, error.c_str());
                    return 1;
                }
                frame_ms += ms;
                if (measuring) {
                    report.passes[pass.name].add(ms);
                }
            }
            if (measuring) {
                report.frame_ms.add(frame_ms);
            }
        }

        report.timer_source = nx::profile::timer_source_name(
            gpu_time_used ? nx::profile::TimerSource::CommandBufferGpuTime
                          : nx::profile::TimerSource::WallClock);

        const double dispatches = 2.0 * static_cast<double>(report.frame_ms.count());
        report.counters["dispatches"]        = dispatches;
        report.counters["threads_per_frame"] = 2.0 * static_cast<double>(pixel_count);
        report.counters["bytes_per_frame"] =
            2.0 * static_cast<double>(pixel_count) * 4.0 * static_cast<double>(sizeof(float));

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        std::printf("  timer      : %s\n", report.timer_source.c_str());
        std::printf("  frame_ms   : p50=%.4f p95=%.4f p99=%.4f mean=%.4f max=%.4f\n",
                    report.frame_ms.percentile(0.50), report.frame_ms.percentile(0.95),
                    report.frame_ms.percentile(0.99), report.frame_ms.mean(),
                    report.frame_ms.max());
        for (const auto& entry : report.passes) {
            std::printf("  %-10s : p50=%.4f p95=%.4f mean=%.4f\n", entry.first.c_str(),
                        entry.second.percentile(0.50), entry.second.percentile(0.95),
                        entry.second.mean());
        }
        if (report.timer_source != std::string("command-buffer-gpu-time")) {
            std::printf("  warning    : GPU timestamps unavailable, numbers include CPU submission\n");
        }

        const std::string out_path =
            bench.out.empty() ? ("reports/bench/01_perf_probe_" + nx::profile::fileTimestampNow() + ".json")
                              : bench.out;
        if (!report.write_json(out_path, &error)) {
            std::fprintf(stderr, "error: cannot write report: %s\n", error.c_str());
            return 1;
        }
        std::printf("  report     : %s\n", out_path.c_str());
        return 0;
    }
}
