// Phase 1.5 hello compute — WGSL kernel writes buffer[i] = i, readback verifies 0..15.
//
// Verifies the full compute pipeline path on Dawn:
//   - Storage buffer create
//   - Shader module from raw WGSL string
//   - Compute pipeline + auto-derived bind group layout
//   - Dispatch + queue submit
//   - CopyBufferToBuffer staging for readback
//   - MapAsync (modern future-based) + GetConstMappedRange
//
// Why this matters for the project:
// 3DGS training has 16 compute kernels. Their cross-platform port lives or
// dies on this minimal pipeline working. P1.5 is the smallest possible
// compute round-trip — if it passes, the path for the full training rewrite
// is open.

#include <webgpu/webgpu_cpp.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <ostream>

namespace {

// AdapterInfo + callback messages are wgpu::StringView (not const char*) in
// modern Dawn. Same printer as aether_dawn_hello.cpp; copy-paste rather than
// share a header — these hello binaries are intentionally self-contained so
// each one is a single-translation-unit smoke test.
std::ostream& operator<<(std::ostream& os, const wgpu::StringView& s) {
    if (s.data == nullptr) {
        return os;
    }
    if (s.length == WGPU_STRLEN) {
        return os << s.data;
    }
    return os.write(s.data, static_cast<std::streamsize>(s.length));
}

constexpr uint32_t kCount = 16;
constexpr uint64_t kBufferBytes = static_cast<uint64_t>(kCount) * sizeof(uint32_t);

// WGSL: each thread writes its global invocation id to the buffer.
// Dispatch 1 workgroup × @workgroup_size(16) → 16 threads → 16 writes.
constexpr const char* kShaderWgsl = R"(
@group(0) @binding(0) var<storage, read_write> data: array<u32>;

@compute @workgroup_size(16)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    data[gid.x] = gid.x;
}
)";

}  // namespace

int main(int /*argc*/, char* /*argv*/[]) {
    static constexpr auto kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
    wgpu::InstanceDescriptor instance_desc{
        .requiredFeatureCount = 1,
        .requiredFeatures = &kTimedWaitAny,
    };
    wgpu::Instance instance = wgpu::CreateInstance(&instance_desc);
    if (instance == nullptr) {
        std::cerr << "wgpu::CreateInstance failed\n";
        return EXIT_FAILURE;
    }

    // ---------------------------------------------------------------- adapter
    wgpu::Adapter adapter;
    {
        wgpu::RequestAdapterOptions options{};
        instance.WaitAny(
            instance.RequestAdapter(
                &options, wgpu::CallbackMode::WaitAnyOnly,
                [&adapter](wgpu::RequestAdapterStatus status,
                           wgpu::Adapter received,
                           wgpu::StringView message) {
                    if (status != wgpu::RequestAdapterStatus::Success) {
                        std::cerr << "RequestAdapter failed: " << message << '\n';
                        return;
                    }
                    adapter = std::move(received);
                }),
            UINT64_MAX);
        if (adapter == nullptr) {
            std::cerr << "Adapter is null\n";
            return EXIT_FAILURE;
        }
    }

    // ----------------------------------------------------------------- device
    wgpu::Device device;
    {
        wgpu::DeviceDescriptor device_desc{};
        instance.WaitAny(
            adapter.RequestDevice(
                &device_desc, wgpu::CallbackMode::WaitAnyOnly,
                [&device](wgpu::RequestDeviceStatus status,
                          wgpu::Device received,
                          wgpu::StringView message) {
                    if (status != wgpu::RequestDeviceStatus::Success) {
                        std::cerr << "RequestDevice failed: " << message << '\n';
                        return;
                    }
                    device = std::move(received);
                }),
            UINT64_MAX);
        if (device == nullptr) {
            std::cerr << "Device is null\n";
            return EXIT_FAILURE;
        }
    }

    wgpu::Queue queue = device.GetQueue();

    // ---------------------------------------------------------------- buffers
    wgpu::BufferDescriptor storage_desc{
        .usage = wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc,
        .size = kBufferBytes,
    };
    wgpu::Buffer storage_buffer = device.CreateBuffer(&storage_desc);

    wgpu::BufferDescriptor readback_desc{
        .usage = wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst,
        .size = kBufferBytes,
    };
    wgpu::Buffer readback_buffer = device.CreateBuffer(&readback_desc);

    // ---------------------------------------------------------- shader module
    wgpu::ShaderSourceWGSL wgsl_source{};
    wgsl_source.code = kShaderWgsl;
    wgpu::ShaderModuleDescriptor shader_desc{};
    shader_desc.nextInChain = &wgsl_source;
    wgpu::ShaderModule shader = device.CreateShaderModule(&shader_desc);

    // -------------------------------------------------- pipeline + bind group
    wgpu::ComputePipelineDescriptor pipeline_desc{};
    pipeline_desc.compute.module = shader;
    pipeline_desc.compute.entryPoint = "main";
    wgpu::ComputePipeline pipeline = device.CreateComputePipeline(&pipeline_desc);

    wgpu::BindGroupEntry bg_entry{
        .binding = 0,
        .buffer = storage_buffer,
        .offset = 0,
        .size = kBufferBytes,
    };
    wgpu::BindGroupDescriptor bg_desc{
        .layout = pipeline.GetBindGroupLayout(0),
        .entryCount = 1,
        .entries = &bg_entry,
    };
    wgpu::BindGroup bind_group = device.CreateBindGroup(&bg_desc);

    // ------------------------------------------------------- encode + submit
    wgpu::CommandEncoder encoder = device.CreateCommandEncoder();
    {
        wgpu::ComputePassEncoder pass = encoder.BeginComputePass();
        pass.SetPipeline(pipeline);
        pass.SetBindGroup(0, bind_group);
        pass.DispatchWorkgroups(1);  // 1 × 16 = 16 threads = 16 elements
        pass.End();
    }
    encoder.CopyBufferToBuffer(storage_buffer, 0, readback_buffer, 0, kBufferBytes);
    wgpu::CommandBuffer commands = encoder.Finish();
    queue.Submit(1, &commands);

    // -------------------------------------------------------- readback (map)
    bool mapped = false;
    instance.WaitAny(
        readback_buffer.MapAsync(
            wgpu::MapMode::Read, 0, kBufferBytes,
            wgpu::CallbackMode::WaitAnyOnly,
            [&mapped](wgpu::MapAsyncStatus status, wgpu::StringView message) {
                if (status != wgpu::MapAsyncStatus::Success) {
                    std::cerr << "MapAsync failed: " << message << '\n';
                    return;
                }
                mapped = true;
            }),
        UINT64_MAX);
    if (!mapped) {
        std::cerr << "Buffer never mapped\n";
        return EXIT_FAILURE;
    }

    const auto* data = static_cast<const uint32_t*>(
        readback_buffer.GetConstMappedRange(0, kBufferBytes));
    if (data == nullptr) {
        std::cerr << "GetConstMappedRange returned null\n";
        return EXIT_FAILURE;
    }

    // ---------------------------------------------------------------- verify
    std::cout << "=== aether_dawn_hello_compute (P1.5) ===\n";
    std::cout << "Expected: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15\n";
    std::cout << "Got:     ";
    bool ok = true;
    for (uint32_t i = 0; i < kCount; ++i) {
        std::cout << ' ' << data[i];
        if (data[i] != i) {
            ok = false;
        }
    }
    std::cout << '\n';
    readback_buffer.Unmap();

    if (!ok) {
        std::cerr << "FAIL: data mismatch\n";
        return EXIT_FAILURE;
    }
    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
