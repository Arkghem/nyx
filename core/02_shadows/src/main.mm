// 02_shadows — realtime shadow lab, P0.
//
// Three modes:
//   * one rendered frame + linear EXRs (the normal smoke run);
//   * --bench, which is the nx::profile benchmark contract and writes a JSON
//     with GPU, CPU and memory counters;
//   * --self-test, which checks the camera math and that the frame contains
//     both lit and shadowed pixels before any metric is trusted.
//
// Mitsuba is never part of this loop. The reference images it produces are
// offline, one per scene, and are consumed by scripts/compare.py later.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#include "math.h"
#include "options.h"
#include "renderer.h"
#include "scene.h"

#include "nx/io/exr.h"
#include "nx/profile/bench_options.h"
#include "nx/profile/perf_report.h"

namespace {

using nx::shadow::Camera;
using nx::shadow::FrameTiming;
using nx::shadow::Mat4;
using nx::shadow::Options;
using nx::shadow::Renderer;
using nx::shadow::Scene;
using nx::shadow::Vec3;

constexpr const char* kExperiment = "02_shadows";

std::string scene_stem(const std::string& path) {
    return std::filesystem::path(path).stem().string();
}

std::string float_tag(float value) {
    std::ostringstream stream;
    stream << std::fixed << std::setprecision(5) << value;
    return stream.str();
}

std::string default_output_path(const Options& options, const Scene& scene) {
    std::ostringstream path;
    path << "outputs/02_shadows/" << scene_stem(options.scene) << "_"
         << nx::shadow::pipeline_tag(options) << "_" << scene.camera.width << "x"
         << scene.camera.height << "_sm" << options.shadow_size << "_b"
         << float_tag(options.bias) << "_seed" << options.seed << ".exr";
    return path.str();
}

std::string visibility_path_from(const std::string& color_path) {
    std::filesystem::path path(color_path);
    path.replace_extension();
    return path.string() + "_vis.exr";
}

struct PixelStats {
    double minimum = 0.0;
    double maximum = 0.0;
    double mean = 0.0;
    long long samples = 0;
    long long nonfinite = 0;
};

PixelStats analyze(const nx::io::Image& image, int channel) {
    PixelStats stats;
    if (!image.valid() || channel < 0 || channel >= image.channels) {
        return stats;
    }
    double sum = 0.0;
    bool first = true;
    for (std::size_t i = 0; i < image.pixels.size(); i += image.channels) {
        const float value = image.pixels[i + channel];
        if (!std::isfinite(value)) {
            ++stats.nonfinite;
            continue;
        }
        if (first) {
            stats.minimum = value;
            stats.maximum = value;
            first = false;
        } else {
            stats.minimum = std::min(stats.minimum, static_cast<double>(value));
            stats.maximum = std::max(stats.maximum, static_cast<double>(value));
        }
        sum += value;
        ++stats.samples;
    }
    stats.mean = stats.samples > 0 ? sum / static_cast<double>(stats.samples) : 0.0;
    return stats;
}

nx::io::Image read_color(id<MTLTexture> texture, int width, int height) {
    nx::io::Image image;
    image.resize(width, height, 4);
    if (texture != nil) {
        [texture getBytes:image.pixels.data()
              bytesPerRow:static_cast<NSUInteger>(width) * 4 * sizeof(float)
               fromRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(width),
                                          static_cast<NSUInteger>(height))
              mipmapLevel:0];
    }
    return image;
}

nx::io::Image read_visibility(id<MTLTexture> texture, int width, int height) {
    nx::io::Image image;
    image.resize(width, height, 1);
    if (texture != nil) {
        [texture getBytes:image.pixels.data()
              bytesPerRow:static_cast<NSUInteger>(width) * sizeof(float)
               fromRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(width),
                                          static_cast<NSUInteger>(height))
              mipmapLevel:0];
    }
    return image;
}

bool write_image(const std::string& path, const nx::io::Image& image, std::string* error) {
    const std::filesystem::path target(path);
    std::error_code ec;
    if (target.has_parent_path()) {
        std::filesystem::create_directories(target.parent_path(), ec);
        if (ec) {
            *error = "cannot create " + target.parent_path().string() + ": " + ec.message();
            return false;
        }
    }
    return nx::io::write_exr(path, image, error);
}

void print_usage() {
    std::printf(
        "02_shadows — realtime shadow lab (P0)\n"
        "\n"
        "usage: .build/bin/02_shadows [options]\n"
        "\n"
        "scene\n"
        "  --scene PATH          exported .nxscene (default .cache/scenes/shadow_basic.nxscene)\n"
        "  --width N --height N  override the output resolution (recomputes fov_y)\n"
        "\n"
        "variant / composition\n"
        "  --variant NAME        albedo|lit|depth|sm|pcf|pcf3|pcf5 (--list-variants)\n"
        "  --pipeline SPEC       e.g. partition=single_ortho,storage=depth,filter=pcf:5\n"
        "  --debug MODE          albedo|normal|depth|visibility\n"
        "\n"
        "shadow\n"
        "  --shadow-size N       shadow map resolution (default 2048)\n"
        "  --pcf-taps N          odd box width, 1..9 (default 3)\n"
        "  --bias F              comparison bias in shadow NDC z (default 1e-3)\n"
        "  --normal-offset F     receiver offset in world units (0: derive for normal_offset mode)\n"
        "  --depth-bias F        rasterizer constant depth bias (default 0)\n"
        "  --slope-bias F        rasterizer slope-scaled bias (default 0)\n"
        "  --cull MODE           shadow pass culling: front|back|none (default front)\n"
        "\n"
        "output\n"
        "  --out PATH            radiance EXR (default is reproducible from the parameters)\n"
        "  --out-visibility PATH visibility EXR (default <out>_vis.exr)\n"
        "  --no-write            render but do not write images\n"
        "  --seed N              recorded in names/metadata (P0 has no stochastic filter)\n"
        "\n"
        "measurement\n"
        "  --timing frame        one command buffer per frame (default, headline number)\n"
        "  --timing passes       one command buffer per pass (per-pass breakdown, upper bound)\n"
        "  --bench-warmup N --bench-frames N --bench-out PATH\n"
        "  --bench-iterations N  frames batched into one command buffer (default 8)\n"
        "  --self-test           camera math + frame sanity checks\n"
        "  --list-variants --list-pipelines\n"
        "\n"
        "export a scene first:\n"
        "  python3 scripts/export_scene.py --all\n");
}

void check(bool condition, const char* label, bool* all_ok) {
    std::printf("  [%s] %s\n", condition ? "ok  " : "FAIL", label);
    if (!condition) {
        *all_ok = false;
    }
}

bool camera_self_test(const Scene& scene) {
    bool ok = true;
    std::printf("camera and projection\n");

    const Camera& camera = scene.camera;
    const float basis_error = std::fabs(nx::shadow::dot(camera.right, camera.up)) +
                              std::fabs(nx::shadow::dot(camera.right, camera.forward)) +
                              std::fabs(nx::shadow::dot(camera.up, camera.forward));
    check(basis_error < 1e-3f, "camera basis is orthonormal", &ok);

    const Mat4 view_projection = camera.view_projection();
    const Vec3 center = nx::shadow::transform_point(
        view_projection, camera.origin + camera.forward * 2.0f);
    check(std::fabs(center.x) < 1e-3f && std::fabs(center.y) < 1e-3f,
          "forward point projects to the frame centre", &ok);
    check(center.z > 0.0f && center.z < 1.0f, "forward point has a valid depth", &ok);

    const float half_width = std::tan(nx::shadow::radians(camera.fov_x) * 0.5f) * 2.0f;
    const Vec3 edge = nx::shadow::transform_point(
        view_projection, camera.origin + camera.forward * 2.0f + camera.right * half_width);
    check(std::fabs(edge.x - 1.0f) < 1e-3f, "right edge projects to NDC x = 1", &ok);

    const Vec3 point = camera.origin + camera.forward * 3.0f + camera.right * 0.5f +
                       camera.up * 0.25f;
    const Vec3 round_trip =
        nx::shadow::transform_point(nx::shadow::inverse(view_projection),
                                    nx::shadow::transform_point(view_projection, point));
    check(nx::shadow::length(round_trip - point) < 1e-3f,
          "inverse(view_projection) round-trips a point", &ok);

    check(scene.triangle_count() > 0, "scene has triangles", &ok);
    check(scene.bounds.valid, "scene bounds are valid", &ok);
    return ok;
}

int run_self_test(Renderer& renderer, const Scene& scene, const Options& options) {
    bool ok = camera_self_test(scene);

    std::printf("frame\n");
    FrameTiming timing;
    std::string error;
    check(renderer.render_frame(false, 1, &timing, &error), "frame renders", &ok);
    if (!ok) {
        std::fprintf(stderr, "reason: %s\n", error.c_str());
        return 1;
    }

    const nx::io::Image color = read_color(renderer.color_texture(), renderer.width(),
                                           renderer.height());
    const PixelStats color_stats = analyze(color, 0);
    check(color_stats.nonfinite == 0, "radiance contains no NaN/Inf", &ok);
    check(color_stats.samples > 0 && color_stats.mean > 0.0, "radiance is not black", &ok);

    if (renderer.has_visibility()) {
        const nx::io::Image visibility = read_visibility(
            renderer.visibility_texture(), renderer.width(), renderer.height());
        const PixelStats visibility_stats = analyze(visibility, 0);
        check(visibility_stats.nonfinite == 0, "visibility contains no NaN/Inf", &ok);
        check(visibility_stats.minimum >= -1e-6 && visibility_stats.maximum <= 1.0 + 1e-6,
              "visibility is in [0, 1]", &ok);
        if (options.variant == "sm" || options.variant == "pcf") {
            check(visibility_stats.minimum < 0.01, "frame contains shadowed pixels", &ok);
            check(visibility_stats.maximum > 0.99, "frame contains lit pixels", &ok);
        }
    }

    std::printf("  gpu time: %.3f ms\n", timing.gpu_ms);
    std::printf("%s\n", ok ? "02_shadows self-test PASSED" : "02_shadows self-test FAILED");
    return ok ? 0 : 1;
}

int run_bench(Renderer& renderer, const Scene& scene, const Options& options,
              const nx::profile::BenchOptions& bench) {
    nx::profile::PerfReport report;
    report.experiment = kExperiment;
    report.renderer = "metal";
    report.vsync = false;
    report.width = renderer.width();
    report.height = renderer.height();
    report.warmup_frames = bench.warmup;
    report.hw = nx::profile::hostDescription();
    report.metadata["variant"] = options.variant;
    report.metadata["tag"] = nx::shadow::pipeline_tag(options);
    report.metadata["pipeline"] =
        options.pipeline.empty() ? std::string("<preset>") : options.pipeline;
    report.metadata["scene"] = options.scene;
    report.metadata["shadow_size"] = std::to_string(options.shadow_size);
    report.metadata["bias"] = float_tag(options.bias);
    report.metadata["pcf_taps"] = std::to_string(options.pcf_taps);
    report.metadata["timing"] = options.timing_passes ? "passes" : "frame";
    const int iterations = options.timing_passes ? 1 : options.bench_iterations;
    report.metadata["bench_iterations"] = std::to_string(iterations);
    report.metadata["device"] = renderer.device_name();
#ifdef NDEBUG
    report.metadata["build_type"] = "release";
#else
    report.metadata["build_type"] = "debug";
#endif

    std::printf("02_shadows benchmark\n");
    std::printf("  device     : %s\n", renderer.device_name().c_str());
    std::printf("  scene      : %s\n", options.scene.c_str());
    std::printf("  variant    : %s%s\n", options.variant.c_str(),
                options.pipeline.empty() ? "" : " (pipeline spec)");
    std::printf("  resolution : %dx%d\n", renderer.width(), renderer.height());
    std::printf("  shadow map : %d, %d tap(s)\n", options.shadow_size,
                renderer.stats().taps);
    std::printf("  timing     : %s\n", options.timing_passes ? "per-pass (upper bound)" : "frame");
    std::printf("  iterations : %d per measured frame\n", iterations);
#ifndef NDEBUG
    std::printf("  WARNING    : Debug build — rebuild with --release before trusting these ms\n");
#endif

    std::string error;
    FrameTiming timing;

    for (int frame = 0; frame < bench.warmup; ++frame) {
        if (!renderer.render_frame(options.timing_passes, iterations, &timing, &error)) {
            std::fprintf(stderr, "error: warmup frame failed: %s\n", error.c_str());
            return 1;
        }
    }

    report.frame_ms.reserve(static_cast<std::size_t>(bench.frames));
    report.cpu_frame_ms.reserve(static_cast<std::size_t>(bench.frames));

    for (int frame = 0; frame < bench.frames; ++frame) {
        if (!renderer.render_frame(options.timing_passes, iterations, &timing, &error)) {
            std::fprintf(stderr, "error: frame %d failed: %s\n", frame, error.c_str());
            return 1;
        }
        report.frame_ms.add(timing.gpu_ms);
        report.cpu_frame_ms.add(timing.cpu_ms);
        for (const auto& entry : timing.passes) {
            report.passes[entry.first].add(entry.second);
        }
    }

    const nx::shadow::ShadowStats& stats = renderer.stats();
    report.counters["triangles"] = stats.triangles;
    report.counters["draw_calls"] = stats.draw_calls;
    report.counters["shadow_map_bytes"] = stats.shadow_map_bytes;
    report.counters["shadow_map_texels"] = stats.shadow_map_texels;
    report.counters["gbuffer_bytes"] = stats.gbuffer_bytes;
    report.counters["taps"] = static_cast<double>(stats.taps);
    report.counters["cascades"] = static_cast<double>(stats.cascades);
    report.counters["texel_world"] = static_cast<double>(stats.texel_world);
    report.timer_source = renderer.gpu_time_available() ? "command-buffer-gpu-time"
                                                        : "wallclock";

    std::printf("  frames     : %d warmup + %d measured\n", bench.warmup, bench.frames);
    std::printf("  timer      : %s\n", report.timer_source.c_str());
    std::printf("  frame_ms   : p50=%.4f p95=%.4f p99=%.4f mean=%.4f max=%.4f\n",
                report.frame_ms.percentile(0.50), report.frame_ms.percentile(0.95),
                report.frame_ms.percentile(0.99), report.frame_ms.mean(),
                report.frame_ms.max());
    std::printf("  cpu_ms     : p50=%.4f p95=%.4f mean=%.4f\n",
                report.cpu_frame_ms.percentile(0.50), report.cpu_frame_ms.percentile(0.95),
                report.cpu_frame_ms.mean());
    for (const auto& entry : report.passes) {
        std::printf("  %-10s : p50=%.4f p95=%.4f mean=%.4f\n", entry.first.c_str(),
                    entry.second.percentile(0.50), entry.second.percentile(0.95),
                    entry.second.mean());
    }
    if (options.timing_passes) {
        std::printf("  note       : per-pass times are an upper bound (separate command buffers)\n");
    }
    std::printf("  memory     : shadow=%.2f MB gbuffer=%.2f MB\n",
                stats.shadow_map_bytes / (1024.0 * 1024.0),
                stats.gbuffer_bytes / (1024.0 * 1024.0));

    const std::string out_path =
        bench.out.empty()
            ? ("reports/bench/" + std::string(kExperiment) + "_" + options.variant + "_" +
               nx::profile::fileTimestampNow() + ".json")
            : bench.out;
    if (!report.write_json(out_path, &error)) {
        std::fprintf(stderr, "error: cannot write report: %s\n", error.c_str());
        return 1;
    }
    std::printf("  report     : %s\n", out_path.c_str());
    (void)scene;
    return 0;
}

}  // namespace

int main(int argc, const char* const* argv) {
    @autoreleasepool {
        Options options;
        std::string error;
        if (!nx::shadow::parse_options(argc, argv, &options, &error)) {
            std::fprintf(stderr, "error: %s\n", error.c_str());
            return 2;
        }
        if (options.help) {
            print_usage();
            return 0;
        }
        if (options.list_variants) {
            nx::shadow::print_variants();
            return 0;
        }
        if (options.list_pipelines) {
            nx::shadow::print_pipelines();
            return 0;
        }

        const nx::profile::BenchOptions bench = nx::profile::BenchOptions::parse(argc, argv);

        Scene scene;
        if (!nx::shadow::load_nxscene(options.scene, &scene, &error)) {
            std::fprintf(stderr, "error: %s\n", error.c_str());
            if (options.scene.find(".xml") != std::string::npos) {
                std::fprintf(stderr,
                             "hint : %s is a Mitsuba scene; export it first:\n"
                             "       python3 scripts/export_scene.py --scene %s\n",
                             options.scene.c_str(), options.scene.c_str());
            }
            return 1;
        }

        if (!scene.source_path.empty() && scene.source_mtime > 0) {
            struct stat source_stat {};
            if (stat(scene.source_path.c_str(), &source_stat) == 0 &&
                static_cast<long long>(source_stat.st_mtime) > scene.source_mtime) {
                std::fprintf(stderr,
                             "warning: %s is newer than %s; re-run the exporter\n",
                             scene.source_path.c_str(), options.scene.c_str());
            }
        }

        if (options.width > 0 || options.height > 0) {
            const int width = options.width > 0 ? options.width : scene.camera.width;
            const int height = options.height > 0 ? options.height : scene.camera.height;
            scene.camera.set_resolution(width, height);
            std::fprintf(stderr,
                         "warning: output resolution overridden to %dx%d; render the "
                         "Mitsuba reference at the same aspect for a quality comparison\n",
                         width, height);
        }

        Renderer renderer;
        if (!renderer.init(scene, options, &error)) {
            std::fprintf(stderr, "error: %s\n", error.c_str());
            return 1;
        }

        if (options.self_test) {
            return run_self_test(renderer, scene, options);
        }
        if (bench.enabled) {
            return run_bench(renderer, scene, options, bench);
        }

        FrameTiming timing;
        if (!renderer.render_frame(options.timing_passes, 1, &timing, &error)) {
            std::fprintf(stderr, "error: %s\n", error.c_str());
            return 1;
        }

        std::printf("02_shadows\n");
        std::printf("  device     : %s\n", renderer.device_name().c_str());
        std::printf("  scene      : %s\n", options.scene.c_str());
        std::printf("  variant    : %s%s\n", options.variant.c_str(),
                    options.pipeline.empty() ? "" : " (pipeline spec)");
        std::printf("  resolution : %dx%d\n", renderer.width(), renderer.height());
        std::printf("  shadow map : %d (%d tap(s), %.5f world/texel)\n", options.shadow_size,
                    renderer.stats().taps, renderer.stats().texel_world);
        std::printf("  triangles  : %.0f, draw calls: %.0f\n", renderer.stats().triangles,
                    renderer.stats().draw_calls);
        std::printf("  gpu time   : %.4f ms%s\n", timing.gpu_ms,
                    options.timing_passes ? " (sum of passes, upper bound)" : "");
        std::printf("  cpu time   : %.4f ms (encode + commit)\n", timing.cpu_ms);
        for (const auto& entry : timing.passes) {
            std::printf("  %-10s : %.4f ms\n", entry.first.c_str(), entry.second);
        }

        const nx::io::Image color =
            read_color(renderer.color_texture(), renderer.width(), renderer.height());
        const PixelStats color_stats = analyze(color, 0);
        std::printf("  radiance   : min=%.5f max=%.5f mean=%.5f nonfinite=%lld\n",
                    color_stats.minimum, color_stats.maximum, color_stats.mean,
                    color_stats.nonfinite);

        nx::io::Image visibility;
        PixelStats visibility_stats;
        if (renderer.has_visibility()) {
            visibility = read_visibility(renderer.visibility_texture(), renderer.width(),
                                         renderer.height());
            visibility_stats = analyze(visibility, 0);
            std::printf("  visibility : min=%.5f max=%.5f mean=%.5f nonfinite=%lld\n",
                        visibility_stats.minimum, visibility_stats.maximum,
                        visibility_stats.mean, visibility_stats.nonfinite);
        }

        if (options.write_images) {
            const std::string color_path =
                options.out.empty() ? default_output_path(options, scene) : options.out;
            if (!write_image(color_path, color, &error)) {
                std::fprintf(stderr, "error: cannot write %s: %s\n", color_path.c_str(),
                             error.c_str());
                return 1;
            }
            std::printf("  output     : %s\n", color_path.c_str());

            if (renderer.has_visibility()) {
                const std::string vis_path = options.visibility_out.empty()
                                                 ? visibility_path_from(color_path)
                                                 : options.visibility_out;
                if (!write_image(vis_path, visibility, &error)) {
                    std::fprintf(stderr, "error: cannot write %s: %s\n", vis_path.c_str(),
                                 error.c_str());
                    return 1;
                }
                std::printf("  visibility : %s\n", vis_path.c_str());
            }
        }
        return 0;
    }
}
