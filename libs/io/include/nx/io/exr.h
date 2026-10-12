// nx::io — linear HDR image input/output.
//
// nyx compares renders in linear light, before any tone mapping, so EXR is the
// only format that matters here. The public header deliberately does not leak
// the underlying EXR library.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace nx::io {

// Interleaved floating point image.
//
// Channels is 1, 3 or 4 and the component order is R, G, B, A. Values are
// linear light with no tone mapping applied.
struct Image {
    int                width    = 0;
    int                height   = 0;
    int                channels = 0;
    std::vector<float> pixels;

    bool valid() const {
        return width > 0 && height > 0 && channels > 0 &&
               pixels.size() == static_cast<size_t>(width) * height * channels;
    }

    void resize(int w, int h, int c) {
        width    = w;
        height   = h;
        channels = c;
        pixels.assign(static_cast<size_t>(w) * h * c, 0.0f);
    }

    float*       row(int y) { return pixels.data() + static_cast<size_t>(y) * width * channels; }
    const float* row(int y) const { return pixels.data() + static_cast<size_t>(y) * width * channels; }

    // Convenience accessor; returns 0 for out-of-range coordinates.
    float at(int x, int y, int c) const {
        if (x < 0 || y < 0 || x >= width || y >= height || c < 0 || c >= channels) {
            return 0.0f;
        }
        return row(y)[static_cast<size_t>(x) * channels + c];
    }
};

// Reads an EXR file into `out`. The result always carries 4 channels (A is
// filled with 1 where the file has none), because every reader path in nyx
// compares RGBA in linear light.
//
// Failures are reported through `error` instead of exceptions: experiments are
// plain command line tools and want a message, not a stack unwind.
bool read_exr(const std::string& path, Image* out, std::string* error = nullptr);

// Writes `image` as a float32 EXR. Channels must be 1, 3 or 4.
bool write_exr(const std::string& path, const Image& image, std::string* error = nullptr);

}  // namespace nx::io
