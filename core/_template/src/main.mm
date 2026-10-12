// Template experiment — a minimal Metal compute program that runs.
//
// Copy this directory with ./scripts/new_exp.sh <name> and build it up. The
// pattern below (device -> library -> pipeline -> dispatch -> readback) is the
// same one every native experiment follows.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "nx/io/exr.h"
#include "nx/profile/perf_report.h"

namespace {

void fail(const std::string& message) {
    std::fprintf(stderr, "error: %s\n", message.c_str());
}

}  // namespace

int main(int argc, const char* const* argv) {
    @autoreleasepool {
        int         width  = 256;
        int         height = 256;
        std::string out_path = "outputs/_template.exr";

        for (int i = 1; i < argc; ++i) {
            if (std::strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
                width = std::atoi(argv[++i]);
            } else if (std::strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
                height = std::atoi(argv[++i]);
            } else if (std::strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
                out_path = argv[++i];
            }
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            fail("no Metal device available");
            return 1;
        }

        NSString* library_path =
            [NSString stringWithFormat:@"%s/_template.metallib", NX_SHADER_DIR];
        NSError*  ns_error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:library_path]
                                                     error:&ns_error];
        if (library == nil) {
            fail(std::string("cannot load ") + library_path.UTF8String + ": " +
                 (ns_error != nil ? ns_error.localizedDescription.UTF8String : "unknown"));
            return 1;
        }

        id<MTLFunction> function = [library newFunctionWithName:@"template_fill"];
        if (function == nil) {
            fail("kernel template_fill not found in the metallib");
            return 1;
        }

        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&ns_error];
        if (pipeline == nil) {
            fail(std::string("cannot create pipeline: ") +
                 (ns_error != nil ? ns_error.localizedDescription.UTF8String : "unknown"));
            return 1;
        }

        const NSUInteger pixel_count = static_cast<NSUInteger>(width) * height;
        id<MTLBuffer> buffer = [device newBufferWithLength:pixel_count * 4 * sizeof(float)
                                                   options:MTLResourceStorageModeShared];
        if (buffer == nil) {
            fail("cannot allocate output buffer");
            return 1;
        }

        struct Parameters {
            int width;
            int height;
        } parameters{width, height};

        id<MTLCommandQueue>        queue   = [device newCommandQueue];
        id<MTLCommandBuffer>       command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];

        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:buffer offset:0 atIndex:0];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(width),
                                             static_cast<NSUInteger>(height), 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding];

        [command commit];
        [command waitUntilCompleted];

        if (command.status == MTLCommandBufferStatusError) {
            fail(std::string("command buffer failed: ") +
                 (command.error != nil ? command.error.localizedDescription.UTF8String
                                       : "unknown"));
            return 1;
        }

        nx::io::Image image;
        image.resize(width, height, 4);
        std::memcpy(image.pixels.data(), buffer.contents, pixel_count * 4 * sizeof(float));

        std::string error;
        if (!nx::io::write_exr(out_path, image, &error)) {
            fail("cannot write " + out_path + ": " + error);
            return 1;
        }

        double sum = 0.0;
        for (size_t i = 0; i < image.pixels.size(); i += 4) {
            sum += image.pixels[i];
        }

        std::printf("device      : %s\n", device.name.UTF8String);
        std::printf("resolution  : %dx%d\n", width, height);
        std::printf("mean R      : %.4f\n", sum / static_cast<double>(pixel_count));
        std::printf("output      : %s\n", out_path.c_str());
        return 0;
    }
}
