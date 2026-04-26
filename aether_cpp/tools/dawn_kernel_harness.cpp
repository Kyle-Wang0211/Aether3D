// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "dawn_kernel_harness.h"

#include <iostream>
#include <ostream>

namespace aether {
namespace tools {

namespace {

// StringView printer (Dawn callbacks return wgpu::StringView, not const char*).
std::ostream& operator<<(std::ostream& os, const wgpu::StringView& s) {
    if (s.data == nullptr) {
        return os;
    }
    if (s.length == WGPU_STRLEN) {
        return os << s.data;
    }
    return os.write(s.data, static_cast<std::streamsize>(s.length));
}

const char* error_type_name(wgpu::ErrorType t) {
    switch (t) {
        case wgpu::ErrorType::NoError:     return "NoError";
        case wgpu::ErrorType::Validation:  return "Validation";
        case wgpu::ErrorType::OutOfMemory: return "OutOfMemory";
        case wgpu::ErrorType::Internal:    return "Internal";
        case wgpu::ErrorType::Unknown:     return "Unknown";
    }
    return "<?>";
}

// Stateless uncaptured-error callback: defined at namespace scope so the
// SetUncapturedErrorCallback assert (callback must NOT be a binding
// lambda) is satisfied. Failure mode = abort() so a binding/validation
// bug DOES NOT silently hide as "test passed but output zeroed". Per
// Phase 6.3a code review (2026-04-26 ~11:30): silence is the worst
// failure mode for a 5-layer-validation harness.
void on_uncaptured_error(const wgpu::Device& /*device*/,
                          wgpu::ErrorType type,
                          wgpu::StringView msg) {
    std::cerr << "\n[Dawn UNCAPTURED ERROR] type=" << error_type_name(type)
              << " (" << static_cast<unsigned>(type) << ")\n  message: "
              << msg << '\n'
              << "  Aborting — silent validation pass would defeat the harness\n";
    std::abort();
}

}  // namespace

DawnKernelHarness::DawnKernelHarness() = default;

DawnKernelHarness::~DawnKernelHarness() {
    // wgpu:: types are RAII; destruct in reverse acquisition order is
    // automatic via member-init-reversed teardown.
}

bool DawnKernelHarness::init() {
    // ─── Instance: enable TimedWaitAny so wgpuInstanceWaitAny works
    //                with WaitAnyOnly callback mode (sync bridge).
    static constexpr auto kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
    wgpu::InstanceDescriptor instance_desc{
        .requiredFeatureCount = 1,
        .requiredFeatures = &kTimedWaitAny,
    };
    instance_ = wgpu::CreateInstance(&instance_desc);
    if (instance_ == nullptr) {
        std::cerr << "[DawnKernelHarness] wgpu::CreateInstance failed\n";
        return false;
    }

    // ─── Adapter: sync via WaitAny + UINT64_MAX ───
    {
        wgpu::RequestAdapterOptions options{};
        instance_.WaitAny(
            instance_.RequestAdapter(
                &options,
                wgpu::CallbackMode::WaitAnyOnly,
                [this](wgpu::RequestAdapterStatus status,
                       wgpu::Adapter adapter,
                       wgpu::StringView message) {
                    if (status != wgpu::RequestAdapterStatus::Success) {
                        std::cerr << "[DawnKernelHarness] RequestAdapter failed: "
                                  << message << '\n';
                        return;
                    }
                    adapter_ = std::move(adapter);
                }),
            UINT64_MAX);
        if (adapter_ == nullptr) {
            std::cerr << "[DawnKernelHarness] adapter is null\n";
            return false;
        }
    }

    // ─── Device: sync via WaitAny + UINT64_MAX ───
    {
        wgpu::DeviceDescriptor device_desc{};
        // Phase 6.3a P1 fix: register uncaptured-error callback BEFORE
        // requesting the device so any subsequent validation error
        // (binding mismatch, wrong stage usage, size error, etc.) calls
        // the abort path rather than silently corrupting test results.
        // Without this, a wrong binding can produce "kernel ran, output
        // is zero, no NaN" → smoke test reports PASS while binding is
        // actually broken. Aborting on validation error makes the failure
        // loud + immediate, which is the whole point of a smoke harness.
        device_desc.SetUncapturedErrorCallback(on_uncaptured_error);
        instance_.WaitAny(
            adapter_.RequestDevice(
                &device_desc,
                wgpu::CallbackMode::WaitAnyOnly,
                [this](wgpu::RequestDeviceStatus status,
                       wgpu::Device device,
                       wgpu::StringView message) {
                    if (status != wgpu::RequestDeviceStatus::Success) {
                        std::cerr << "[DawnKernelHarness] RequestDevice failed: "
                                  << message << '\n';
                        return;
                    }
                    device_ = std::move(device);
                }),
            UINT64_MAX);
        if (device_ == nullptr) {
            std::cerr << "[DawnKernelHarness] device is null\n";
            return false;
        }
    }

    // ─── Queue: sync accessor ───
    queue_ = device_.GetQueue();
    if (queue_ == nullptr) {
        std::cerr << "[DawnKernelHarness] device.GetQueue returned null\n";
        return false;
    }
    return true;
}

wgpu::Buffer DawnKernelHarness::upload(const void* data, size_t size,
                                        wgpu::BufferUsage usage) {
    wgpu::BufferDescriptor desc{
        .usage = usage | wgpu::BufferUsage::CopyDst,
        .size = size,
    };
    wgpu::Buffer buf = device_.CreateBuffer(&desc);
    queue_.WriteBuffer(buf, /*offset=*/0, data, size);
    return buf;
}

wgpu::Buffer DawnKernelHarness::alloc(size_t size, wgpu::BufferUsage usage) {
    wgpu::BufferDescriptor desc{
        .usage = usage,
        .size = size,
    };
    return device_.CreateBuffer(&desc);
}

wgpu::Buffer DawnKernelHarness::alloc_staging_for_readback(size_t size) {
    wgpu::BufferDescriptor desc{
        .usage = wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst,
        .size = size,
    };
    return device_.CreateBuffer(&desc);
}

wgpu::ComputePipeline
DawnKernelHarness::load_compute(std::string_view wgsl_source,
                                const char* entry_point) {
    wgpu::ShaderSourceWGSL wgsl_desc{};
    // wgpu::StringView from string_view: pointer + length (avoids strlen).
    wgsl_desc.code = wgpu::StringView{
        wgsl_source.data(),
        wgsl_source.size(),
    };
    wgpu::ShaderModuleDescriptor shader_desc{};
    shader_desc.nextInChain = &wgsl_desc;
    wgpu::ShaderModule shader = device_.CreateShaderModule(&shader_desc);

    wgpu::ComputePipelineDescriptor pipeline_desc{};
    pipeline_desc.compute.module = shader;
    pipeline_desc.compute.entryPoint = wgpu::StringView{entry_point, WGPU_STRLEN};
    return device_.CreateComputePipeline(&pipeline_desc);
}

void DawnKernelHarness::dispatch(const wgpu::ComputePipeline& pipeline,
                                  const std::vector<wgpu::Buffer>& bindings,
                                  uint32_t wg_x, uint32_t wg_y, uint32_t wg_z) {
    // ─── Build a single bind group covering all `bindings` ───
    std::vector<wgpu::BindGroupEntry> bg_entries;
    bg_entries.reserve(bindings.size());
    for (size_t i = 0; i < bindings.size(); ++i) {
        wgpu::BindGroupEntry e{};
        e.binding = static_cast<uint32_t>(i);
        e.buffer = bindings[i];
        e.offset = 0;
        e.size = WGPU_WHOLE_SIZE;
        bg_entries.push_back(e);
    }
    wgpu::BindGroupDescriptor bg_desc{};
    bg_desc.layout = pipeline.GetBindGroupLayout(0);
    bg_desc.entryCount = bg_entries.size();
    bg_desc.entries = bg_entries.data();
    wgpu::BindGroup bind_group = device_.CreateBindGroup(&bg_desc);

    // ─── Encode + submit + sync ───
    wgpu::CommandEncoder encoder = device_.CreateCommandEncoder();
    {
        wgpu::ComputePassEncoder pass = encoder.BeginComputePass();
        pass.SetPipeline(pipeline);
        pass.SetBindGroup(0, bind_group);
        pass.DispatchWorkgroups(wg_x, wg_y, wg_z);
        pass.End();
    }
    wgpu::CommandBuffer commands = encoder.Finish();
    queue_.Submit(1, &commands);

    // Wait for GPU completion via OnSubmittedWorkDone → WaitAny pattern.
    bool done = false;
    instance_.WaitAny(
        queue_.OnSubmittedWorkDone(
            wgpu::CallbackMode::WaitAnyOnly,
            [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView) {
                done = true;
            }),
        UINT64_MAX);
    if (!done) {
        std::cerr << "[DawnKernelHarness] dispatch WaitAny did not complete\n";
    }
}

void DawnKernelHarness::copy_to_staging(const wgpu::Buffer& src,
                                         const wgpu::Buffer& dst,
                                         size_t size) {
    wgpu::CommandEncoder encoder = device_.CreateCommandEncoder();
    encoder.CopyBufferToBuffer(src, 0, dst, 0, size);
    wgpu::CommandBuffer commands = encoder.Finish();
    queue_.Submit(1, &commands);

    // Wait so the staging buffer is valid for map-read below.
    bool done = false;
    instance_.WaitAny(
        queue_.OnSubmittedWorkDone(
            wgpu::CallbackMode::WaitAnyOnly,
            [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView) {
                done = true;
            }),
        UINT64_MAX);
    if (!done) {
        std::cerr << "[DawnKernelHarness] copy_to_staging WaitAny did not complete\n";
    }
}

std::vector<uint8_t> DawnKernelHarness::readback(const wgpu::Buffer& buf,
                                                   size_t size) {
    bool mapped = false;
    instance_.WaitAny(
        buf.MapAsync(
            wgpu::MapMode::Read, 0, size,
            wgpu::CallbackMode::WaitAnyOnly,
            [&mapped](wgpu::MapAsyncStatus status, wgpu::StringView msg) {
                if (status != wgpu::MapAsyncStatus::Success) {
                    std::cerr << "[DawnKernelHarness] MapAsync failed: " << msg << '\n';
                    return;
                }
                mapped = true;
            }),
        UINT64_MAX);
    if (!mapped) {
        return {};
    }
    const auto* p = static_cast<const uint8_t*>(buf.GetConstMappedRange(0, size));
    std::vector<uint8_t> out(p, p + size);
    buf.Unmap();
    return out;
}

}  // namespace tools
}  // namespace aether
