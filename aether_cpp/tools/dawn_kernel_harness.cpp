// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "dawn_kernel_harness.h"

#include <webgpu/webgpu_cpp.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <ostream>
#include <string>
#include <sys/stat.h>
#include <vector>

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

// ─── Disk-backed Dawn persistent pipeline cache ─────────────────────────────
// DawnCacheDeviceDescriptor's load/store callbacks are plain C function
// pointers + a void* userdata. We store the cache directory + a hit counter in
// this struct and pass it as userdata. Each cache entry is one file named by
// the hex of Dawn's (binary) cache key, written under cache_dir. This persists
// the compiled MSL/pipeline blobs across launches so the 11 CreateComputePipeline
// Tint→Metal compiles (the ~31.7s A16 first-launch cost) are skipped on a warm
// start. NOTE (the coordinator's caveat, verified by MEASURING init_ms): on
// Metal, Dawn caches the Tint-generated MSL; whether the final MTLComputePipeline
// PSO compile is also skipped depends on the Dawn/Metal version's use of
// MTLBinaryArchive. The real 2nd-launch init_ms is the only truth — we log it.
struct DiskPipelineCache {
    std::string dir;
    std::atomic<long> load_hits{0};
    std::atomic<long> store_count{0};
};

std::string KeyToHex(const void* key, size_t key_size) {
    static const char* hx = "0123456789abcdef";
    const auto* p = static_cast<const unsigned char*>(key);
    std::string s;
    s.reserve(key_size * 2);
    for (size_t i = 0; i < key_size; ++i) {
        s.push_back(hx[(p[i] >> 4) & 0xF]);
        s.push_back(hx[p[i] & 0xF]);
    }
    // Dawn keys can be long; cap the filename to a safe length by keeping the
    // full hex but it is bounded by the key size (cache keys are short hashes
    // in practice). If a key were pathologically long, the FS would reject it
    // and the store would silently no-op (acceptable: just a cache miss).
    return s;
}

// loadDataFunction: return the FULL blob size for |key|. If |value| is non-null
// and |valueSize| >= the blob size, copy the blob into |value|. Dawn first calls
// with value=nullptr to size, then again with a buffer.
size_t CacheLoad(const void* key, size_t keySize, void* value, size_t valueSize,
                 void* userdata) {
    auto* c = static_cast<DiskPipelineCache*>(userdata);
    if (!c || keySize == 0) return 0;
    const std::string path = c->dir + "/" + KeyToHex(key, keySize) + ".bin";
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return 0;
    const std::streamsize sz = f.tellg();
    if (sz <= 0) return 0;
    if (value && valueSize >= static_cast<size_t>(sz)) {
        f.seekg(0);
        f.read(static_cast<char*>(value), sz);
        c->load_hits.fetch_add(1);
    }
    return static_cast<size_t>(sz);
}

void CacheStore(const void* key, size_t keySize, const void* value,
                size_t valueSize, void* userdata) {
    auto* c = static_cast<DiskPipelineCache*>(userdata);
    if (!c || keySize == 0 || !value || valueSize == 0) return;
    const std::string path = c->dir + "/" + KeyToHex(key, keySize) + ".bin";
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) return;
    f.write(static_cast<const char*>(value), valueSize);
    if (f) c->store_count.fetch_add(1);
}

}  // namespace

DawnKernelHarness::DawnKernelHarness() = default;

DawnKernelHarness::~DawnKernelHarness() {
    // wgpu:: types are RAII; destruct in reverse acquisition order is
    // automatic via member-init-reversed teardown.
}

bool DawnKernelHarness::init() {
    return init_with_cache(nullptr, nullptr, nullptr);
}

bool DawnKernelHarness::init_with_cache(const char* cache_dir,
                                        const char* isolation_key,
                                        bool* out_cache_warm) {
    if (out_cache_warm) *out_cache_warm = false;
    // ─── Disk pipeline cache (optional). Created here, owned for the lifetime
    //     of the process (Dawn requires the cache to outlive the device). A
    //     leaked static is fine for a harness; the OS reclaims on exit. ───
    static DiskPipelineCache* g_cache = nullptr;
    if (cache_dir && cache_dir[0]) {
        ::mkdir(cache_dir, 0755);  // no-op if it already exists
        g_cache = new DiskPipelineCache();
        g_cache->dir = cache_dir;
    }
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

        // Phase 6.3a Step 5b: Brush prefix_sum_* kernels declare
        // @workgroup_size(512). WebGPU's default cap is 256; bump
        // maxComputeInvocationsPerWorkgroup + WorkgroupSizeX so the
        // pipelines can be created. Modern desktop/mobile GPUs all
        // support 1024 (verified at runtime: this adapter reports
        // maxComputeWorkgroupSizeX=1024).
        wgpu::Limits required_limits{};
        required_limits.maxComputeInvocationsPerWorkgroup = 512;
        required_limits.maxComputeWorkgroupSizeX = 512;
        // Phase 6.3a Step 6: Brush rasterize_backwards binds 10 storage
        // buffers (uniforms + 6 read inputs + 3 atomic-write outputs).
        // WebGPU's default cap is 8; bump to 10 so the pipeline can be
        // created. Apple Silicon supports up to 64; this 10 is well below
        // any modern GPU's max — verified by adapter introspection.
        required_limits.maxStorageBuffersPerShaderStage = 10;
        // S1 GPU DSP-SIFT detect parity (sift_dog_extrema_test.wgsl): one
        // octave's gss levels are bound as a single storage buffer. For the
        // 4224x2376 octave 0 with 6 gss levels that is ~240 MB, above WebGPU's
        // default maxStorageBufferBindingSize of 128 MB. The adapter reports
        // support up to 4 GB (verified at runtime via the Dawn validation
        // message); request 1 GB so the largest octave binding is valid. This
        // limit is PERMISSIVE-only — it cannot change any existing kernel's
        // output, it only allows larger single bindings (same additive pattern
        // as the maxComputeInvocations / maxStorageBuffersPerShaderStage bumps
        // above). Falls back loudly (device request fails) on an adapter that
        // genuinely can't support it.
        required_limits.maxStorageBufferBindingSize = 2048ull * 1024ull * 1024ull;
        // maxBufferSize is a separate cap (default 256 MB). The first_octave=-1
        // parity-baseline geometry upsamples to 8448x4752, so one octave's gss
        // levels are ~963 MB; bump to 2 GB so the baseline path is also
        // validateable. Production uses first_octave=0 (PLAN 06-25), well under
        // even the default. Same permissive-only rationale as above.
        required_limits.maxBufferSize = 2048ull * 1024ull * 1024ull;
        // iOS-Metal safety (GPU DSP-SIFT on-device): Apple A-series Metal caps
        // maxBufferLength at ~half device RAM, so a 6 GB A16 reports a maximum
        // BELOW the 2 GB request above and RequestDevice would FAIL. The
        // production path is first_octave=0, whose largest single octave-0
        // binding (4224x2376, 6 gss levels) is ~240 MB — comfortably under any
        // A-series limit. Clamp the two buffer-size limits to what the adapter
        // actually reports so the device request succeeds on-device while still
        // exceeding the real 240 MB need. (Desktop adapters report >= 2 GB so
        // this is a no-op there.)
        {
            wgpu::Limits adapter_limits{};
            if (adapter_.GetLimits(&adapter_limits) == wgpu::Status::Success) {
                if (adapter_limits.maxStorageBufferBindingSize <
                    required_limits.maxStorageBufferBindingSize) {
                    required_limits.maxStorageBufferBindingSize =
                        adapter_limits.maxStorageBufferBindingSize;
                }
                if (adapter_limits.maxBufferSize < required_limits.maxBufferSize) {
                    required_limits.maxBufferSize = adapter_limits.maxBufferSize;
                }
            }
        }
        device_desc.requiredLimits = &required_limits;

        // Phase 6.3a Step 6: Brush rasterize_backwards.wgsl uses
        // subgroupAdd / subgroupAny / subgroup_invocation_id. WGSL
        // requires the 'subgroups' extension to be enabled, which on
        // the API side maps to FeatureName::Subgroups. Most modern
        // adapters (Apple Silicon, recent Adreno/Mali, all desktop)
        // support it; if a future adapter doesn't, the device request
        // will fail loudly here rather than at first compile of a
        // training kernel.
        static constexpr wgpu::FeatureName required_features[] = {
            wgpu::FeatureName::Subgroups,
        };
        device_desc.requiredFeatureCount = 1;
        device_desc.requiredFeatures = required_features;

        // ─── Chain the disk-backed persistent pipeline cache onto the device
        //     descriptor (DawnCacheDeviceDescriptor). isolationKey is a stable
        //     version string so the cache survives across launches; bump it to
        //     invalidate when shaders change. The load/store callbacks read/
        //     write the per-key blob files under cache_dir. Must outlive the
        //     device — g_cache is a leaked static; the descriptor lives until
        //     RequestDevice returns (Dawn copies what it needs). ───
        wgpu::DawnCacheDeviceDescriptor cache_desc{};
        std::string iso = (isolation_key && isolation_key[0]) ? isolation_key
                                                              : "gpusift-v1";
        if (g_cache) {
            cache_desc.isolationKey =
                wgpu::StringView(iso.c_str(), iso.size());
            cache_desc.loadDataFunction = CacheLoad;
            cache_desc.storeDataFunction = CacheStore;
            cache_desc.functionUserdata = g_cache;
            // Prepend to the device descriptor's chain.
            cache_desc.nextInChain = device_desc.nextInChain;
            device_desc.nextInChain = &cache_desc;
        }
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

    // Report cache warmth: the device + pipeline compiles happen lazily on the
    // first CreateComputePipeline (in GpuSiftExtractor::init), so the load
    // callbacks may fire AFTER this returns. We expose g_cache to the caller via
    // the harness so it can read the final hit count after the pipelines build.
    cache_for_report_ = g_cache;
    if (out_cache_warm && g_cache) {
        // A warm start is one where blob files already exist on disk. Count
        // them now (before the compiles run) so the flag reflects the PRIOR
        // launch's stores, independent of when Dawn calls LoadData.
        // (The precise load-hit count is logged separately after build.)
        *out_cache_warm = false;  // set by the caller via cache_load_hits()
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
    // resize-construct + index assignment (vs reserve + push_back): one
    // less moving part, and .data() points at fully-initialized memory
    // immediately, no risk of stale reads if a future change adds work
    // between construction and CreateBindGroup.
    std::vector<wgpu::BindGroupEntry> bg_entries(bindings.size());
    for (size_t i = 0; i < bindings.size(); ++i) {
        bg_entries[i].binding = static_cast<uint32_t>(i);
        bg_entries[i].buffer = bindings[i];
        bg_entries[i].offset = 0;
        bg_entries[i].size = WGPU_WHOLE_SIZE;
    }
    wgpu::BindGroupDescriptor bg_desc{};
    bg_desc.layout = pipeline.GetBindGroupLayout(0);
    bg_desc.entryCount = static_cast<uint32_t>(bg_entries.size());
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
    // Build @group(0) bind group from `bindings`. Same resize-not-push_back
    // discipline as dispatch() — see comment there.
    std::vector<wgpu::BindGroupEntry> bg_entries(bindings.size());
    for (size_t i = 0; i < bindings.size(); ++i) {
        bg_entries[i].binding = static_cast<uint32_t>(i);
        bg_entries[i].buffer = bindings[i];
        bg_entries[i].offset = 0;
        bg_entries[i].size = WGPU_WHOLE_SIZE;
    }
    wgpu::BindGroupDescriptor bg_desc{};
    bg_desc.layout = pipeline.GetBindGroupLayout(0);
    bg_desc.entryCount = static_cast<uint32_t>(bg_entries.size());
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
    if (!done) {
        // Match the diagnostic style used by dispatch / copy_to_staging /
        // dispatch_render_pass — silent timeout would let a downstream
        // readback() return zero-filled bytes that look like a successful
        // (but wrong) test result. The harness's P1 design rule is
        // "silent = catastrophe"; this site was the last violation.
        std::cerr << "[DawnKernelHarness] readback_texture WaitAny did not complete\n";
    }

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

long DawnKernelHarness::cache_load_hits() const {
    auto* c = static_cast<DiskPipelineCache*>(cache_for_report_);
    return c ? c->load_hits.load() : 0;
}

long DawnKernelHarness::cache_store_count() const {
    auto* c = static_cast<DiskPipelineCache*>(cache_for_report_);
    return c ? c->store_count.load() : 0;
}

}  // namespace tools
}  // namespace aether
