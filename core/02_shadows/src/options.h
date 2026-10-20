// 02_shadows — command line and pipeline spec.
//
// The user facing story is `--variant <preset>` for the common cases and
// `--pipeline partition=...,storage=...,filter=...,bias=...` for explicit
// compositions. P0 only knows single_ortho + depth + nearest/pcf + compute;
// unknown components produce a message that lists what is available instead of
// silently falling back.

#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace nx::shadow {

enum class BiasMode { None, Slope, NormalOffset };

struct Options {
    std::string scene = ".cache/scenes/shadow_basic.nxscene";
    std::string variant = "sm";
    std::string pipeline;  // explicit component spec, empty when a preset is used

    std::string out;             // empty: build a reproducible default name
    std::string visibility_out;  // empty: build a reproducible default name
    std::string debug;           // albedo|normal|depth|visibility (overrides variant)
    std::string sweep_tag;       // optional tag included in the default file name

    int width = 0;
    int height = 0;
    int shadow_size = 2048;
    int pcf_taps = 3;

    float bias = 1e-3f;          // comparison bias in shadow-map NDC z
    float normal_offset = 0.0f;  // world units; 0 means derive from texel size
    float depth_bias = 0.0f;     // rasterizer constant bias in depth units
    float slope_bias = 0.0f;     // rasterizer slope-scaled bias

    BiasMode bias_mode = BiasMode::Slope;
    std::string cull = "front";  // shadow pass: front|back|none
    unsigned seed = 0;

    // Benchmark-only: encode the same frame N times into one command buffer
    // and divide the GPU time by N. At 768p/1080p the real cost is sub-ms,
    // where a single frame is dominated by scheduling noise.
    int bench_iterations = 8;

    bool self_test = false;
    bool list_variants = false;
    bool list_pipelines = false;
    bool help = false;
    bool validate = false;
    bool timing_passes = false;
    bool write_images = true;
};

inline bool parse_int(const char* text, int* out) {
    if (text == nullptr || *text == '\0') {
        return false;
    }
    char* end = nullptr;
    const long value = std::strtol(text, &end, 10);
    if (end == text || *end != '\0') {
        return false;
    }
    *out = static_cast<int>(value);
    return true;
}

inline bool parse_float(const char* text, float* out) {
    if (text == nullptr || *text == '\0') {
        return false;
    }
    char* end = nullptr;
    const float value = std::strtof(text, &end);
    if (end == text || *end != '\0') {
        return false;
    }
    *out = value;
    return true;
}

inline bool parse_uint(const char* text, unsigned* out) {
    if (text == nullptr || *text == '\0') {
        return false;
    }
    char* end = nullptr;
    const unsigned long value = std::strtoul(text, &end, 10);
    if (end == text || *end != '\0') {
        return false;
    }
    *out = static_cast<unsigned>(value);
    return true;
}

inline bool is_known_variant(const std::string& variant) {
    return variant == "albedo" || variant == "lit" || variant == "depth" ||
           variant == "sm" || variant == "pcf" || variant == "pcf3" ||
           variant == "pcf5";
}

inline std::string trimmed(const std::string& text) {
    const std::size_t first = text.find_first_not_of(" \t");
    if (first == std::string::npos) {
        return {};
    }
    const std::size_t last = text.find_last_not_of(" \t");
    return text.substr(first, last - first + 1);
}

// Parses a pipeline spec such as
//   partition=single_ortho,storage=depth,filter=pcf:5,bias=normal_offset
// and folds it into `options`. Returns false with a message for unknown or
// unsupported components.
inline bool apply_pipeline_spec(const std::string& spec, Options* options,
                                std::string* error) {
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (start <= spec.size()) {
        const std::size_t comma = spec.find(',', start);
        const std::string part =
            spec.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
        if (!trimmed(part).empty()) {
            parts.push_back(trimmed(part));
        }
        if (comma == std::string::npos) {
            break;
        }
        start = comma + 1;
    }

    if (parts.empty()) {
        *error = "--pipeline is empty";
        return false;
    }

    bool filter_seen = false;
    for (const std::string& part : parts) {
        const std::size_t equals = part.find('=');
        if (equals == std::string::npos) {
            *error = "pipeline component '" + part + "' is missing '='";
            return false;
        }
        const std::string key = trimmed(part.substr(0, equals));
        const std::string value = trimmed(part.substr(equals + 1));

        if (key == "partition") {
            if (value != "single_ortho") {
                *error = "unsupported partition '" + value +
                         "' (P0 knows single_ortho; cascades arrive in P4)";
                return false;
            }
        } else if (key == "storage") {
            if (value != "depth") {
                *error = "unsupported storage '" + value +
                         "' (P0 knows depth; moments arrive in P2)";
                return false;
            }
        } else if (key == "resolve") {
            if (value != "compute") {
                *error = "unsupported resolve '" + value +
                         "' (P0 knows compute; stencil arrives with shadow volumes)";
                return false;
            }
        } else if (key == "bias") {
            if (value == "none") {
                options->bias_mode = BiasMode::None;
                options->bias = 0.0f;
                options->normal_offset = 0.0f;
                options->depth_bias = 0.0f;
                options->slope_bias = 0.0f;
            } else if (value == "slope") {
                options->bias_mode = BiasMode::Slope;
            } else if (value == "normal_offset") {
                options->bias_mode = BiasMode::NormalOffset;
            } else {
                *error = "unknown bias mode '" + value +
                         "' (none|slope|normal_offset)";
                return false;
            }
        } else if (key == "filter") {
            filter_seen = true;
            std::string name = value;
            int taps = 0;
            const std::size_t colon = value.find(':');
            if (colon != std::string::npos) {
                name = value.substr(0, colon);
                if (!parse_int(value.c_str() + colon + 1, &taps) || taps < 1 ||
                    (taps % 2) == 0 || taps > 9) {
                    *error = "filter taps must be an odd number in [1, 9]";
                    return false;
                }
            }
            if (name == "nearest") {
                options->variant = "sm";
                options->pcf_taps = 1;
            } else if (name == "pcf") {
                options->variant = "pcf";
                if (taps > 0) {
                    options->pcf_taps = taps;
                }
            } else {
                *error = "unsupported filter '" + name +
                         "' (P0 knows nearest and pcf)";
                return false;
            }
        } else {
            *error = "unknown pipeline component '" + key +
                     "' (partition|storage|filter|bias|resolve)";
            return false;
        }
    }

    if (!filter_seen) {
        options->variant = "sm";
    }
    options->pipeline = spec;
    return true;
}

inline void print_variants() {
    std::printf(
        "variants:\n"
        "  albedo    flat albedo from the G-buffer (camera/geometry calibration)\n"
        "  lit       direct lighting, visibility forced to 1 (lighting calibration)\n"
        "  depth     linearized camera depth (debug)\n"
        "  sm        hard shadow map, nearest lookup\n"
        "  pcf       percentage-closer filtering, --pcf-taps 3|5|7\n"
        "  pcf3/pcf5 aliases for pcf with a fixed tap count\n");
}

inline void print_pipelines() {
    std::printf(
        "pipeline components supported in P0:\n"
        "  partition=single_ortho\n"
        "  storage=depth\n"
        "  filter=nearest|pcf[:N]      N odd in [1,9]\n"
        "  bias=none|slope|normal_offset\n"
        "  resolve=compute\n"
        "presets: sm, pcf3, pcf5\n"
        "example: --pipeline partition=single_ortho,storage=depth,filter=pcf:5,bias=slope\n");
}

// Returns false on a malformed command line. `error` is printable as-is.
inline bool parse_options(int argc, const char* const* argv, Options* options,
                          std::string* error) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value = [&](const char* what) -> const char* {
            if (i + 1 >= argc) {
                *error = std::string(what) + " needs a value";
                return nullptr;
            }
            return argv[++i];
        };

        if (arg == "--scene") {
            if (const char* v = value("--scene")) options->scene = v; else return false;
        } else if (arg == "--variant") {
            if (const char* v = value("--variant")) options->variant = v; else return false;
            if (!is_known_variant(options->variant)) {
                *error = "unknown variant '" + options->variant + "' (use --list-variants)";
                return false;
            }
        } else if (arg == "--pipeline") {
            if (const char* v = value("--pipeline")) options->pipeline = v; else return false;
        } else if (arg == "--out") {
            if (const char* v = value("--out")) options->out = v; else return false;
        } else if (arg == "--out-visibility") {
            if (const char* v = value("--out-visibility")) options->visibility_out = v; else return false;
        } else if (arg == "--debug") {
            if (const char* v = value("--debug")) options->debug = v; else return false;
        } else if (arg == "--width") {
            if (const char* v = value("--width")) { if (!parse_int(v, &options->width) || options->width <= 0) { *error = "--width must be positive"; return false; } } else return false;
        } else if (arg == "--height") {
            if (const char* v = value("--height")) { if (!parse_int(v, &options->height) || options->height <= 0) { *error = "--height must be positive"; return false; } } else return false;
        } else if (arg == "--shadow-size") {
            if (const char* v = value("--shadow-size")) { if (!parse_int(v, &options->shadow_size) || options->shadow_size < 16) { *error = "--shadow-size must be >= 16"; return false; } } else return false;
        } else if (arg == "--pcf-taps") {
            if (const char* v = value("--pcf-taps")) { if (!parse_int(v, &options->pcf_taps) || options->pcf_taps < 1 || (options->pcf_taps % 2) == 0 || options->pcf_taps > 9) { *error = "--pcf-taps must be odd in [1,9]"; return false; } } else return false;
        } else if (arg == "--bias") {
            if (const char* v = value("--bias")) { if (!parse_float(v, &options->bias)) { *error = "invalid --bias"; return false; } } else return false;
        } else if (arg == "--normal-offset") {
            if (const char* v = value("--normal-offset")) { if (!parse_float(v, &options->normal_offset) || options->normal_offset < 0.0f) { *error = "invalid --normal-offset"; return false; } } else return false;
        } else if (arg == "--depth-bias") {
            if (const char* v = value("--depth-bias")) { if (!parse_float(v, &options->depth_bias)) { *error = "invalid --depth-bias"; return false; } } else return false;
        } else if (arg == "--slope-bias") {
            if (const char* v = value("--slope-bias")) { if (!parse_float(v, &options->slope_bias)) { *error = "invalid --slope-bias"; return false; } } else return false;
        } else if (arg == "--cull") {
            if (const char* v = value("--cull")) options->cull = v; else return false;
            if (options->cull != "front" && options->cull != "back" && options->cull != "none") {
                *error = "--cull must be front|back|none";
                return false;
            }
        } else if (arg == "--bench-iterations") {
            if (const char* v = value("--bench-iterations")) {
                if (!parse_int(v, &options->bench_iterations) ||
                    options->bench_iterations < 1 || options->bench_iterations > 64) {
                    *error = "--bench-iterations must be in [1, 64]";
                    return false;
                }
            } else {
                return false;
            }
        } else if (arg == "--seed") {
            if (const char* v = value("--seed")) { if (!parse_uint(v, &options->seed)) { *error = "invalid --seed"; return false; } } else return false;
        } else if (arg == "--self-test") {
            options->self_test = true;
        } else if (arg == "--list-variants") {
            options->list_variants = true;
        } else if (arg == "--list-pipelines") {
            options->list_pipelines = true;
        } else if (arg == "--timing") {
            if (const char* v = value("--timing")) {
                if (std::strcmp(v, "frame") == 0) {
                    options->timing_passes = false;
                } else if (std::strcmp(v, "passes") == 0) {
                    options->timing_passes = true;
                } else {
                    *error = "--timing must be frame|passes";
                    return false;
                }
            } else {
                return false;
            }
        } else if (arg == "--validate") {
            options->validate = true;
        } else if (arg == "--no-write") {
            options->write_images = false;
        } else if (arg == "--help" || arg == "-h") {
            options->help = true;
        } else if (arg == "--bench-warmup" || arg == "--bench-frames" || arg == "--bench-out") {
            // Consumed by nx::profile::BenchOptions::parse; skip its value here.
            if (i + 1 < argc) {
                ++i;
            }
        } else {
            *error = "unknown option '" + arg + "' (see --help)";
            return false;
        }
    }

    // A preset and an explicit spec are two different ways to say the same
    // thing; the explicit spec is applied last and wins.
    if (!options->pipeline.empty()) {
        if (!apply_pipeline_spec(options->pipeline, options, error)) {
            return false;
        }
    }

    if (options->variant == "pcf3") {
        options->variant = "pcf";
        options->pcf_taps = 3;
    } else if (options->variant == "pcf5") {
        options->variant = "pcf";
        options->pcf_taps = 5;
    }

    return true;
}

inline std::string pipeline_tag(const Options& options) {
    if (!options.pipeline.empty()) {
        // Keep the tag filesystem friendly: the full spec lives in the report
        // metadata, the file name only needs to be unique and readable.
        std::string tag = options.pipeline;
        for (char& c : tag) {
            if (c == '=' || c == ',' || c == ':') {
                c = '-';
            }
        }
        return tag;
    }
    if (options.variant == "pcf") {
        return "pcf" + std::to_string(options.pcf_taps);
    }
    return options.variant;
}

}  // namespace nx::shadow
