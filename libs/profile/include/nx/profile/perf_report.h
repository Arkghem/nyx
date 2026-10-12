// nx::profile — frame timing collection and benchmark reports.
//
// The report format is the contract between experiments, scripts/bench.sh and
// scripts/perf_gate.py. Changing it means changing perf_gate.py too.

#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <vector>

namespace nx::profile {

// Collects per-frame or per-pass timings in milliseconds and answers
// percentile queries.
//
// Benchmarks are judged on p95 rather than the mean: a renderer that is fast on
// average but stutters is not a renderer that holds a frame budget.
class FrameStats {
public:
    void   add(double milliseconds);
    void   reserve(std::size_t count);

    std::size_t count() const { return m_samples.size(); }
    bool        empty() const { return m_samples.empty(); }

    double min() const;
    double max() const;
    double mean() const;
    double sum() const { return m_sum; }

    // Nearest-rank percentile, p in [0, 1]. Returns 0 when there is no sample.
    double percentile(double p) const;

    const std::vector<double>& samples() const { return m_samples; }

private:
    std::vector<double> m_samples;
    mutable std::vector<double> m_sorted;
    mutable bool   m_sorted_valid = false;
    double         m_sum          = 0.0;
};

// One benchmark run.
struct PerfReport {
    std::string experiment;
    // "timestamp-counter" when the numbers came from MTLCounterSampleBuffer,
    // "wallclock" when the device could not provide counters. Gates must not
    // compare across different sources.
    std::string timer_source = "wallclock";
    std::string renderer;                       // metal | forge | python
    std::string hw;                             // filled by hostDescription()
    std::string commit;                         // git revision, may be empty
    std::string timestamp;                      // ISO 8601, filled when empty
    bool        vsync = false;
    int         width = 0;
    int         height = 0;
    int         warmup_frames = 0;

    FrameStats frame_ms;
    std::map<std::string, FrameStats> passes;
    std::map<std::string, double>     counters;

    std::string to_json() const;
    bool        write_json(const std::string& path, std::string* error = nullptr) const;
};

// Machine description, e.g. "arm64 macOS 26.6.2 (Apple M4 Pro)".
std::string hostDescription();

// ISO 8601 timestamp for "now", local time.
std::string isoTimestampNow();

// Filesystem-safe timestamp, e.g. "20261012-115700". Used in report names.
std::string fileTimestampNow();

}  // namespace nx::profile
