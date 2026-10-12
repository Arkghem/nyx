// nx::profile — GPU timing primitives for Metal.
//
// Two mechanisms exist, and which one you can use depends on the device. Both
// were probed on the development machine (Apple M3 Max) before this API was
// fixed, and the results shaped it:
//
//   * MTLCommandBuffer.GPUStartTime / GPUEndTime — the GPU execution window of
//     one command buffer. Available everywhere, measured directly on the GPU,
//     and therefore the default.
//
//   * MTLCounterSampleBuffer — per-pass timestamps. Requires both the
//     "timestamp" counter set and a counter *sampling point*. The M3 Max
//     reports only MTLCounterSamplingPointAtStageBoundary, which means
//     compute encoders cannot be sampled at all:
//
//         AtStageBoundary     YES
//         AtDrawBoundary      NO
//         AtBlitBoundary      NO
//         AtDispatchBoundary  NO
//
//     Calling sampleCountersInBuffer on a compute encoder there aborts the
//     process, so GpuTimer refuses to arm itself unless the caller asks for a
//     sampling point the device actually supports.
//
// This is an Objective-C++ header.

#pragma once

#import <Metal/Metal.h>

#include <string>
#include <vector>

namespace nx::profile {

// GPU time of a single command buffer, in milliseconds. Returns -1 when the
// driver did not report a window (for example when the buffer never ran).
double command_buffer_gpu_ms(id<MTLCommandBuffer> command_buffer);

// Wall-clock time of a single command buffer, in milliseconds.
double command_buffer_wall_ms(id<MTLCommandBuffer> command_buffer);

// Where the numbers in a report came from. Gates must never compare across
// different sources.
enum class TimerSource {
    CounterTimestamp,     // per-pass MTLCounterSampleBuffer samples
    CommandBufferGpuTime, // GPUStartTime/GPUEndTime per command buffer
    WallClock,            // CPU side stopwatch, includes submission overhead
};

const char* timer_source_name(TimerSource source);

// Capability probe for counter based sampling. Kept explicit because the
// answers differ per model and silence here means a process abort later.
struct CounterCapabilities {
    bool timestamp_counter_set = false;
    bool stage_boundary        = false;  // render encoder stage boundaries
    bool draw_boundary         = false;
    bool blit_boundary         = false;
    bool dispatch_boundary     = false;  // what a compute encoder would need

    // True when a compute encoder may be sampled on this device.
    bool compute_sampling() const { return timestamp_counter_set && dispatch_boundary; }
    // True when counter based per-pass timing is possible at all.
    bool any_sampling() const { return timestamp_counter_set && (stage_boundary || any_boundary()); }

private:
    bool any_boundary() const { return draw_boundary || blit_boundary || dispatch_boundary; }
};

CounterCapabilities probe_counter_capabilities(id<MTLDevice> device);

// Per-pass GPU timestamps from a counter sample buffer.
//
// Only usable on devices and encoders where probe_counter_capabilities()
// reports support. Always check before arming: on an unsupported device the
// Metal validation layer aborts rather than returning an error.
class GpuTimer {
public:
    // Allocates a sample buffer for `capacity` samples. Use two samples
    // (begin, end) per pass. Fails with an explanatory message when the device
    // cannot sample compute encoders.
    bool init(id<MTLDevice> device, int capacity, std::string* error = nullptr);

    // Inserts a timestamp sample into a compute encoder. Does nothing when the
    // timer is not armed.
    void sample(id<MTLComputeCommandEncoder> encoder, int index, bool barrier = true);

    // Reads the samples back after the command buffer completed. Returns one
    // entry per sample in milliseconds; negative values mark invalid samples.
    bool resolve(id<MTLCommandBuffer> command_buffer,
                 std::vector<double>* milliseconds,
                 std::string* error = nullptr);

    int  capacity() const { return m_capacity; }
    bool ready() const { return m_buffer != nil; }

private:
    id<MTLCounterSampleBuffer> m_buffer   = nil;
    int                        m_capacity = 0;
};

}  // namespace nx::profile
