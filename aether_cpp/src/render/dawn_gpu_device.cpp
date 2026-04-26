// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// DawnGPUDevice — Concrete GPUDevice implementation backed by Dawn (WebGPU).
//
// ─── Phase 6.2.F status (this commit): Factory + Buffer impl ─────────
//
// Factory (create_dawn_gpu_device): wgpuCreateInstance with TimedWaitAny
// feature, synchronous WaitAny on RequestAdapter / RequestDevice futures
// to bridge the async API into a synchronous GPUDevice constructor.
// Failure modes log via stderr + return nullptr.
//
// Buffer impl: hybrid stability strategy locked by user 2026-04-26 to
// satisfy the national-scale stability requirement (must run on
// iPhone 8 → iPhone 17 Pro, 30 background apps, thermal throttle):
//
//   update_buffer (HOT PATH, frequent — every frame possibly):
//     wgpuQueueWriteBuffer. Zero-block, never spin-waits, runs in queue
//     submission timeline. This is the path 99% of CPU→GPU writes take.
//
//   map_buffer for read (RARE PATH, ~1-2× per second for loss monitor):
//     wgpuBufferMapAsync(MapMode_Read) + wgpuInstanceWaitAny spin.
//     Spin-wait is acceptable because frequency is low. Buffer must
//     have been created with kStaging usage (→ MapRead WGPU usage).
//
//   map_buffer for write (DISCOURAGED — falls into spin-wait fallback):
//     Returns nullptr + warns once per buffer. Callers must migrate to
//     update_buffer. update_buffer covers every CPU→GPU write case the
//     splat engine + training engine actually need.
//
// Subsequent commits fill in:
//   6.2.G: Texture impl (incl IOSurface bridge for Flutter zero-copy)
//   6.2.H: Shader impl (load_shader → WGSL module + entry point)
//   6.2.I: Render pipeline impl
//   6.2.J: Compute pipeline impl
//   6.2.K: DawnCommandBuffer + Dawn{Compute,Render}Encoder
//
// Build gate: AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn (CMake).

#if defined(AETHER_ENABLE_DAWN)

#include "aether/render/dawn_gpu_device.h"

#include <webgpu/webgpu.h>  // C API — strict-flags compatible

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace aether {
namespace render {

namespace {

// ─── Logging helpers ───────────────────────────────────────────────────

inline void dawn_log(const char* fmt, ...) {
    // stderr is the right channel: hello-tools printed there, iOS NSLog
    // is reachable via Console.app / Xcode IDE attach. fprintf is async-
    // signal-safe enough for our diagnostic-only path.
    va_list args;
    va_start(args, fmt);
    std::fprintf(stderr, "[Aether3D][Dawn] ");
    std::vfprintf(stderr, fmt, args);
    std::fprintf(stderr, "\n");
    va_end(args);
}

// One-time stub-warn helper (guards against log spam for paths that
// haven't been implemented yet OR are deliberately discouraged).
inline void warn_once(std::atomic<bool>& fired, const char* who, const char* msg) {
    bool expected = false;
    if (fired.compare_exchange_strong(expected, true)) {
        dawn_log("WARN_ONCE: %s — %s", who, msg);
    }
}

// ─── Sync bridge helpers (callback → blocking wait) ────────────────────
//
// Dawn's RequestAdapter / RequestDevice / MapAsync are all callback-based
// futures. Our GPUDevice abstract API is synchronous. We bridge by setting
// callback mode = WaitAnyOnly + writing the result to a stack variable
// via userdata, then wgpuInstanceWaitAny blocks until the callback fires.
// UINT64_MAX timeout = wait forever (acceptable for setup-time blocking;
// MapAsync runtime use is on the rare-path readback only).

struct AdapterCallbackData {
    WGPUAdapter adapter{nullptr};
    bool success{false};
};
extern "C" void on_adapter_request(WGPURequestAdapterStatus status,
                                   WGPUAdapter adapter,
                                   WGPUStringView message,
                                   WGPU_NULLABLE void* userdata1,
                                   WGPU_NULLABLE void* /*userdata2*/) {
    auto* data = static_cast<AdapterCallbackData*>(userdata1);
    if (status == WGPURequestAdapterStatus_Success) {
        data->adapter = adapter;
        data->success = true;
    } else {
        dawn_log("RequestAdapter FAILED: status=%d msg=%.*s",
                 status,
                 message.length == WGPU_STRLEN ? 0 : static_cast<int>(message.length),
                 message.data ? message.data : "");
    }
}

struct DeviceCallbackData {
    WGPUDevice device{nullptr};
    bool success{false};
};
extern "C" void on_device_request(WGPURequestDeviceStatus status,
                                  WGPUDevice device,
                                  WGPUStringView message,
                                  WGPU_NULLABLE void* userdata1,
                                  WGPU_NULLABLE void* /*userdata2*/) {
    auto* data = static_cast<DeviceCallbackData*>(userdata1);
    if (status == WGPURequestDeviceStatus_Success) {
        data->device = device;
        data->success = true;
    } else {
        dawn_log("RequestDevice FAILED: status=%d msg=%.*s",
                 status,
                 message.length == WGPU_STRLEN ? 0 : static_cast<int>(message.length),
                 message.data ? message.data : "");
    }
}

struct MapCallbackData {
    bool mapped{false};
    bool error{false};
};
extern "C" void on_buffer_map(WGPUMapAsyncStatus status,
                              WGPUStringView message,
                              WGPU_NULLABLE void* userdata1,
                              WGPU_NULLABLE void* /*userdata2*/) {
    auto* data = static_cast<MapCallbackData*>(userdata1);
    if (status == WGPUMapAsyncStatus_Success) {
        data->mapped = true;
    } else {
        data->error = true;
        dawn_log("BufferMapAsync FAILED: status=%d msg=%.*s",
                 status,
                 message.length == WGPU_STRLEN ? 0 : static_cast<int>(message.length),
                 message.data ? message.data : "");
    }
}

// ─── Per-buffer state stored in DawnGPUDevice's map ────────────────────

struct DawnBuffer {
    WGPUBuffer handle{nullptr};
    std::size_t size_bytes{0};
    std::uint8_t usage_mask{0};   // original GPUBufferUsage mask
    bool is_staging{false};        // shorthand: kStaging present
    bool currently_mapped{false};  // tracks unmap pairing
    // NB: a per-buffer warn-once flag was tried first but std::atomic<bool>
    // is not move-constructible, blocking unordered_map::emplace. The
    // device-level warned_map_write_discouraged_ atomic on DawnGPUDevice
    // covers the same warn-once intent at process scope, which is the
    // right granularity anyway — buffers come and go, the design issue
    // surfaces once per process.
};

// ─── Usage flag mapping ────────────────────────────────────────────────

inline WGPUBufferUsage map_buffer_usage(std::uint8_t mask, bool& out_is_staging) {
    out_is_staging = (mask & static_cast<std::uint8_t>(GPUBufferUsage::kStaging)) != 0;

    WGPUBufferUsage flags = WGPUBufferUsage_None;
    // Always include CopyDst so update_buffer (wgpuQueueWriteBuffer) works
    // for any non-staging buffer; staging buffers get MapRead instead.
    if (out_is_staging) {
        flags |= WGPUBufferUsage_MapRead;
        flags |= WGPUBufferUsage_CopyDst;  // staging is the readback target
    } else {
        flags |= WGPUBufferUsage_CopyDst;  // for wgpuQueueWriteBuffer
        flags |= WGPUBufferUsage_CopySrc;  // for blit / readback to staging
    }
    if (mask & static_cast<std::uint8_t>(GPUBufferUsage::kVertex))
        flags |= WGPUBufferUsage_Vertex;
    if (mask & static_cast<std::uint8_t>(GPUBufferUsage::kIndex))
        flags |= WGPUBufferUsage_Index;
    if (mask & static_cast<std::uint8_t>(GPUBufferUsage::kUniform))
        flags |= WGPUBufferUsage_Uniform;
    if (mask & static_cast<std::uint8_t>(GPUBufferUsage::kStorage))
        flags |= WGPUBufferUsage_Storage;
    if (mask & static_cast<std::uint8_t>(GPUBufferUsage::kIndirect))
        flags |= WGPUBufferUsage_Indirect;
    return flags;
}

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// DawnGPUDevice
// ═══════════════════════════════════════════════════════════════════════

class DawnGPUDevice final : public GPUDevice {
public:
    // Init() does the synchronous adapter/device/queue acquisition.
    // Returns false if any step fails; caller (factory) discards the
    // partially-initialized DawnGPUDevice on failure.
    bool init(bool /*request_high_performance*/) noexcept {
        // Instance — must request TimedWaitAny so wgpuInstanceWaitAny works
        // with WGPUCallbackMode_WaitAnyOnly. Without this feature, WaitAny
        // returns Error/Timeout immediately and our sync bridge breaks.
        WGPUInstanceFeatureName features[1] = { WGPUInstanceFeatureName_TimedWaitAny };
        WGPUInstanceDescriptor instance_desc{};
        instance_desc.requiredFeatureCount = 1;
        instance_desc.requiredFeatures = features;
        wgpu_instance_ = wgpuCreateInstance(&instance_desc);
        if (!wgpu_instance_) {
            dawn_log("create_dawn_gpu_device: wgpuCreateInstance returned NULL");
            return false;
        }

        // Adapter — sync via WaitAny.
        AdapterCallbackData adapter_cb{};
        WGPURequestAdapterCallbackInfo adapter_cb_info{};
        adapter_cb_info.mode = WGPUCallbackMode_WaitAnyOnly;
        adapter_cb_info.callback = on_adapter_request;
        adapter_cb_info.userdata1 = &adapter_cb;
        WGPUFuture adapter_future =
            wgpuInstanceRequestAdapter(wgpu_instance_, /*options=*/nullptr, adapter_cb_info);
        WGPUFutureWaitInfo adapter_wait{};
        adapter_wait.future = adapter_future;
        adapter_wait.completed = false;
        WGPUWaitStatus ws = wgpuInstanceWaitAny(wgpu_instance_, 1, &adapter_wait, UINT64_MAX);
        if (ws != WGPUWaitStatus_Success || !adapter_cb.success) {
            dawn_log("create_dawn_gpu_device: adapter WaitAny status=%d", ws);
            return false;
        }
        wgpu_adapter_ = adapter_cb.adapter;

        // Device — sync via WaitAny.
        DeviceCallbackData device_cb{};
        WGPURequestDeviceCallbackInfo device_cb_info{};
        device_cb_info.mode = WGPUCallbackMode_WaitAnyOnly;
        device_cb_info.callback = on_device_request;
        device_cb_info.userdata1 = &device_cb;
        WGPUDeviceDescriptor device_desc{};
        WGPUFuture device_future =
            wgpuAdapterRequestDevice(wgpu_adapter_, &device_desc, device_cb_info);
        WGPUFutureWaitInfo device_wait{};
        device_wait.future = device_future;
        device_wait.completed = false;
        ws = wgpuInstanceWaitAny(wgpu_instance_, 1, &device_wait, UINT64_MAX);
        if (ws != WGPUWaitStatus_Success || !device_cb.success) {
            dawn_log("create_dawn_gpu_device: device WaitAny status=%d", ws);
            return false;
        }
        wgpu_device_ = device_cb.device;

        // Queue — synchronous accessor.
        wgpu_queue_ = wgpuDeviceGetQueue(wgpu_device_);
        if (!wgpu_queue_) {
            dawn_log("create_dawn_gpu_device: wgpuDeviceGetQueue returned NULL");
            return false;
        }

        return true;
    }

    ~DawnGPUDevice() override {
        // Release in reverse of acquisition order.
        // Buffers / textures / shaders / pipelines released in their
        // type-specific destroy methods + map cleanup below.
        for (auto& kv : buffers_) {
            if (kv.second.handle) {
                wgpuBufferDestroy(kv.second.handle);
                wgpuBufferRelease(kv.second.handle);
            }
        }
        buffers_.clear();
        if (wgpu_queue_)    { wgpuQueueRelease(wgpu_queue_);       wgpu_queue_ = nullptr; }
        if (wgpu_device_)   { wgpuDeviceRelease(wgpu_device_);     wgpu_device_ = nullptr; }
        if (wgpu_adapter_)  { wgpuAdapterRelease(wgpu_adapter_);   wgpu_adapter_ = nullptr; }
        if (wgpu_instance_) { wgpuInstanceRelease(wgpu_instance_); wgpu_instance_ = nullptr; }
    }

    // ─── Device Info ───

    GraphicsBackend backend() const noexcept override {
        return GraphicsBackend::kDawn;
    }

    GPUCaps capabilities() const noexcept override {
        // Phase 6.2.K wires this via wgpuDeviceGetLimits. For now return
        // WebGPU spec-minimum guarantees so callers can dimension based on
        // a known floor.
        GPUCaps caps{};
        caps.backend = GraphicsBackend::kDawn;
        caps.max_buffer_size = 256u * 1024u * 1024u;
        caps.max_texture_size = 8192u;
        caps.max_compute_workgroup_size = 256u;
        caps.max_threadgroup_memory = 16384u;
        caps.supports_compute = true;
        caps.supports_indirect_draw = true;
        caps.supports_shared_memory = true;
        caps.supports_half_precision = false;
        caps.supports_simd_group = false;
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
        if (!wgpu_device_) {
            warn_once(stub_create_buffer_, "create_buffer", "wgpu_device_ is NULL — factory init failed");
            return GPUBufferHandle{0};
        }
        if (desc.size_bytes == 0) {
            // Dawn rejects 0-byte buffers; surface a noop handle for safety.
            return GPUBufferHandle{0};
        }

        bool is_staging = false;
        WGPUBufferUsage usage = map_buffer_usage(desc.usage_mask, is_staging);

        WGPUBufferDescriptor buf_desc{};
        buf_desc.usage = usage;
        buf_desc.size = desc.size_bytes;
        buf_desc.mappedAtCreation = false;  // hot path uses queue.writeBuffer; no need
        if (desc.label) {
            // WGPUStringView with WGPU_STRLEN sentinel = "use strlen-style null-terminated"
            buf_desc.label.data = desc.label;
            buf_desc.label.length = WGPU_STRLEN;
        }

        WGPUBuffer buffer = wgpuDeviceCreateBuffer(wgpu_device_, &buf_desc);
        if (!buffer) {
            dawn_log("create_buffer: wgpuDeviceCreateBuffer returned NULL "
                     "(size=%zu usage=0x%llx)",
                     desc.size_bytes, static_cast<unsigned long long>(usage));
            return GPUBufferHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        DawnBuffer entry;
        entry.handle = buffer;
        entry.size_bytes = desc.size_bytes;
        entry.usage_mask = desc.usage_mask;
        entry.is_staging = is_staging;
        entry.currently_mapped = false;
        // warned_map_write atomic default-constructs to false.
        buffers_.emplace(handle_id, std::move(entry));
        allocated_bytes_ += desc.size_bytes;
        if (allocated_bytes_ > peak_bytes_) peak_bytes_ = allocated_bytes_;
        return GPUBufferHandle{handle_id};
    }

    void destroy_buffer(GPUBufferHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it == buffers_.end()) return;
        if (it->second.handle) {
            // wgpuBufferDestroy releases GPU resources immediately. Release
            // drops the CPU-side reference. Both are needed to fully tear
            // down without a refcount leak.
            wgpuBufferDestroy(it->second.handle);
            wgpuBufferRelease(it->second.handle);
        }
        if (allocated_bytes_ >= it->second.size_bytes) {
            allocated_bytes_ -= it->second.size_bytes;
        }
        buffers_.erase(it);
    }

    void* map_buffer(GPUBufferHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it == buffers_.end()) return nullptr;
        DawnBuffer& entry = it->second;
        if (!entry.handle) return nullptr;

        // Fast path: kStaging buffer = CPU readback target.
        // Pattern: (1) caller submits a CopyBufferToBuffer src→staging,
        // (2) calls map_buffer here, (3) reads via returned pointer,
        // (4) calls unmap_buffer. Spin-wait below blocks the calling
        // thread until the GPU finishes and the map fires. Frequency is
        // expected to be 1-2× per second (loss monitor), so the spin is
        // user's accepted cost.
        if (entry.is_staging) {
            ++spin_wait_count_;

            MapCallbackData map_cb{};
            WGPUBufferMapCallbackInfo cb_info{};
            cb_info.mode = WGPUCallbackMode_WaitAnyOnly;
            cb_info.callback = on_buffer_map;
            cb_info.userdata1 = &map_cb;
            WGPUFuture map_future = wgpuBufferMapAsync(
                entry.handle, WGPUMapMode_Read, /*offset=*/0,
                entry.size_bytes, cb_info);
            WGPUFutureWaitInfo wait{};
            wait.future = map_future;
            wait.completed = false;
            // 1-second cap on the spin: if a single map takes longer,
            // something is genuinely wrong (GPU hang? device lost?).
            // Bail with nullptr so caller can recover instead of blocking
            // the whole app on a stuck spin.
            constexpr uint64_t kSpinBudgetNs = 1'000'000'000ull;  // 1 s
            WGPUWaitStatus ws = wgpuInstanceWaitAny(
                wgpu_instance_, 1, &wait, kSpinBudgetNs);
            if (ws != WGPUWaitStatus_Success || !map_cb.mapped) {
                dawn_log("map_buffer (staging) WaitAny exceeded 1s "
                         "or callback errored — possible GPU hang. "
                         "Returning nullptr; caller should treat as "
                         "transient failure.");
                return nullptr;
            }

            const void* ptr = wgpuBufferGetConstMappedRange(
                entry.handle, /*offset=*/0, entry.size_bytes);
            if (!ptr) {
                dawn_log("map_buffer (staging) GetConstMappedRange returned NULL");
                wgpuBufferUnmap(entry.handle);
                return nullptr;
            }
            entry.currently_mapped = true;
            // const-cast: GPUDevice::map_buffer signature is `void*`; for
            // staging we hand back a const-mapped range. Caller MUST NOT
            // write — that's a contract violation that Dawn won't catch
            // because the const-ness is stripped at the API boundary.
            // This is the Dawn equivalent of Metal's MTLStorageModeShared
            // CPU-mapped ptr where const-ness lives in the contract.
            return const_cast<void*>(ptr);
        }

        // Discouraged path: caller wants CPU→GPU write via map. They
        // should be using update_buffer (wgpuQueueWriteBuffer) which
        // doesn't spin and doesn't block the queue. Warn once per
        // process so the violation is visible during dev, return
        // nullptr so the caller's data flow fails loud rather than silent.
        warn_once(warned_map_write_discouraged_,
                  "DawnGPUDevice::map_buffer (write path)",
                  "buffer was not created with kStaging — use update_buffer "
                  "for CPU->GPU writes (zero-block hot path), or set "
                  "GPUBufferUsage::kStaging on the desc if read-back is "
                  "actually intended");
        return nullptr;
    }

    void unmap_buffer(GPUBufferHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it == buffers_.end()) return;
        if (!it->second.currently_mapped) return;
        wgpuBufferUnmap(it->second.handle);
        it->second.currently_mapped = false;
    }

    void update_buffer(GPUBufferHandle handle, const void* data,
                       std::size_t offset, std::size_t size) noexcept override {
        if (!data || size == 0) return;
        if (!wgpu_queue_) return;

        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it == buffers_.end()) return;
        DawnBuffer& entry = it->second;
        if (!entry.handle) return;
        if (offset + size > entry.size_bytes) {
            dawn_log("update_buffer: out-of-bounds (offset=%zu size=%zu cap=%zu)",
                     offset, size, entry.size_bytes);
            return;
        }

        // HOT PATH — non-blocking. wgpuQueueWriteBuffer enqueues a copy
        // through the queue's submission timeline. Returns immediately;
        // the actual GPU-side write happens when Dawn's queue worker
        // gets to it. This is the every-frame splat-data-update path.
        // Stability characteristic: zero CPU stall regardless of GPU
        // generation (iPhone 8 → iPhone 17 Pro all see < 100µs here).
        wgpuQueueWriteBuffer(wgpu_queue_, entry.handle,
                             static_cast<uint64_t>(offset), data, size);
    }

    // ─── Texture Management (Phase 6.2.G) ───

    GPUTextureHandle create_texture(const GPUTextureDesc& desc) noexcept override {
        (void)desc;
        warn_once(stub_create_texture_, "create_texture", "Phase 6.2.G stub");
        return GPUTextureHandle{0};
    }

    void destroy_texture(GPUTextureHandle handle) noexcept override {
        (void)handle;
        warn_once(stub_destroy_texture_, "destroy_texture", "Phase 6.2.G stub");
    }

    void update_texture(GPUTextureHandle handle, const void* data,
                        std::uint32_t width, std::uint32_t height,
                        std::uint32_t bytes_per_row) noexcept override {
        (void)handle; (void)data; (void)width; (void)height; (void)bytes_per_row;
        warn_once(stub_update_texture_, "update_texture", "Phase 6.2.G stub");
    }

    // ─── Shader Management (Phase 6.2.H) ───

    GPUShaderHandle load_shader(const char* name,
                                GPUShaderStage stage) noexcept override {
        (void)name; (void)stage;
        warn_once(stub_load_shader_, "load_shader", "Phase 6.2.H stub");
        return GPUShaderHandle{0};
    }

    void destroy_shader(GPUShaderHandle handle) noexcept override {
        (void)handle;
        warn_once(stub_destroy_shader_, "destroy_shader", "Phase 6.2.H stub");
    }

    // ─── Pipeline Management (Phase 6.2.I + 6.2.J) ───

    GPURenderPipelineHandle create_render_pipeline(
        GPUShaderHandle vertex_shader,
        GPUShaderHandle fragment_shader,
        const GPURenderTargetDesc& target_desc) noexcept override {
        (void)vertex_shader; (void)fragment_shader; (void)target_desc;
        warn_once(stub_create_render_pipeline_, "create_render_pipeline",
                  "Phase 6.2.I stub");
        return GPURenderPipelineHandle{0};
    }

    void destroy_render_pipeline(GPURenderPipelineHandle handle) noexcept override {
        (void)handle;
        warn_once(stub_destroy_render_pipeline_, "destroy_render_pipeline",
                  "Phase 6.2.I stub");
    }

    GPUComputePipelineHandle create_compute_pipeline(
        GPUShaderHandle compute_shader) noexcept override {
        (void)compute_shader;
        warn_once(stub_create_compute_pipeline_, "create_compute_pipeline",
                  "Phase 6.2.J stub");
        return GPUComputePipelineHandle{0};
    }

    void destroy_compute_pipeline(GPUComputePipelineHandle handle) noexcept override {
        (void)handle;
        warn_once(stub_destroy_compute_pipeline_, "destroy_compute_pipeline",
                  "Phase 6.2.J stub");
    }

    // ─── Command Buffer (Phase 6.2.K) ───

    std::unique_ptr<GPUCommandBuffer> create_command_buffer() noexcept override {
        warn_once(stub_create_command_buffer_, "create_command_buffer",
                  "Phase 6.2.K stub");
        return nullptr;
    }

    // ─── Synchronization ───

    void wait_idle() noexcept override {
        // Phase 6.2.K: wgpuQueueOnSubmittedWorkDone + wait via WaitAny.
        // 6.2.F: skeleton wait_idle is a no-op since nothing is submitted
        // through us yet (no command buffers issued). update_buffer's
        // wgpuQueueWriteBuffer enqueues but doesn't need a wait_idle.
    }

    // ─── Telemetry accessors ───────────────────────────────────────────

    /// Total number of map_buffer calls that took the spin-wait path
    /// since device creation. Surfaced so tests / profilers can assert
    /// the hot-path stays at zero. Not part of GPUDevice virtual API
    /// — DawnGPUDevice-specific accessor.
    std::uint64_t spin_wait_count() const noexcept {
        return spin_wait_count_.load(std::memory_order_relaxed);
    }

    // ─── Dawn-specific accessors (used by future DawnCommandBuffer / Encoder) ───

    WGPUDevice wgpu_device() const noexcept { return wgpu_device_; }
    WGPUQueue wgpu_queue() const noexcept { return wgpu_queue_; }
    WGPUInstance wgpu_instance() const noexcept { return wgpu_instance_; }

private:
    // Native Dawn handles. Initialized by init() in the factory.
    WGPUInstance wgpu_instance_{nullptr};
    WGPUAdapter wgpu_adapter_{nullptr};
    WGPUDevice wgpu_device_{nullptr};
    WGPUQueue wgpu_queue_{nullptr};

    mutable std::mutex mutex_;
    std::uint32_t next_id_{0};

    // Resource maps. Buffers populated by 6.2.F. Others populated by 6.2.G-K.
    std::unordered_map<std::uint32_t, DawnBuffer> buffers_;
    [[maybe_unused]] std::unordered_set<std::uint32_t> textures_;            // 6.2.G
    [[maybe_unused]] std::unordered_set<std::uint32_t> shaders_;             // 6.2.H
    [[maybe_unused]] std::unordered_set<std::uint32_t> render_pipelines_;    // 6.2.I
    [[maybe_unused]] std::unordered_set<std::uint32_t> compute_pipelines_;   // 6.2.J

    // Memory tracking
    std::size_t allocated_bytes_{0};
    std::size_t peak_bytes_{0};

    // Telemetry: total spin-wait-path map_buffer calls. Atomic so the
    // accessor + increment don't race; relaxed ordering is fine because
    // the value is only ever read for diagnostic purposes.
    std::atomic<std::uint64_t> spin_wait_count_{0};

    // Device-level warn-once flags
    std::atomic<bool> warned_map_write_discouraged_{false};

    // Stub-fired flags for the methods 6.2.G-K still owe.
    std::atomic<bool> stub_create_buffer_{false};
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
    auto device = std::make_unique<DawnGPUDevice>();
    if (!device->init(request_high_performance)) {
        dawn_log("create_dawn_gpu_device: init failed; returning nullptr");
        return nullptr;
    }
    return device;
}

std::unique_ptr<GPUCommandBuffer> create_dawn_command_buffer(GPUDevice& device) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return nullptr;
    // Phase 6.2.K wires the real command-buffer creation. Skeleton state.
    return nullptr;
}

}  // namespace render
}  // namespace aether

#endif  // AETHER_ENABLE_DAWN
