// nx::profile — benchmark CLI contract.
//
// Every experiment that can be benchmarked accepts the same three flags, so
// scripts/bench.sh does not need to know anything about the experiment:
//
//   --bench-warmup <n>   frames rendered before measurement starts
//   --bench-frames <n>   number of frames measured
//   --bench-out <path>   where the JSON report is written
//
// Applications that do not own their command line (The-Forge unit tests are
// launched with their own arguments) can use the environment variable instead:
//
//   NYX_BENCH="<warmup>,<frames>,<out path>"

#pragma once

#include <cstdlib>
#include <cstring>
#include <string>

namespace nx::profile {

struct BenchOptions {
    bool        enabled = false;
    int         warmup  = 60;
    int         frames  = 600;
    std::string out;

    static BenchOptions parse(int argc, const char* const* argv) {
        BenchOptions options;

        for (int i = 1; i < argc; ++i) {
            const char* arg = argv[i];
            if (arg == nullptr) {
                continue;
            }
            const bool has_value = (i + 1) < argc;

            if (std::strcmp(arg, "--bench-warmup") == 0 && has_value) {
                options.warmup  = std::atoi(argv[++i]);
                options.enabled = true;
            } else if (std::strcmp(arg, "--bench-frames") == 0 && has_value) {
                options.frames  = std::atoi(argv[++i]);
                options.enabled = true;
            } else if (std::strcmp(arg, "--bench-out") == 0 && has_value) {
                options.out     = argv[++i];
                options.enabled = true;
            }
        }

        // Environment fallback: "<warmup>,<frames>,<path>".
        const char* env = std::getenv("NYX_BENCH");
        if (env != nullptr && env[0] != '\0') {
            const std::string spec(env);
            const std::size_t first  = spec.find(',');
            const std::size_t second = (first == std::string::npos)
                                           ? std::string::npos
                                           : spec.find(',', first + 1);
            if (first != std::string::npos) {
                options.warmup = std::atoi(spec.substr(0, first).c_str());
                options.enabled = true;
                if (second != std::string::npos) {
                    options.frames = std::atoi(spec.substr(first + 1, second - first - 1).c_str());
                    options.out    = spec.substr(second + 1);
                } else {
                    options.frames = std::atoi(spec.substr(first + 1).c_str());
                }
            }
        }

        if (options.frames <= 0) {
            options.frames = 600;
        }
        if (options.warmup < 0) {
            options.warmup = 0;
        }
        return options;
    }
};

}  // namespace nx::profile
