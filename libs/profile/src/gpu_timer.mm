// nx::profile — Metal GPU timing implementation.

#include "nx/profile/gpu_timer.h"

#include <algorithm>

namespace nx::profile {
namespace {

void set_error(std::string* error, const std::string& message) {
    if (error != nullptr) {
        *error = message;
    }
}

id<MTLCounterSet> timestamp_counter_set(id<MTLDevice> device) {
    if (device == nil) {
        return nil;
    }
    for (id<MTLCounterSet> set in [device counterSets]) {
        if ([[set name] isEqualToString:MTLCommonCounterSetTimestamp]) {
            return set;
        }
    }
    return nil;
}

}  // namespace

double command_buffer_gpu_ms(id<MTLCommandBuffer> command_buffer) {
    if (command_buffer == nil) {
        return -1.0;
    }
    const CFTimeInterval start = command_buffer.GPUStartTime;
    const CFTimeInterval end   = command_buffer.GPUEndTime;
    if (start <= 0.0 || end < start) {
        return -1.0;
    }
    return (end - start) * 1000.0;
}

double command_buffer_wall_ms(id<MTLCommandBuffer> command_buffer) {
    if (command_buffer == nil) {
        return -1.0;
    }
    const CFTimeInterval start = command_buffer.kernelStartTime;
    const CFTimeInterval end   = command_buffer.kernelEndTime;
    if (start <= 0.0 || end < start) {
        return -1.0;
    }
    return (end - start) * 1000.0;
}

const char* timer_source_name(TimerSource source) {
    switch (source) {
        case TimerSource::CounterTimestamp:     return "counter-timestamp";
        case TimerSource::CommandBufferGpuTime: return "command-buffer-gpu-time";
        case TimerSource::WallClock:            return "wallclock";
    }
    return "unknown";
}

CounterCapabilities probe_counter_capabilities(id<MTLDevice> device) {
    CounterCapabilities capabilities;
    if (device == nil) {
        return capabilities;
    }
    capabilities.timestamp_counter_set = timestamp_counter_set(device) != nil;
    capabilities.stage_boundary    = [device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary];
    capabilities.draw_boundary     = [device supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary];
    capabilities.blit_boundary     = [device supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary];
    capabilities.dispatch_boundary = [device supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary];
    return capabilities;
}

bool GpuTimer::init(id<MTLDevice> device, int capacity, std::string* error) {
    m_buffer   = nil;
    m_capacity = 0;

    if (device == nil) {
        set_error(error, "gpu timer: no Metal device");
        return false;
    }
    if (capacity < 2) {
        set_error(error, "gpu timer: capacity must allow at least one begin/end pair");
        return false;
    }

    const CounterCapabilities capabilities = probe_counter_capabilities(device);
    if (!capabilities.timestamp_counter_set) {
        set_error(error, "gpu timer: device does not expose MTLCommonCounterSetTimestamp");
        return false;
    }
    // This class only inserts samples into compute encoders, and Metal aborts
    // the process when the device does not support that sampling point.
    if (!capabilities.compute_sampling()) {
        set_error(error,
                  "gpu timer: this device cannot sample compute encoders "
                  "(MTLCounterSamplingPointAtDispatchBoundary unsupported). "
                  "Use command_buffer_gpu_ms() instead.");
        return false;
    }

    MTLCounterSampleBufferDescriptor* descriptor =
        [[MTLCounterSampleBufferDescriptor alloc] init];
    descriptor.counterSet  = timestamp_counter_set(device);
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.sampleCount = static_cast<NSUInteger>(capacity);

    NSError* ns_error = nil;
    m_buffer = [device newCounterSampleBufferWithDescriptor:descriptor error:&ns_error];
    if (m_buffer == nil) {
        set_error(error,
                  std::string("gpu timer: cannot create counter sample buffer: ") +
                      (ns_error != nil ? ns_error.localizedDescription.UTF8String
                                       : "unknown error"));
        return false;
    }

    m_capacity = capacity;
    return true;
}

void GpuTimer::sample(id<MTLComputeCommandEncoder> encoder, int index, bool barrier) {
    if (m_buffer == nil || encoder == nil || index < 0 || index >= m_capacity) {
        return;
    }
    [encoder sampleCountersInBuffer:m_buffer
                      atSampleIndex:static_cast<NSUInteger>(index)
                        withBarrier:(barrier ? YES : NO)];
}

bool GpuTimer::resolve(id<MTLCommandBuffer> command_buffer,
                       std::vector<double>* milliseconds,
                       std::string* error) {
    if (m_buffer == nil) {
        set_error(error, "gpu timer: not initialised");
        return false;
    }
    if (command_buffer == nil) {
        set_error(error, "gpu timer: no command buffer");
        return false;
    }
    if (milliseconds == nullptr) {
        set_error(error, "gpu timer: null output vector");
        return false;
    }

    NSData* data = [m_buffer resolveCounterRange:NSMakeRange(0, static_cast<NSUInteger>(m_capacity))];
    if (data == nil) {
        set_error(error,
                  "gpu timer: resolveCounterRange returned nil — the command buffer "
                  "has to complete before the samples can be read");
        return false;
    }

    const MTLCounterResultTimestamp* stamps =
        reinterpret_cast<const MTLCounterResultTimestamp*>(data.bytes);
    const NSUInteger available = data.length / sizeof(MTLCounterResultTimestamp);

    milliseconds->assign(static_cast<std::size_t>(m_capacity), -1.0);
    const NSUInteger count = std::min<NSUInteger>(available, static_cast<NSUInteger>(m_capacity));
    for (NSUInteger i = 0; i < count; ++i) {
        if (stamps[i].timestamp == MTLCounterErrorValue) {
            (*milliseconds)[i] = -1.0;  // invalid sample, keep the marker
            continue;
        }
        // Timestamp counter values are nanoseconds on Apple GPUs.
        (*milliseconds)[i] = static_cast<double>(stamps[i].timestamp) / 1.0e6;
    }
    return true;
}

}  // namespace nx::profile
