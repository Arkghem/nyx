// nx::metrics — metric implementation.

#include "nx/metrics/metrics.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace nx::metrics {
namespace {

void set_error(std::string* error, const std::string& message) {
    if (error != nullptr) {
        *error = message;
    }
}

}  // namespace

bool compare(const nx::io::Image& reference,
             const nx::io::Image& test,
             QualityReport*       out,
             std::string*         error) {
    if (out == nullptr) {
        set_error(error, "compare: null report");
        return false;
    }
    if (!reference.valid() || !test.valid()) {
        set_error(error, "compare: empty image");
        return false;
    }
    if (reference.width != test.width || reference.height != test.height) {
        set_error(error, "compare: resolution mismatch");
        return false;
    }

    const int channels = std::min(reference.channels, test.channels);
    if (channels <= 0) {
        set_error(error, "compare: no common channels");
        return false;
    }

    QualityReport report;
    long long     samples = 0;
    double        sum_sq  = 0.0;
    double        sum_abs = 0.0;
    double        max_abs = 0.0;

    for (int y = 0; y < reference.height; ++y) {
        const float* ref_row  = reference.row(y);
        const float* test_row = test.row(y);
        for (int x = 0; x < reference.width; ++x) {
            const std::size_t ref_base  = static_cast<std::size_t>(x) * reference.channels;
            const std::size_t test_base = static_cast<std::size_t>(x) * test.channels;
            for (int c = 0; c < channels; ++c) {
                const double delta = static_cast<double>(ref_row[ref_base + c]) -
                                     static_cast<double>(test_row[test_base + c]);
                const double abs_delta = std::fabs(delta);
                sum_sq  += delta * delta;
                sum_abs += abs_delta;
                max_abs  = std::max(max_abs, abs_delta);
                ++samples;
            }
        }
    }

    if (samples == 0) {
        set_error(error, "compare: nothing to compare");
        return false;
    }

    report.samples      = samples;
    report.mse          = sum_sq / static_cast<double>(samples);
    report.mae          = sum_abs / static_cast<double>(samples);
    report.max_abs_diff = max_abs;
    // Peak of 1.0: nyx images are linear light normalised to [0, 1] reference
    // white, so this matches the convention used by the Python side.
    report.psnr = (report.mse > 0.0)
                      ? 10.0 * std::log10(1.0 / report.mse)
                      : std::numeric_limits<double>::infinity();

    *out = report;
    return true;
}

nx::io::Image diff_image(const nx::io::Image& reference, const nx::io::Image& test, float scale) {
    nx::io::Image result;
    if (!reference.valid() || !test.valid()) {
        return result;
    }
    if (reference.width != test.width || reference.height != test.height) {
        return result;
    }

    const int channels = std::min(reference.channels, test.channels);
    result.resize(reference.width, reference.height, channels);

    for (int y = 0; y < reference.height; ++y) {
        const float* ref_row  = reference.row(y);
        const float* test_row = test.row(y);
        float*       out_row  = result.row(y);
        for (int x = 0; x < reference.width; ++x) {
            const std::size_t ref_base  = static_cast<std::size_t>(x) * reference.channels;
            const std::size_t test_base = static_cast<std::size_t>(x) * test.channels;
            const std::size_t out_base  = static_cast<std::size_t>(x) * channels;
            for (int c = 0; c < channels; ++c) {
                out_row[out_base + c] =
                    std::fabs(ref_row[ref_base + c] - test_row[test_base + c]) * scale;
            }
        }
    }
    return result;
}

}  // namespace nx::metrics
