// nx::profile — frame statistics and benchmark report serialisation.

#include "nx/profile/perf_report.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <sys/sysctl.h>
#include <sys/utsname.h>

namespace nx::profile {
namespace {

// Minimal JSON string escaping: enough for the identifiers nyx writes
// (experiment names, pass names, host strings).
std::string escape(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (const char c : value) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    std::ostringstream hex;
                    hex << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                        << static_cast<int>(static_cast<unsigned char>(c));
                    out += hex.str();
                } else {
                    out += c;
                }
        }
    }
    return out;
}

std::string quote(const std::string& value) {
    return "\"" + escape(value) + "\"";
}

std::string number(double value) {
    if (!std::isfinite(value)) {
        return "null";
    }
    std::ostringstream out;
    out << std::setprecision(6) << value;
    return out.str();
}

// Statistics block shared by the frame timing and every pass.
std::string stats_json(const FrameStats& stats, const std::string& indent) {
    std::ostringstream out;
    out << "{\n";
    out << indent << "  \"samples\": " << stats.count() << ",\n";
    out << indent << "  \"min\": "  << number(stats.min())  << ",\n";
    out << indent << "  \"mean\": " << number(stats.mean()) << ",\n";
    out << indent << "  \"p50\": "  << number(stats.percentile(0.50)) << ",\n";
    out << indent << "  \"p95\": "  << number(stats.percentile(0.95)) << ",\n";
    out << indent << "  \"p99\": "  << number(stats.percentile(0.99)) << ",\n";
    out << indent << "  \"max\": "  << number(stats.max())  << "\n";
    out << indent << "}";
    return out.str();
}

std::string brandString() {
    char   buffer[256] = {0};
    size_t size        = sizeof(buffer);
    if (sysctlbyname("machdep.cpu.brand_string", buffer, &size, nullptr, 0) == 0) {
        return std::string(buffer);
    }
    return {};
}

}  // namespace

// ---------------------------------------------------------------------------
// FrameStats
// ---------------------------------------------------------------------------

void FrameStats::add(double milliseconds) {
    m_samples.push_back(milliseconds);
    m_sum         += milliseconds;
    m_sorted_valid = false;
}

void FrameStats::reserve(std::size_t count) {
    m_samples.reserve(count);
}

double FrameStats::min() const {
    if (m_samples.empty()) {
        return 0.0;
    }
    return *std::min_element(m_samples.begin(), m_samples.end());
}

double FrameStats::max() const {
    if (m_samples.empty()) {
        return 0.0;
    }
    return *std::max_element(m_samples.begin(), m_samples.end());
}

double FrameStats::mean() const {
    if (m_samples.empty()) {
        return 0.0;
    }
    return m_sum / static_cast<double>(m_samples.size());
}

double FrameStats::percentile(double p) const {
    if (m_samples.empty()) {
        return 0.0;
    }
    if (p <= 0.0) {
        return min();
    }
    if (p >= 1.0) {
        return max();
    }
    if (!m_sorted_valid) {
        m_sorted       = m_samples;
        std::sort(m_sorted.begin(), m_sorted.end());
        m_sorted_valid = true;
    }
    // Nearest rank with rounding. For a sorted sample of size n, p95 of a
    // 600 frame run lands on the 570th value.
    const double rank = p * static_cast<double>(m_sorted.size() - 1);
    const auto   index = static_cast<std::size_t>(std::llround(rank));
    return m_sorted[std::min(index, m_sorted.size() - 1)];
}

// ---------------------------------------------------------------------------
// PerfReport
// ---------------------------------------------------------------------------

std::string PerfReport::to_json() const {
    const std::string timestamp_value = timestamp.empty() ? isoTimestampNow() : timestamp;
    const std::string hw_value        = hw.empty() ? hostDescription() : hw;

    std::ostringstream out;
    out << "{\n";
    out << "  \"experiment\": "   << quote(experiment) << ",\n";
    out << "  \"timestamp\": "    << quote(timestamp_value) << ",\n";
    out << "  \"commit\": "       << quote(commit) << ",\n";
    out << "  \"hw\": "           << quote(hw_value) << ",\n";
    out << "  \"renderer\": "     << quote(renderer) << ",\n";
    out << "  \"timer_source\": " << quote(timer_source) << ",\n";
    out << "  \"vsync\": "        << (vsync ? "true" : "false") << ",\n";
    out << "  \"resolution\": ["  << width << ", " << height << "],\n";
    out << "  \"warmup_frames\": " << warmup_frames << ",\n";
    out << "  \"frames\": "       << frame_ms.count() << ",\n";
    out << "  \"frame_ms\": "     << stats_json(frame_ms, "  ") << ",\n";

    out << "  \"passes\": {";
    if (passes.empty()) {
        out << "},\n";
    } else {
        out << "\n";
        std::size_t index = 0;
        for (const auto& entry : passes) {
            out << "    " << quote(entry.first) << ": "
                << stats_json(entry.second, "    ");
            out << (++index < passes.size() ? ",\n" : "\n");
        }
        out << "  },\n";
    }

    out << "  \"counters\": {";
    if (counters.empty()) {
        out << "}\n";
    } else {
        out << "\n";
        std::size_t index = 0;
        for (const auto& entry : counters) {
            out << "    " << quote(entry.first) << ": " << number(entry.second);
            out << (++index < counters.size() ? ",\n" : "\n");
        }
        out << "  }\n";
    }
    out << "}\n";
    return out.str();
}

bool PerfReport::write_json(const std::string& path, std::string* error) const {
    std::error_code ec;
    const std::filesystem::path target(path);
    if (target.has_parent_path()) {
        std::filesystem::create_directories(target.parent_path(), ec);
        if (ec) {
            if (error != nullptr) {
                *error = "cannot create directory " + target.parent_path().string() +
                         ": " + ec.message();
            }
            return false;
        }
    }

    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) {
        if (error != nullptr) {
            *error = "cannot open " + path + " for writing";
        }
        return false;
    }
    file << to_json();
    return static_cast<bool>(file);
}

// ---------------------------------------------------------------------------
// Host helpers
// ---------------------------------------------------------------------------

std::string hostDescription() {
    std::ostringstream out;

    struct utsname info {};
    if (uname(&info) == 0) {
        out << info.machine << " " << info.sysname << " " << info.release;
    } else {
        out << "unknown host";
    }

    const std::string brand = brandString();
    if (!brand.empty()) {
        out << " (" << brand << ")";
    }
    return out.str();
}

std::string isoTimestampNow() {
    const std::time_t now = std::time(nullptr);
    std::tm           tm_now {};
    localtime_r(&now, &tm_now);

    std::ostringstream out;
    out << std::put_time(&tm_now, "%Y-%m-%dT%H:%M:%S");
    return out.str();
}

std::string fileTimestampNow() {
    const std::time_t now = std::time(nullptr);
    std::tm           tm_now {};
    localtime_r(&now, &tm_now);

    std::ostringstream out;
    out << std::put_time(&tm_now, "%Y%m%d-%H%M%S");
    return out.str();
}

}  // namespace nx::profile
