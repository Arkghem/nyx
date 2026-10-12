// nx::metrics — image quality metrics.
//
// Everything here operates on linear light, before tone mapping. Comparing
// tone-mapped images hides energy errors that the whole Mitsuba-vs-Forge loop
// exists to expose.

#pragma once

#include "nx/io/exr.h"

#include <string>

namespace nx::metrics {

struct QualityReport {
    double mse          = 0.0;
    double mae          = 0.0;
    double max_abs_diff = 0.0;
    // Peak signal to noise ratio in dB against a peak of 1.0. Positive
    // infinity when the images are identical.
    double psnr = 0.0;
    // Number of compared values, for sanity checking.
    long long samples = 0;
};

// Compares two images in linear light. Dimensions must match; when the channel
// counts differ the smaller count is used.
bool compare(const nx::io::Image& reference,
             const nx::io::Image& test,
             QualityReport*       out,
             std::string*         error = nullptr);

// |reference - test| * scale, written out as the diff image of a report.
// A scale of 10 is the default because meaningful differences are usually
// small compared to the full range.
nx::io::Image diff_image(const nx::io::Image& reference,
                         const nx::io::Image& test,
                         float                scale = 10.0f);

}  // namespace nx::metrics
