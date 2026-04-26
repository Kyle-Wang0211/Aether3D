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

// ═══════════════════════════════════════════════════════════════════════
// Phase 6.3a Step 4 v3 — texture / render-pipeline path
// ═══════════════════════════════════════════════════════════════════════

wgpu::Texture DawnKernelHarness::alloc_render_target(uint32_t w, uint32_t h,
                                                      wgpu::TextureFormat format) {
    wgpu::TextureDescriptor desc{};
    desc.size.width = w;
    desc.size.height = h;
    desc.size.depthOrArrayLayers = 1;
    desc.format = format;
    desc.mipLevelCount = 1;
    desc.sampleCount = 1;
    desc.dimension = wgpu::TextureDimension::e2D;
    desc.usage = wgpu::TextureUsage::RenderAttachment
               | wgpu::TextureUsage::CopySrc
               | wgpu::TextureUsage::TextureBinding;
    return device_.CreateTexture(&desc);
}

wgpu::RenderPipeline DawnKernelHarness::load_render_pipeline(
        std::string_view wgsl_source,
        const char* vs_entry,
        const char* fs_entry,
        wgpu::TextureFormat color_format,
        wgpu::PrimitiveTopology topology) {
    wgpu::ShaderSourceWGSL wgsl_desc{};
    wgsl_desc.code = wgpu::StringView{ wgsl_source.data(), wgsl_source.size() };
    wgpu::ShaderModuleDescriptor shader_desc{};
    shader_desc.nextInChain = &wgsl_desc;
    wgpu::ShaderModule shader = device_.CreateShaderModule(&shader_desc);

    // Color target: enable premultiplied alpha blending so the fragment
    // shader can output (color*α, α) and the ROP composes correctly.
    wgpu::BlendState blend{};
    blend.color.srcFactor = wgpu::BlendFactor::One;
    blend.color.dstFactor = wgpu::BlendFactor::OneMinusSrcAlpha;
    blend.color.operation = wgpu::BlendOperation::Add;
    blend.alpha.srcFactor = wgpu::BlendFactor::One;
    blend.alpha.dstFactor = wgpu::BlendFactor::OneMinusSrcAlpha;
    blend.alpha.operation = wgpu::BlendOperation::Add;

    wgpu::ColorTargetState color_target{};
    color_target.format = color_format;
    color_target.blend = &blend;
    color_target.writeMask = wgpu::ColorWriteMask::All;

    wgpu::FragmentState fragment{};
    fragment.module = shader;
    fragment.entryPoint = wgpu::StringView{ fs_entry, WGPU_STRLEN };
    fragment.targetCount = 1;
    fragment.targets = &color_target;

    wgpu::VertexState vertex{};
    vertex.module = shader;
    vertex.entryPoint = wgpu::StringView{ vs_entry, WGPU_STRLEN };
    // No vertex buffers — instanced quads pull data from storage buffers
    // via vertexID + instanceID (MetalSplatter / Spark.js convention).
    vertex.bufferCount = 0;

    wgpu::RenderPipelineDescriptor pipeline_desc{};
    pipeline_desc.vertex = vertex;
    pipeline_desc.fragment = &fragment;
    pipeline_desc.primitive.topology = topology;
    pipeline_desc.primitive.cullMode = wgpu::CullMode::None;
    pipeline_desc.primitive.frontFace = wgpu::FrontFace::CCW;
    pipeline_desc.multisample.count = 1;
    pipeline_desc.multisample.mask = 0xFFFFFFFF;

    return device_.CreateRenderPipeline(&pipeline_desc);
}

void DawnKernelHarness::dispatch_render_pass(
        const wgpu::RenderPipeline& pipeline,
        const wgpu::Texture& target,
        const std::vector<wgpu::Buffer>& bindings,
        uint32_t vertex_count,
        uint32_t instance_count) {
    // Build @group(0) bind group from `bindings`.
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

    // Color attachment: clear to transparent black, store output.
    wgpu::TextureView view = target.CreateView();
    wgpu::RenderPassColorAttachment color_attach{};
    color_attach.view = view;
    color_attach.loadOp = wgpu::LoadOp::Clear;
    color_attach.storeOp = wgpu::StoreOp::Store;
    color_attach.clearValue = {0.0, 0.0, 0.0, 0.0};

    wgpu::RenderPassDescriptor pass_desc{};
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attach;

    wgpu::CommandEncoder encoder = device_.CreateCommandEncoder();
    {
        wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&pass_desc);
        pass.SetPipeline(pipeline);
        pass.SetBindGroup(0, bind_group);
        pass.Draw(vertex_count, instance_count, /*firstVertex=*/0, /*firstInstance=*/0);
        pass.End();
    }
    wgpu::CommandBuffer commands = encoder.Finish();
    queue_.Submit(1, &commands);

    bool done = false;
    instance_.WaitAny(
        queue_.OnSubmittedWorkDone(
            wgpu::CallbackMode::WaitAnyOnly,
            [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView) {
                done = true;
            }),
        UINT64_MAX);
    if (!done) {
        std::cerr << "[DawnKernelHarness] dispatch_render_pass WaitAny did not complete\n";
    }
}

std::vector<uint8_t> DawnKernelHarness::readback_texture(
        const wgpu::Texture& tex,
        uint32_t w, uint32_t h,
        uint32_t bytes_per_pixel) {
    // WebGPU requires 256-byte row alignment for copyTextureToBuffer.
    // Pad each row, then unpad on readback so the caller gets tight bytes.
    constexpr uint32_t kAlign = 256;
    const uint32_t unpadded_bpr = w * bytes_per_pixel;
    const uint32_t padded_bpr =
        (unpadded_bpr + kAlign - 1) / kAlign * kAlign;
    const uint64_t padded_total = static_cast<uint64_t>(padded_bpr) * h;

    auto staging = alloc_staging_for_readback(padded_total);

    wgpu::CommandEncoder encoder = device_.CreateCommandEncoder();
    wgpu::TexelCopyTextureInfo src_info{};
    src_info.texture = tex;
    src_info.mipLevel = 0;
    src_info.origin = {0, 0, 0};
    src_info.aspect = wgpu::TextureAspect::All;

    wgpu::TexelCopyBufferInfo dst_info{};
    dst_info.buffer = staging;
    dst_info.layout.offset = 0;
    dst_info.layout.bytesPerRow = padded_bpr;
    dst_info.layout.rowsPerImage = h;

    wgpu::Extent3D extent{ w, h, 1 };
    encoder.CopyTextureToBuffer(&src_info, &dst_info, &extent);
    wgpu::CommandBuffer commands = encoder.Finish();
    queue_.Submit(1, &commands);

    bool done = false;
    instance_.WaitAny(
        queue_.OnSubmittedWorkDone(
            wgpu::CallbackMode::WaitAnyOnly,
            [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView) { done = true; }),
        UINT64_MAX);
    (void)done;

    auto padded_bytes = readback(staging, padded_total);

    // Unpad rows: copy unpadded_bpr bytes per row, skipping padding.
    std::vector<uint8_t> tight(static_cast<size_t>(unpadded_bpr) * h);
    for (uint32_t y = 0; y < h; ++y) {
        std::memcpy(tight.data() + y * unpadded_bpr,
                    padded_bytes.data() + y * padded_bpr,
                    unpadded_bpr);
    }
    return tight;
}

}  // namespace tools
}  // namespace aether
