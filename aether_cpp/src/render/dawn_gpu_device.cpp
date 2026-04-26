// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// DawnGPUDevice — Concrete GPUDevice implementation backed by Dawn (WebGPU).
//
// ─── Phase 6.2 status: SKELETON (this commit) ─────────────────────────
// This file currently provides:
//   - Class skeleton with all virtual overrides as compiling stubs
//   - Factory functions that build but return nullptr (Dawn not yet
//     initialized)
//   - All GPUDevice virtual methods present so the strict-flag build
//     of aether3d_core succeeds with this file in the source list
//
// Subsequent commits fill in:
//   - 6.2.F: Buffer impl (create/destroy/map/unmap/update)
//   - 6.2.G: Texture impl (incl IOSurface bridge for Flutter zero-copy)
//   - 6.2.H: Shader impl (load_shader → create from WGSL string)
//   - 6.2.I: Render pipeline impl
//   - 6.2.J: Compute pipeline impl
//   - 6.2.K: DawnCommandBuffer + Dawn{Compute,Render}Encoder
//
// Build gate: AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn (CMake
// conditional). If Dawn isn't built (e.g. headless host without GPU),
// this TU is excluded entirely.

#if defined(AETHER_ENABLE_DAWN)

#include "aether/render/dawn_gpu_device.h"

#include <webgpu/webgpu.h>  // C API — strict-flags compatible (vs webgpu_cpp.h
                            // which uses RAII wrappers that need exceptions/RTTI)

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <unordered_map>

namespace aether {
namespace render {

namespace {

// One-time stub log so devs notice they're hitting unimplemented code paths
// during the multi-commit Phase 6.2 buildout. Logs once per call site
// (atomic-fence-protected boolean), not per call.
inline void stub_log_once(std::atomic<bool>& fired, const char* who) {
    bool expected = false;
    if (fired.compare_exchange_strong(expected, true)) {
        // stderr is fine for headless tests; iOS production code will replace
        // these stubs entirely before any user-visible call site is enabled.
        std::fprintf(stderr,
            "[Aether3D][Dawn] STUB: %s — Phase 6.2 skeleton, real impl "
            "lands in subsequent commit\n", who);
    }
}

// ─── Resource value types (mirror Metal's id<MTLBuffer> etc. as raw C handles)

struct DawnBuffer {
    WGPUBuffer handle{nullptr};
    std::size_t size_bytes{0};
};

struct DawnTexture {
    WGPUTexture handle{nullptr};
    std::uint32_t width{0};
    std::uint32_t height{0};
};

struct DawnShader {
    WGPUShaderModule module{nullptr};
    char entry_point[64]{};  // copied from name arg in load_shader
    GPUShaderStage stage{GPUShaderStage::kCompute};
};

struct DawnRenderPipeline {
    WGPURenderPipeline handle{nullptr};
};

struct DawnComputePipeline {
    WGPUComputePipeline handle{nullptr};
};

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// DawnGPUDevice
// ═══════════════════════════════════════════════════════════════════════

class DawnGPUDevice final : public GPUDevice {
public:
    DawnGPUDevice() noexcept = default;

    ~DawnGPUDevice() override {
        // Phase 6.2.K will release WGPU* handles in the maps. Skeleton:
        // maps are empty so destruction is trivial.
    }

    // ─── Device Info ───

    GraphicsBackend backend() const noexcept override {
        return GraphicsBackend::kDawn;
    }

    GPUCaps capabilities() const noexcept override {
        // Skeleton: return reasonable defaults. Phase 6.2.E build verify
        // doesn't exercise these; Phase 6.2.K wires them via
        // wgpuDeviceGetLimits.
        GPUCaps caps{};
        caps.backend = GraphicsBackend::kDawn;
        caps.max_buffer_size = 256u * 1024u * 1024u;  // 256 MB safe default
        caps.max_texture_size = 8192u;                // WebGPU minimum guarantee
        caps.max_compute_workgroup_size = 256u;       // WebGPU minimum guarantee
        caps.max_threadgroup_memory = 16384u;         // WebGPU minimum guarantee
        caps.supports_compute = true;
        caps.supports_indirect_draw = true;
        caps.supports_shared_memory = true;
        caps.supports_half_precision = false;         // f16 is optional in WebGPU
        caps.supports_simd_group = false;             // subgroups optional + experimental
        caps.simd_width = 0;
        return caps;
    }

    GPUMemoryStats memory_stats() const noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        GPUMemoryStats stats{};
        stats.allocated_bytes = allocated_bytes_;
        stats.peak_bytes = peak_bytes_;
        stats.buffer_count = static_cast<std::uint32_t>(buffers_.size());
        stats.texture_count = static_cast<std::uint32_t>(textures_.size());
        return stats;
    }

    // ─── Buffer Management (Phase 6.2.F) ───

    GPUBufferHandle create_buffer(const GPUBufferDesc& desc) noexcept override {
        (void)desc;
        stub_log_once(stub_create_buffer_, "DawnGPUDevice::create_buffer");
        return GPUBufferHandle{0};
    }

    void destroy_buffer(GPUBufferHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_destroy_buffer_, "DawnGPUDevice::destroy_buffer");
    }

    void* map_buffer(GPUBufferHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_map_buffer_, "DawnGPUDevice::map_buffer");
        return nullptr;
    }

    void unmap_buffer(GPUBufferHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_unmap_buffer_, "DawnGPUDevice::unmap_buffer");
    }

    void update_buffer(GPUBufferHandle handle, const void* data,
                       std::size_t offset, std::size_t size) noexcept override {
        (void)handle;
        (void)data;
        (void)offset;
        (void)size;
        stub_log_once(stub_update_buffer_, "DawnGPUDevice::update_buffer");
    }

    // ─── Texture Management (Phase 6.2.G) ───

    GPUTextureHandle create_texture(const GPUTextureDesc& desc) noexcept override {
        (void)desc;
        stub_log_once(stub_create_texture_, "DawnGPUDevice::create_texture");
        return GPUTextureHandle{0};
    }

    void destroy_texture(GPUTextureHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_destroy_texture_, "DawnGPUDevice::destroy_texture");
    }

    void update_texture(GPUTextureHandle handle, const void* data,
                        std::uint32_t width, std::uint32_t height,
                        std::uint32_t bytes_per_row) noexcept override {
        (void)handle;
        (void)data;
        (void)width;
        (void)height;
        (void)bytes_per_row;
        stub_log_once(stub_update_texture_, "DawnGPUDevice::update_texture");
    }

    // ─── Shader Management (Phase 6.2.H) ───
    //
    // NB: load_shader's name parameter semantics differ from Metal. On
    // Metal it's a function name in the embedded metallib. On Dawn it's
    // the WGSL entry-point function name within a pre-loaded WGSL module
    // (the module loading happens earlier in 6.4 via a separate FFI call
    // since WGSL is text-source rather than precompiled). Phase 6.2.H
    // resolves this — likely by changing load_shader to look up a
    // pre-registered WGSL module by `name` and bind to the entry-point.

    GPUShaderHandle load_shader(const char* name,
                                GPUShaderStage stage) noexcept override {
        (void)name;
        (void)stage;
        stub_log_once(stub_load_shader_, "DawnGPUDevice::load_shader");
        return GPUShaderHandle{0};
    }

    void destroy_shader(GPUShaderHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_destroy_shader_, "DawnGPUDevice::destroy_shader");
    }

    // ─── Pipeline Management (Phase 6.2.I + 6.2.J) ───

    GPURenderPipelineHandle create_render_pipeline(
        GPUShaderHandle vertex_shader,
        GPUShaderHandle fragment_shader,
        const GPURenderTargetDesc& target_desc) noexcept override {
        (void)vertex_shader;
        (void)fragment_shader;
        (void)target_desc;
        stub_log_once(stub_create_render_pipeline_,
                      "DawnGPUDevice::create_render_pipeline");
        return GPURenderPipelineHandle{0};
    }

    void destroy_render_pipeline(GPURenderPipelineHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_destroy_render_pipeline_,
                      "DawnGPUDevice::destroy_render_pipeline");
    }

    GPUComputePipelineHandle create_compute_pipeline(
        GPUShaderHandle compute_shader) noexcept override {
        (void)compute_shader;
        stub_log_once(stub_create_compute_pipeline_,
                      "DawnGPUDevice::create_compute_pipeline");
        return GPUComputePipelineHandle{0};
    }

    void destroy_compute_pipeline(GPUComputePipelineHandle handle) noexcept override {
        (void)handle;
        stub_log_once(stub_destroy_compute_pipeline_,
                      "DawnGPUDevice::destroy_compute_pipeline");
    }

    // ─── Command Buffer (Phase 6.2.K) ───

    std::unique_ptr<GPUCommandBuffer> create_command_buffer() noexcept override {
        stub_log_once(stub_create_command_buffer_,
                      "DawnGPUDevice::create_command_buffer");
        return nullptr;
    }

    // ─── Synchronization ───

    void wait_idle() noexcept override {
        // Phase 6.2.K: wgpuQueueOnSubmittedWorkDone + spin until callback fires.
        // Skeleton no-op — no work is ever submitted from stubs anyway.
    }

    // ─── Dawn-specific accessors (used by future DawnCommandBuffer / Encoder) ───

    WGPUDevice wgpu_device() const noexcept { return wgpu_device_; }
    WGPUQueue wgpu_queue() const noexcept { return wgpu_queue_; }

private:
    // Native Dawn handles. Phase 6.2.F factory wires these via
    // wgpuCreateInstance + wgpuInstanceRequestAdapter + wgpuAdapterRequestDevice;
    // skeleton leaves them null. [[maybe_unused]] silences strict-flag
    // -Werror,-Wunused-private-field while skeleton stubs don't reference
    // them; attribute drops away naturally when 6.2.F populates them.
    [[maybe_unused]] WGPUInstance wgpu_instance_{nullptr};
    [[maybe_unused]] WGPUAdapter wgpu_adapter_{nullptr};
    WGPUDevice wgpu_device_{nullptr};
    WGPUQueue wgpu_queue_{nullptr};

    mutable std::mutex mutex_;
    [[maybe_unused]] std::uint32_t next_id_{0};

    // Resource maps (handle.id → Dawn handle wrapper). Empty in skeleton;
    // populated by Phase 6.2.F-K.
    std::unordered_map<std::uint32_t, DawnBuffer> buffers_;
    std::unordered_map<std::uint32_t, DawnTexture> textures_;
    std::unordered_map<std::uint32_t, DawnShader> shaders_;
    std::unordered_map<std::uint32_t, DawnRenderPipeline> render_pipelines_;
    std::unordered_map<std::uint32_t, DawnComputePipeline> compute_pipelines_;

    // Memory tracking (filled in 6.2.F)
    std::size_t allocated_bytes_{0};
    std::size_t peak_bytes_{0};

    // Stub-fired flags so each unimplemented method warns at most once.
    // These add ~120 bytes to the device — acceptable for dev-time signal,
    // and they go away when Phase 6.2.F-K replaces the stubs entirely.
    std::atomic<bool> stub_create_buffer_{false};
    std::atomic<bool> stub_destroy_buffer_{false};
    std::atomic<bool> stub_map_buffer_{false};
    std::atomic<bool> stub_unmap_buffer_{false};
    std::atomic<bool> stub_update_buffer_{false};
    std::atomic<bool> stub_create_texture_{false};
    std::atomic<bool> stub_destroy_texture_{false};
    std::atomic<bool> stub_update_texture_{false};
    std::atomic<bool> stub_load_shader_{false};
    std::atomic<bool> stub_destroy_shader_{false};
    std::atomic<bool> stub_create_render_pipeline_{false};
    std::atomic<bool> stub_destroy_render_pipeline_{false};
    std::atomic<bool> stub_create_compute_pipeline_{false};
    std::atomic<bool> stub_destroy_compute_pipeline_{false};
    std::atomic<bool> stub_create_command_buffer_{false};
};

// ═══════════════════════════════════════════════════════════════════════
// Factory functions
// ═══════════════════════════════════════════════════════════════════════

std::unique_ptr<GPUDevice> create_dawn_gpu_device(bool request_high_performance) noexcept {
    (void)request_high_performance;
    // Phase 6.2 skeleton: returns a DawnGPUDevice with no underlying Dawn
    // resources allocated. Calls into virtual methods produce stub_log_once
    // warnings. Phase 6.2.F adds the real wgpuCreateInstance +
    // RequestAdapter + RequestDevice chain so this returns a working
    // device. Skeleton lets dependent callers compile + link; the stubs
    // signal at first runtime call.
    return std::make_unique<DawnGPUDevice>();
}

std::unique_ptr<GPUCommandBuffer> create_dawn_command_buffer(GPUDevice& device) noexcept {
    // Type-tag dispatch (project compiles with -fno-rtti). Mirror of
    // create_metal_command_buffer's pattern.
    if (device.backend() != GraphicsBackend::kDawn) return nullptr;
    // Skeleton: command-buffer creation is Phase 6.2.K. Until then, return
    // nullptr so accidental callers get a clean fail-stop, not a UB crash.
    return nullptr;
}

}  // namespace render
}  // namespace aether

#endif  // AETHER_ENABLE_DAWN
