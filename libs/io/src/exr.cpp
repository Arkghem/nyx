// nx::io — EXR implementation on top of tinyexr.

#include "nx/io/exr.h"

#define TINYEXR_IMPLEMENTATION
#include <tinyexr.h>

#include <cstdlib>
#include <filesystem>

namespace nx::io {
namespace {

void set_error(std::string* error, const std::string& message) {
    if (error != nullptr) {
        *error = message;
    }
}

// tinyexr hands back a heap string that the caller owns.
void take_tinyexr_error(std::string* error, const char* message) {
    if (error != nullptr) {
        *error = (message != nullptr) ? message : "unknown tinyexr error";
    }
    if (message != nullptr) {
        FreeEXRErrorMessage(message);
    }
}

}  // namespace

bool read_exr(const std::string& path, Image* out, std::string* error) {
    if (out == nullptr) {
        set_error(error, "read_exr: null output image");
        return false;
    }

    float* rgba       = nullptr;
    int    width      = 0;
    int    height     = 0;
    const char* tinyexr_error = nullptr;

    // LoadEXR converts whatever the file holds (half, float, integer) to float
    // RGBA, which avoids reimplementing tinyexr's pixel type plumbing.
    const int result = LoadEXR(&rgba, &width, &height, path.c_str(), &tinyexr_error);
    if (result != TINYEXR_SUCCESS) {
        take_tinyexr_error(error, tinyexr_error);
        return false;
    }

    out->resize(width, height, 4);
    std::copy(rgba, rgba + static_cast<size_t>(width) * height * 4, out->pixels.begin());
    std::free(rgba);
    return true;
}

bool write_exr(const std::string& path, const Image& image, std::string* error) {
    if (!image.valid()) {
        set_error(error, "write_exr: image is empty or inconsistent");
        return false;
    }
    if (image.channels != 1 && image.channels != 3 && image.channels != 4) {
        set_error(error, "write_exr: channels must be 1, 3 or 4");
        return false;
    }

    // Create the parent directory if needed: experiments are usually pointed at
    // outputs/ or references/ and should not have to mkdir first.
    std::error_code ec;
    const std::filesystem::path target(path);
    if (target.has_parent_path() && !target.parent_path().empty()) {
        std::filesystem::create_directories(target.parent_path(), ec);
        if (ec) {
            set_error(error, "write_exr: cannot create " + target.parent_path().string() +
                                 ": " + ec.message());
            return false;
        }
    }

    // SaveEXR picks ZIP compression for images of at least 16x16 and leaves
    // smaller ones uncompressed.
    const char* tinyexr_error = nullptr;
    const int result = SaveEXR(image.pixels.data(),
                               image.width,
                               image.height,
                               image.channels,
                               /*save_as_fp16=*/0,
                               path.c_str(),
                               &tinyexr_error);
    if (result != TINYEXR_SUCCESS) {
        take_tinyexr_error(error, tinyexr_error);
        return false;
    }
    return true;
}

}  // namespace nx::io
