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
#include "aether/render/gpu_command.h"
#include "aether/shaders/wgsl_sources.h"  // 6.4a baked WGSL externs

#include <webgpu/webgpu.h>  // C API — strict-flags compatible

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

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

struct QueueWorkDoneCallbackData {
    bool done{false};
    bool error{false};
};
extern "C" void on_queue_work_done(WGPUQueueWorkDoneStatus status,
                                   WGPUStringView message,
                                   WGPU_NULLABLE void* userdata1,
                                   WGPU_NULLABLE void* /*userdata2*/) {
    auto* data = static_cast<QueueWorkDoneCallbackData*>(userdata1);
    if (status == WGPUQueueWorkDoneStatus_Success) {
        data->done = true;
    } else {
        data->error = true;
        dawn_log("QueueWorkDone FAILED: status=%d msg=%.*s",
                 status,
                 message.length == WGPU_STRLEN ? 0 : static_cast<int>(message.length),
                 message.data ? message.data : "");
    }
}

// ─── Uncaptured error callback ─────────────────────────────────────────
//
// Fires when Dawn detects a validation error (binding mismatch, wrong
// stage, OOM, …) that wasn't surfaced through a return value. Without
// this, errors go silent and downstream code reads zero-filled buffers
// that look like a successful but wrong result. Phase 6.3a code-review
// rule: "silent = catastrophe".
//
// On a validation error we abort the process — the failure is loud and
// immediate, with the Dawn diagnostic preserved in stderr. The harness
// uses the same pattern (dawn_kernel_harness.cpp on_uncaptured_error).
//
// On non-validation errors (Internal / Unknown) we still abort: there
// is no recovery path inside the GPUDevice contract for these.
inline const char* error_type_name_(WGPUErrorType t) {
    switch (t) {
        case WGPUErrorType_NoError:     return "NoError";
        case WGPUErrorType_Validation:  return "Validation";
        case WGPUErrorType_OutOfMemory: return "OutOfMemory";
        case WGPUErrorType_Internal:    return "Internal";
        case WGPUErrorType_Unknown:     return "Unknown";
        default:                        return "<?>";
    }
}
extern "C" void on_device_uncaptured_error(WGPUDevice const* /*device*/,
                                           WGPUErrorType type,
                                           WGPUStringView message,
                                           WGPU_NULLABLE void* /*userdata1*/,
                                           WGPU_NULLABLE void* /*userdata2*/) {
    dawn_log("UNCAPTURED ERROR type=%s (%u) msg=%.*s",
             error_type_name_(type), static_cast<unsigned>(type),
             message.length == WGPU_STRLEN
                 ? (message.data ? static_cast<int>(std::strlen(message.data)) : 0)
                 : static_cast<int>(message.length),
             message.data ? message.data : "");
    dawn_log("UNCAPTURED ERROR: aborting — silent failure would defeat "
             "the device contract");
    std::abort();
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

// ─── Per-shader state ──────────────────────────────────────────────────

struct DawnShader {
    WGPUShaderModule module{nullptr};
    GPUShaderStage stage{GPUShaderStage::kCompute};
    // Entry-point name. WGSL allows multiple entry points per module
    // (e.g. splat_render.wgsl has both vs_main and fs_main); we record
    // which one this shader handle resolves to so pipeline creation can
    // wire the right ProgrammableStageDescriptor.entryPoint.
    std::string entry_point;
};

// Registry entry for a WGSL source + its entry-point function name.
struct WgslEntry {
    std::string source;
    std::string entry_point;
};

// ─── Per-texture state ─────────────────────────────────────────────────

struct DawnTexture {
    WGPUTexture handle{nullptr};
    std::uint32_t width{0};
    std::uint32_t height{0};
    GPUTextureFormat format{GPUTextureFormat::kRGBA8Unorm};
    std::uint8_t usage_mask{0};
    // Phase 6.4a: when imported from an IOSurface via SharedTextureMemory,
    // we hold the SharedTextureMemory handle here so the texture survives
    // beyond a single render pass and so per-frame Begin/EndAccess fences
    // can find the right memory object. nullptr for plain (non-imported)
    // textures.
    WGPUSharedTextureMemory shared_memory{nullptr};
};

// ─── Texture / blend / topology format mapping ─────────────────────────

inline WGPUTextureFormat map_texture_format(GPUTextureFormat fmt) {
    switch (fmt) {
        case GPUTextureFormat::kR8Unorm:               return WGPUTextureFormat_R8Unorm;
        case GPUTextureFormat::kRG8Unorm:              return WGPUTextureFormat_RG8Unorm;
        case GPUTextureFormat::kRGBA8Unorm:            return WGPUTextureFormat_RGBA8Unorm;
        case GPUTextureFormat::kBGRA8Unorm:            return WGPUTextureFormat_BGRA8Unorm;
        case GPUTextureFormat::kRGBA8Srgb:             return WGPUTextureFormat_RGBA8UnormSrgb;
        case GPUTextureFormat::kR16Float:              return WGPUTextureFormat_R16Float;
        case GPUTextureFormat::kRG16Float:             return WGPUTextureFormat_RG16Float;
        case GPUTextureFormat::kRGBA16Float:           return WGPUTextureFormat_RGBA16Float;
        case GPUTextureFormat::kR32Float:              return WGPUTextureFormat_R32Float;
        case GPUTextureFormat::kRG32Float:             return WGPUTextureFormat_RG32Float;
        case GPUTextureFormat::kRGBA32Float:           return WGPUTextureFormat_RGBA32Float;
        case GPUTextureFormat::kDepth32Float:          return WGPUTextureFormat_Depth32Float;
        case GPUTextureFormat::kDepth32Float_Stencil8: return WGPUTextureFormat_Depth32FloatStencil8;
        case GPUTextureFormat::kR32Uint:               return WGPUTextureFormat_R32Uint;
        case GPUTextureFormat::kRG32Uint:              return WGPUTextureFormat_RG32Uint;
        case GPUTextureFormat::kInvalid:               return WGPUTextureFormat_Undefined;
    }
    return WGPUTextureFormat_RGBA8Unorm;
}

inline WGPUBlendOperation map_blend_op(GPUBlendOperation op) {
    switch (op) {
        case GPUBlendOperation::kAdd:             return WGPUBlendOperation_Add;
        case GPUBlendOperation::kSubtract:        return WGPUBlendOperation_Subtract;
        case GPUBlendOperation::kReverseSubtract: return WGPUBlendOperation_ReverseSubtract;
    }
    return WGPUBlendOperation_Add;
}

inline WGPUBlendFactor map_blend_factor(GPUBlendFactor f) {
    switch (f) {
        case GPUBlendFactor::kZero:                     return WGPUBlendFactor_Zero;
        case GPUBlendFactor::kOne:                      return WGPUBlendFactor_One;
        case GPUBlendFactor::kSourceColor:              return WGPUBlendFactor_Src;
        case GPUBlendFactor::kOneMinusSourceColor:      return WGPUBlendFactor_OneMinusSrc;
        case GPUBlendFactor::kDestinationColor:         return WGPUBlendFactor_Dst;
        case GPUBlendFactor::kOneMinusDestinationColor: return WGPUBlendFactor_OneMinusDst;
        case GPUBlendFactor::kSourceAlpha:              return WGPUBlendFactor_SrcAlpha;
        case GPUBlendFactor::kOneMinusSourceAlpha:      return WGPUBlendFactor_OneMinusSrcAlpha;
        case GPUBlendFactor::kDestinationAlpha:         return WGPUBlendFactor_DstAlpha;
        case GPUBlendFactor::kOneMinusDestinationAlpha: return WGPUBlendFactor_OneMinusDstAlpha;
    }
    return WGPUBlendFactor_One;
}

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

        // Device — sync via WaitAny. Two-phase: first try with the full
        // feature/limit set Phase 6.3a proved are needed for the Brush
        // training kernels (Subgroups + bumped limits). If RequestDevice
        // rejects (e.g. adapter doesn't expose Subgroups on some Dawn
        // backends), retry with a reduced set so the viewer kernels still
        // work — supports_subgroups_ tracks the fallback so callers can
        // skip rasterize_backwards. National-grade stability rule:
        // optional features must not block the whole device.
        //
        // The 5 carry-overs from harness::init():
        //   1. Subgroups feature (rasterize_backwards)
        //   2. maxComputeInvocationsPerWorkgroup = 512 (prefix_sum_*)
        //   3. maxComputeWorkgroupSizeX           = 512 (prefix_sum_*)
        //   4. maxStorageBuffersPerShaderStage    = 10 (rasterize_backwards)
        //   5. UncapturedErrorCallback abort       (catch silent validation)
        WGPULimits required_limits = WGPU_LIMITS_INIT;
        required_limits.maxComputeInvocationsPerWorkgroup = 512;
        required_limits.maxComputeWorkgroupSizeX = 512;
        required_limits.maxStorageBuffersPerShaderStage = 10;

        // Phase 6.4a: also request the SharedTextureMemoryIOSurface +
        // SharedFenceMTLSharedEvent feature pair. Both are needed for
        // the PocketWorld Flutter Texture bridge:
        //   - SharedTextureMemoryIOSurface: import IOSurface as WGPUTexture
        //   - SharedFenceMTLSharedEvent:    EndAccess produces a fence
        //                                    that synchronizes Dawn writes
        //                                    with the IOSurface consumer
        //                                    (Flutter compositor / Metal
        //                                    blitter)
        // Apple-only; graceful fallback: if either is unavailable, the
        // IOSurface bridge degrades but the rest of the device still
        // works (training kernels / smokes are unaffected).
        WGPUFeatureName all_features[3] = {
            WGPUFeatureName_Subgroups,
            WGPUFeatureName_SharedTextureMemoryIOSurface,
            WGPUFeatureName_SharedFenceMTLSharedEvent,
        };
        WGPUFeatureName subgroups_only[1] = { WGPUFeatureName_Subgroups };

        auto try_request_device = [&](size_t feature_count,
                                       const WGPUFeatureName* features) -> bool {
            DeviceCallbackData device_cb{};
            WGPURequestDeviceCallbackInfo device_cb_info{};
            device_cb_info.mode = WGPUCallbackMode_WaitAnyOnly;
            device_cb_info.callback = on_device_request;
            device_cb_info.userdata1 = &device_cb;

            WGPUDeviceDescriptor device_desc = WGPU_DEVICE_DESCRIPTOR_INIT;
            device_desc.requiredFeatureCount = feature_count;
            device_desc.requiredFeatures = features;
            device_desc.requiredLimits = &required_limits;
            device_desc.uncapturedErrorCallbackInfo.callback =
                on_device_uncaptured_error;
            // userdata not used — the callback is global-state-free.

            WGPUFuture fut = wgpuAdapterRequestDevice(
                wgpu_adapter_, &device_desc, device_cb_info);
            WGPUFutureWaitInfo wait{};
            wait.future = fut;
            wait.completed = false;
            WGPUWaitStatus wstatus =
                wgpuInstanceWaitAny(wgpu_instance_, 1, &wait, UINT64_MAX);
            if (wstatus != WGPUWaitStatus_Success || !device_cb.success) {
                return false;
            }
            wgpu_device_ = device_cb.device;
            return true;
        };

        // Attempt 1: full feature set (Subgroups + IOSurface + MTLSharedEvent).
        if (try_request_device(3, all_features)) {
            supports_subgroups_ = true;
            supports_iosurface_  = true;
        } else if (try_request_device(1, subgroups_only)) {
            // Attempt 2: Subgroups only (Linux/Android/Windows path).
            supports_subgroups_ = true;
            supports_iosurface_  = false;
            dawn_log("create_dawn_gpu_device: SharedTextureMemoryIOSurface "
                     "feature unavailable on this adapter (expected on "
                     "non-Apple platforms). Flutter Texture bridge will "
                     "fall back to copy-based readback.");
        } else {
            // Attempt 3: bare minimum.
            dawn_log("create_dawn_gpu_device: device request with Subgroups "
                     "failed — retrying with no optional features. "
                     "rasterize_backwards.wgsl will be unavailable.");
            if (!try_request_device(0, nullptr)) {
                dawn_log("create_dawn_gpu_device: device request failed "
                         "even with no optional features — adapter likely "
                         "doesn't meet WebGPU minimums");
                return false;
            }
            supports_subgroups_ = false;
            supports_iosurface_  = false;
        }

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
        for (auto& kv : shaders_) {
            if (kv.second.module) {
                wgpuShaderModuleRelease(kv.second.module);
            }
        }
        shaders_.clear();
        for (auto& kv : compute_pipelines_) {
            if (kv.second) wgpuComputePipelineRelease(kv.second);
        }
        compute_pipelines_.clear();
        for (auto& kv : render_pipelines_) {
            if (kv.second) wgpuRenderPipelineRelease(kv.second);
        }
        render_pipelines_.clear();
        for (auto& kv : textures_) {
            if (kv.second.handle) {
                wgpuTextureDestroy(kv.second.handle);
                wgpuTextureRelease(kv.second.handle);
            }
        }
        textures_.clear();
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

    // ─── Texture Management (Phase 6.2.I) ───

    GPUTextureHandle create_texture(const GPUTextureDesc& desc) noexcept override {
        if (!wgpu_device_) return GPUTextureHandle{0};
        if (desc.width == 0 || desc.height == 0) return GPUTextureHandle{0};

        // Map usage mask. For render targets we always include CopySrc
        // so readback_texture (Step 9) can copyTextureToBuffer without a
        // second usage hint. This matches the harness alloc_render_target
        // contract (RenderAttachment | CopySrc | TextureBinding).
        WGPUTextureUsage usage = WGPUTextureUsage_None;
        if (desc.usage_mask & static_cast<std::uint8_t>(GPUTextureUsage::kShaderRead))
            usage |= WGPUTextureUsage_TextureBinding;
        if (desc.usage_mask & static_cast<std::uint8_t>(GPUTextureUsage::kShaderWrite))
            usage |= WGPUTextureUsage_StorageBinding;
        if (desc.usage_mask & static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget)) {
            usage |= WGPUTextureUsage_RenderAttachment;
            usage |= WGPUTextureUsage_CopySrc;
            // Render targets are commonly sampled in subsequent passes
            // (e.g. compose pass after splat_render). Allow that without
            // forcing the caller to opt in explicitly.
            usage |= WGPUTextureUsage_TextureBinding;
        }
        // CopyDst added unconditionally so update_texture (queue write)
        // works on any texture without the caller having to opt in.
        usage |= WGPUTextureUsage_CopyDst;

        WGPUTextureDescriptor tex_desc = WGPU_TEXTURE_DESCRIPTOR_INIT;
        tex_desc.usage = usage;
        tex_desc.dimension = (desc.depth > 1) ? WGPUTextureDimension_3D
                                              : WGPUTextureDimension_2D;
        tex_desc.size.width = desc.width;
        tex_desc.size.height = desc.height;
        tex_desc.size.depthOrArrayLayers = desc.depth > 0 ? desc.depth : 1;
        tex_desc.format = map_texture_format(desc.format);
        tex_desc.mipLevelCount = desc.mip_levels > 0 ? desc.mip_levels : 1;
        tex_desc.sampleCount = 1;
        if (desc.label) {
            tex_desc.label.data = desc.label;
            tex_desc.label.length = WGPU_STRLEN;
        }

        WGPUTexture texture = wgpuDeviceCreateTexture(wgpu_device_, &tex_desc);
        if (!texture) {
            dawn_log("create_texture: wgpuDeviceCreateTexture returned NULL "
                     "(w=%u h=%u format=%d)",
                     desc.width, desc.height, static_cast<int>(desc.format));
            return GPUTextureHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        DawnTexture entry{};
        entry.handle = texture;
        entry.width = desc.width;
        entry.height = desc.height;
        entry.format = desc.format;
        entry.usage_mask = desc.usage_mask;
        textures_.emplace(handle_id, std::move(entry));
        return GPUTextureHandle{handle_id};
    }

    void destroy_texture(GPUTextureHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(handle.id);
        if (it == textures_.end()) return;
        if (it->second.handle) {
            // For SharedTextureMemory-backed textures we should NOT call
            // wgpuTextureDestroy (the underlying storage is owned by the
            // shared memory, not by this texture handle). Just Release
            // the texture, then Release the SharedTextureMemory.
            if (it->second.shared_memory) {
                wgpuTextureRelease(it->second.handle);
                wgpuSharedTextureMemoryRelease(it->second.shared_memory);
            } else {
                wgpuTextureDestroy(it->second.handle);
                wgpuTextureRelease(it->second.handle);
            }
        }
        textures_.erase(it);
    }

    // ─── 6.4a: IOSurface-backed texture import ─────────────────────────
    //
    // Creates a WGPUSharedTextureMemory from the provided IOSurfaceRef
    // (passed as void* per the Dawn C API), then a WGPUTexture backed by
    // that memory. The texture's bytes ARE the IOSurface's bytes — Dawn
    // writes directly into Flutter-readable memory, no copy.
    //
    // Per-frame protocol: the renderer MUST wrap each render pass with
    // BeginAccess / EndAccess (see iosurface_begin_access /
    // iosurface_end_access below) — this is the producer/consumer fence
    // between Dawn writes and Flutter compositor reads. On Apple this
    // maps to MTLSharedEvent under the hood.
    GPUTextureHandle import_iosurface(void* iosurface,
                                       std::uint32_t width,
                                       std::uint32_t height,
                                       GPUTextureFormat format) noexcept {
        if (!wgpu_device_) return GPUTextureHandle{0};
        if (!supports_iosurface_) {
            dawn_log("import_iosurface: SharedTextureMemoryIOSurface feature "
                     "not enabled — Apple-platform-only path");
            return GPUTextureHandle{0};
        }
        if (!iosurface || width == 0 || height == 0) {
            dawn_log("import_iosurface: invalid args (iosurface=%p w=%u h=%u)",
                     iosurface, width, height);
            return GPUTextureHandle{0};
        }

        WGPUSharedTextureMemoryIOSurfaceDescriptor io_desc =
            WGPU_SHARED_TEXTURE_MEMORY_IO_SURFACE_DESCRIPTOR_INIT;
        io_desc.ioSurface = iosurface;
        // allowStorageBinding=false: we use the texture as a render
        // attachment + texture binding, never as a compute storage write.
        io_desc.allowStorageBinding = WGPU_FALSE;

        WGPUSharedTextureMemoryDescriptor mem_desc =
            WGPU_SHARED_TEXTURE_MEMORY_DESCRIPTOR_INIT;
        mem_desc.nextInChain = &io_desc.chain;

        WGPUSharedTextureMemory mem =
            wgpuDeviceImportSharedTextureMemory(wgpu_device_, &mem_desc);
        if (!mem) {
            dawn_log("import_iosurface: ImportSharedTextureMemory NULL "
                     "(IOSurface format / Dawn-version mismatch?)");
            return GPUTextureHandle{0};
        }

        // CreateTexture with NULL descriptor uses the SharedTextureMemory's
        // inherent properties (matched to the IOSurface format).
        WGPUTexture texture =
            wgpuSharedTextureMemoryCreateTexture(mem, /*descriptor=*/nullptr);
        if (!texture) {
            dawn_log("import_iosurface: CreateTexture NULL");
            wgpuSharedTextureMemoryRelease(mem);
            return GPUTextureHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        DawnTexture entry{};
        entry.handle = texture;
        entry.width = width;
        entry.height = height;
        entry.format = format;
        entry.usage_mask = static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget);
        entry.shared_memory = mem;
        textures_.emplace(handle_id, std::move(entry));
        return GPUTextureHandle{handle_id};
    }

    // BeginAccess: fence between the previous IOSurface consumer (Flutter
    // compositor reading the prior frame) and the upcoming Dawn write.
    // Must be called BEFORE the render pass that writes the texture.
    bool iosurface_begin_access(GPUTextureHandle handle) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(handle.id);
        if (it == textures_.end() || !it->second.shared_memory) return false;
        WGPUSharedTextureMemoryBeginAccessDescriptor desc =
            WGPU_SHARED_TEXTURE_MEMORY_BEGIN_ACCESS_DESCRIPTOR_INIT;
        // Texture is "initialized" — Dawn will preserve any prior content
        // (we'll clear it on the render pass anyway).
        desc.initialized = WGPU_TRUE;
        // No fences chained on input — plain "we want to write" semantics.
        WGPUStatus s = wgpuSharedTextureMemoryBeginAccess(
            it->second.shared_memory, it->second.handle, &desc);
        if (s != WGPUStatus_Success) {
            dawn_log("iosurface_begin_access: status=%d", s);
            return false;
        }
        return true;
    }

    // EndAccess: signals to the IOSurface (and any consumer waiting on
    // it) that our Dawn writes are complete and the texture is ready
    // to read. Must be called AFTER the render pass + commit.
    bool iosurface_end_access(GPUTextureHandle handle) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(handle.id);
        if (it == textures_.end() || !it->second.shared_memory) return false;
        WGPUSharedTextureMemoryEndAccessState state = {};
        WGPUStatus s = wgpuSharedTextureMemoryEndAccess(
            it->second.shared_memory, it->second.handle, &state);
        if (s != WGPUStatus_Success) {
            dawn_log("iosurface_end_access: status=%d", s);
            wgpuSharedTextureMemoryEndAccessStateFreeMembers(state);
            return false;
        }
        // Free any signal fences Dawn allocated. We don't pass them
        // anywhere (the consumer is Flutter compositor reading the
        // IOSurface directly, which uses Apple's CVPixelBuffer-level
        // sync, not Dawn fences).
        wgpuSharedTextureMemoryEndAccessStateFreeMembers(state);
        return true;
    }

    std::vector<std::uint8_t> readback_texture(
        GPUTextureHandle handle,
        std::uint32_t width,
        std::uint32_t height,
        std::uint32_t bytes_per_pixel) noexcept override {
        if (!wgpu_device_ || !wgpu_queue_ || !wgpu_instance_) return {};
        if (width == 0 || height == 0 || bytes_per_pixel == 0) return {};

        // Look up texture; verify dims match caller's claim.
        WGPUTexture tex = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = textures_.find(handle.id);
            if (it == textures_.end()) return {};
            tex = it->second.handle;
            if (it->second.width != width || it->second.height != height) {
                dawn_log("readback_texture: dim mismatch: stored=(%u,%u) "
                         "requested=(%u,%u)", it->second.width,
                         it->second.height, width, height);
                return {};
            }
        }
        if (!tex) return {};

        // WebGPU requires copyTextureToBuffer rows be 256-byte aligned.
        // Pad each row, then unpad on read. This is the same logic as
        // the harness readback_texture (dawn_kernel_harness.cpp).
        constexpr std::uint32_t kRowAlign = 256;
        const std::uint32_t unpadded_bpr = width * bytes_per_pixel;
        const std::uint32_t padded_bpr =
            (unpadded_bpr + kRowAlign - 1) / kRowAlign * kRowAlign;
        const std::uint64_t padded_total =
            static_cast<std::uint64_t>(padded_bpr) * height;

        // Transient staging buffer (MapRead | CopyDst), released at end.
        WGPUBufferDescriptor staging_desc = WGPU_BUFFER_DESCRIPTOR_INIT;
        staging_desc.size = padded_total;
        staging_desc.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
        staging_desc.mappedAtCreation = WGPU_FALSE;
        WGPUBuffer staging = wgpuDeviceCreateBuffer(wgpu_device_, &staging_desc);
        if (!staging) {
            dawn_log("readback_texture: staging buffer create failed");
            return {};
        }

        // Encode + submit the texture→buffer copy, then wait.
        WGPUCommandEncoderDescriptor enc_desc = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
        WGPUCommandEncoder encoder =
            wgpuDeviceCreateCommandEncoder(wgpu_device_, &enc_desc);
        if (!encoder) {
            wgpuBufferRelease(staging);
            return {};
        }

        WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        src.texture = tex;
        src.mipLevel = 0;
        src.origin.x = 0; src.origin.y = 0; src.origin.z = 0;
        src.aspect = WGPUTextureAspect_All;

        WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
        dst.buffer = staging;
        dst.layout.offset = 0;
        dst.layout.bytesPerRow = padded_bpr;
        dst.layout.rowsPerImage = height;

        WGPUExtent3D extent{width, height, 1};
        wgpuCommandEncoderCopyTextureToBuffer(encoder, &src, &dst, &extent);

        WGPUCommandBufferDescriptor cb_desc = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
        WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(encoder, &cb_desc);
        wgpuCommandEncoderRelease(encoder);
        if (!cmd) {
            wgpuBufferRelease(staging);
            return {};
        }
        wgpuQueueSubmit(wgpu_queue_, 1, &cmd);
        wgpuCommandBufferRelease(cmd);

        // Wait for the copy to finish before mapping.
        QueueWorkDoneCallbackData q_state{};
        WGPUQueueWorkDoneCallbackInfo q_info = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
        q_info.mode = WGPUCallbackMode_WaitAnyOnly;
        q_info.callback = on_queue_work_done;
        q_info.userdata1 = &q_state;
        WGPUFuture q_fut = wgpuQueueOnSubmittedWorkDone(wgpu_queue_, q_info);
        WGPUFutureWaitInfo q_wait{q_fut, false};
        WGPUWaitStatus q_ws =
            wgpuInstanceWaitAny(wgpu_instance_, 1, &q_wait, UINT64_MAX);
        if (q_ws != WGPUWaitStatus_Success || !q_state.done) {
            dawn_log("readback_texture: copy WaitAny status=%d done=%d",
                     q_ws, q_state.done);
            wgpuBufferRelease(staging);
            return {};
        }

        // Map staging buffer.
        MapCallbackData m_state{};
        WGPUBufferMapCallbackInfo m_info = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
        m_info.mode = WGPUCallbackMode_WaitAnyOnly;
        m_info.callback = on_buffer_map;
        m_info.userdata1 = &m_state;
        WGPUFuture m_fut = wgpuBufferMapAsync(staging, WGPUMapMode_Read,
                                               0, padded_total, m_info);
        WGPUFutureWaitInfo m_wait{m_fut, false};
        constexpr std::uint64_t kSpinBudgetNs = 1'000'000'000ull;
        WGPUWaitStatus m_ws =
            wgpuInstanceWaitAny(wgpu_instance_, 1, &m_wait, kSpinBudgetNs);
        if (m_ws != WGPUWaitStatus_Success || !m_state.mapped) {
            dawn_log("readback_texture: MapAsync WaitAny status=%d mapped=%d",
                     m_ws, m_state.mapped);
            wgpuBufferRelease(staging);
            return {};
        }

        const std::uint8_t* mapped = static_cast<const std::uint8_t*>(
            wgpuBufferGetConstMappedRange(staging, 0, padded_total));
        if (!mapped) {
            wgpuBufferUnmap(staging);
            wgpuBufferRelease(staging);
            return {};
        }

        // Unpad rows: copy unpadded_bpr bytes per row, skip padding bytes.
        std::vector<std::uint8_t> tight(
            static_cast<std::size_t>(unpadded_bpr) * height);
        for (std::uint32_t y = 0; y < height; ++y) {
            std::memcpy(tight.data() + static_cast<std::size_t>(y) * unpadded_bpr,
                        mapped + static_cast<std::size_t>(y) * padded_bpr,
                        unpadded_bpr);
        }
        wgpuBufferUnmap(staging);
        wgpuBufferRelease(staging);
        return tight;
    }

    void update_texture(GPUTextureHandle handle, const void* data,
                        std::uint32_t width, std::uint32_t height,
                        std::uint32_t bytes_per_row) noexcept override {
        if (!data || width == 0 || height == 0) return;
        if (!wgpu_queue_) return;

        WGPUTexture tex = nullptr;
        std::size_t total_bytes = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = textures_.find(handle.id);
            if (it == textures_.end()) return;
            tex = it->second.handle;
            total_bytes = static_cast<std::size_t>(bytes_per_row) * height;
        }
        if (!tex) return;

        // wgpuQueueWriteTexture is the analog of update_buffer for
        // textures: zero-block enqueue through the queue's submission
        // timeline, no spin-wait. WebGPU requires bytesPerRow be a
        // multiple of 256; the caller provides it pre-aligned.
        WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        dst.texture = tex;
        dst.mipLevel = 0;
        dst.origin.x = 0; dst.origin.y = 0; dst.origin.z = 0;
        dst.aspect = WGPUTextureAspect_All;

        WGPUTexelCopyBufferLayout data_layout = WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT;
        data_layout.offset = 0;
        data_layout.bytesPerRow = bytes_per_row;
        data_layout.rowsPerImage = height;

        WGPUExtent3D write_size{width, height, 1};
        wgpuQueueWriteTexture(wgpu_queue_, &dst, data, total_bytes,
                              &data_layout, &write_size);
    }

    // Dawn-specific accessor for use by future RenderEncoder + readback.
    WGPUTexture get_texture(GPUTextureHandle handle) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(handle.id);
        return (it != textures_.end()) ? it->second.handle : nullptr;
    }
    WGPUBuffer get_buffer(GPUBufferHandle handle) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        return (it != buffers_.end()) ? it->second.handle : nullptr;
    }
    // For Step 9 readback_texture: needs dimensions to compute padded
    // bytes-per-row + total readback size. Returns false if invalid handle.
    bool get_texture_info(GPUTextureHandle handle,
                          std::uint32_t& out_w, std::uint32_t& out_h,
                          GPUTextureFormat& out_fmt) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(handle.id);
        if (it == textures_.end()) return false;
        out_w = it->second.width;
        out_h = it->second.height;
        out_fmt = it->second.format;
        return true;
    }

    // ─── Shader Management (Phase 6.2.G) ───
    //
    // Two-step model unique to Dawn (vs Metal's single .metallib lookup):
    //   1. register_wgsl(name, source, entry_point) — writes WGSL bytes
    //      + entry-point function name into the device-local registry,
    //      keyed by `name`.
    //   2. load_shader(name, stage) — looks up source + entry_point,
    //      compiles into a WGPUShaderModule, returns a GPUShaderHandle.
    //      Tint validation errors surface via the SetUncapturedErrorCallback
    //      abort path registered in init() — a malformed WGSL source
    //      aborts the process with the Tint diagnostic, NOT a silent
    //      zero handle.
    //
    // Multi-entry-point WGSL (e.g. splat_render.wgsl: vs_main + fs_main)
    // requires registering the same source twice under different names:
    //   register_wgsl_source(dev, "splat_render_vs", source, "vs_main");
    //   register_wgsl_source(dev, "splat_render_fs", source, "fs_main");
    //   auto vs = dev.load_shader("splat_render_vs", kVertex);
    //   auto fs = dev.load_shader("splat_render_fs", kFragment);

    void register_wgsl(const char* name,
                       std::string_view wgsl_source,
                       const char* entry_point) noexcept {
        if (!name || !entry_point) return;
        std::lock_guard<std::mutex> lock(mutex_);
        WgslEntry entry;
        entry.source = std::string(wgsl_source);
        entry.entry_point = entry_point;
        wgsl_sources_[name] = std::move(entry);
    }

    GPUShaderHandle load_shader(const char* name,
                                GPUShaderStage stage) noexcept override {
        if (!wgpu_device_ || !name) return GPUShaderHandle{0};

        std::string source_copy;
        std::string entry_point_copy;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = wgsl_sources_.find(name);
            if (it == wgsl_sources_.end()) {
                dawn_log("load_shader: name '%s' not found in WGSL registry "
                         "— call register_wgsl_source() first", name);
                return GPUShaderHandle{0};
            }
            source_copy = it->second.source;
            entry_point_copy = it->second.entry_point;
        }

        // WGSL source descriptor (chained struct on ShaderModuleDescriptor).
        WGPUShaderSourceWGSL wgsl_src = WGPU_SHADER_SOURCE_WGSL_INIT;
        wgsl_src.code.data = source_copy.data();
        wgsl_src.code.length = source_copy.size();

        WGPUShaderModuleDescriptor mod_desc = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
        mod_desc.nextInChain = &wgsl_src.chain;
        mod_desc.label.data = name;
        mod_desc.label.length = WGPU_STRLEN;

        WGPUShaderModule module =
            wgpuDeviceCreateShaderModule(wgpu_device_, &mod_desc);
        if (!module) {
            // Malformed WGSL would have aborted via uncaptured-error
            // callback; reaching here means some other failure (OOM
            // creating the module). Log and bail.
            dawn_log("load_shader: wgpuDeviceCreateShaderModule returned NULL "
                     "for name='%s'", name);
            return GPUShaderHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        DawnShader entry{};
        entry.module = module;
        entry.stage = stage;
        entry.entry_point = std::move(entry_point_copy);
        shaders_.emplace(handle_id, std::move(entry));
        return GPUShaderHandle{handle_id};
    }

    void destroy_shader(GPUShaderHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = shaders_.find(handle.id);
        if (it == shaders_.end()) return;
        if (it->second.module) {
            wgpuShaderModuleRelease(it->second.module);
        }
        shaders_.erase(it);
    }

    // Dawn-specific accessor for pipeline creation (Step 3 + Step 4).
    // Returns nullptr if handle invalid. Caller does NOT take ownership;
    // the WGPUShaderModule is released when destroy_shader is called.
    WGPUShaderModule get_shader_module(GPUShaderHandle handle,
                                        std::string& out_entry_point) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = shaders_.find(handle.id);
        if (it == shaders_.end()) return nullptr;
        out_entry_point = it->second.entry_point;
        return it->second.module;
    }

    // ─── Pipeline Management (Phase 6.2.I + 6.2.J) ───

    GPURenderPipelineHandle create_render_pipeline(
        GPUShaderHandle vertex_shader,
        GPUShaderHandle fragment_shader,
        const GPURenderTargetDesc& target_desc) noexcept override {
        if (!wgpu_device_) return GPURenderPipelineHandle{0};

        std::string vs_entry, fs_entry;
        WGPUShaderModule vs_module = get_shader_module(vertex_shader, vs_entry);
        WGPUShaderModule fs_module = get_shader_module(fragment_shader, fs_entry);
        if (!vs_module || !fs_module) {
            dawn_log("create_render_pipeline: invalid shader handle "
                     "vs=%u fs=%u", vertex_shader.id, fragment_shader.id);
            return GPURenderPipelineHandle{0};
        }

        // ─── Color targets ────────────────────────────────────────────
        // Walk attachments. Mirror MetalGPUDevice's legacy fallback:
        // attachment 0 with default RGBA8Unorm format inherits the
        // `target_desc.color_format` + `target_desc.blending_enabled`
        // legacy fields. Premultiplied-alpha blend (One/OneMinusSrcAlpha)
        // is the default when blending_enabled is true — same convention
        // as the harness load_render_pipeline.
        const std::uint32_t attachment_count =
            std::min<std::uint32_t>(
                std::max<std::uint32_t>(target_desc.color_attachment_count, 1),
                kMaxColorAttachments);

        WGPUColorTargetState color_targets[kMaxColorAttachments] = {};
        WGPUBlendState blend_states[kMaxColorAttachments] = {};

        for (std::uint32_t i = 0; i < attachment_count; ++i) {
            GPUColorAttachmentTargetDesc attachment = target_desc.color_attachments[i];
            if (i == 0 && attachment.format == GPUTextureFormat::kRGBA8Unorm) {
                attachment.format = target_desc.color_format;
                attachment.blend.blending_enabled = target_desc.blending_enabled;
                if (target_desc.blending_enabled) {
                    // Premultiplied-alpha blend (matches splat_render.wgsl's
                    // (rgb*α, α) fragment output contract).
                    attachment.blend.rgb_blend_op = GPUBlendOperation::kAdd;
                    attachment.blend.alpha_blend_op = GPUBlendOperation::kAdd;
                    attachment.blend.source_rgb_blend = GPUBlendFactor::kOne;
                    attachment.blend.destination_rgb_blend =
                        GPUBlendFactor::kOneMinusSourceAlpha;
                    attachment.blend.source_alpha_blend = GPUBlendFactor::kOne;
                    attachment.blend.destination_alpha_blend =
                        GPUBlendFactor::kOneMinusSourceAlpha;
                }
            }

            WGPUColorTargetState& tgt = color_targets[i];
            tgt = WGPU_COLOR_TARGET_STATE_INIT;
            tgt.format = map_texture_format(attachment.format);
            tgt.writeMask = WGPUColorWriteMask_All;
            if (attachment.blend.blending_enabled) {
                blend_states[i].color.operation = map_blend_op(attachment.blend.rgb_blend_op);
                blend_states[i].color.srcFactor  = map_blend_factor(attachment.blend.source_rgb_blend);
                blend_states[i].color.dstFactor  = map_blend_factor(attachment.blend.destination_rgb_blend);
                blend_states[i].alpha.operation = map_blend_op(attachment.blend.alpha_blend_op);
                blend_states[i].alpha.srcFactor  = map_blend_factor(attachment.blend.source_alpha_blend);
                blend_states[i].alpha.dstFactor  = map_blend_factor(attachment.blend.destination_alpha_blend);
                tgt.blend = &blend_states[i];
            }
        }

        // ─── Fragment state ───────────────────────────────────────────
        WGPUFragmentState fragment = WGPU_FRAGMENT_STATE_INIT;
        fragment.module = fs_module;
        fragment.entryPoint.data = fs_entry.data();
        fragment.entryPoint.length = fs_entry.size();
        fragment.targetCount = attachment_count;
        fragment.targets = color_targets;

        // ─── Vertex state ─────────────────────────────────────────────
        // Instanced quads pull all data from storage buffers via
        // vertex_index + instance_index — no vertex buffer attribs.
        WGPUVertexState vertex = WGPU_VERTEX_STATE_INIT;
        vertex.module = vs_module;
        vertex.entryPoint.data = vs_entry.data();
        vertex.entryPoint.length = vs_entry.size();
        vertex.bufferCount = 0;
        vertex.buffers = nullptr;

        // ─── Pipeline descriptor ──────────────────────────────────────
        WGPURenderPipelineDescriptor pipeline_desc =
            WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
        pipeline_desc.vertex = vertex;
        pipeline_desc.fragment = &fragment;
        pipeline_desc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
        pipeline_desc.primitive.cullMode = WGPUCullMode_None;
        pipeline_desc.primitive.frontFace = WGPUFrontFace_CCW;
        pipeline_desc.multisample.count =
            target_desc.sample_count > 0 ? target_desc.sample_count : 1;
        pipeline_desc.multisample.mask = 0xFFFFFFFFu;

        // Depth-stencil only when the caller asked for it.
        WGPUDepthStencilState depth_stencil = WGPU_DEPTH_STENCIL_STATE_INIT;
        if ((target_desc.depth_test_enabled || target_desc.depth_write_enabled) &&
            target_desc.depth_format != GPUTextureFormat::kInvalid) {
            depth_stencil.format = map_texture_format(target_desc.depth_format);
            depth_stencil.depthWriteEnabled = target_desc.depth_write_enabled
                ? WGPUOptionalBool_True : WGPUOptionalBool_False;
            // Compare function. WGPU defaults map cleanly.
            switch (target_desc.depth_compare) {
                case GPUCompareFunction::kAlways:
                    depth_stencil.depthCompare = WGPUCompareFunction_Always; break;
                case GPUCompareFunction::kLess:
                    depth_stencil.depthCompare = WGPUCompareFunction_Less; break;
                case GPUCompareFunction::kLessEqual:
                    depth_stencil.depthCompare = WGPUCompareFunction_LessEqual; break;
                case GPUCompareFunction::kGreater:
                    depth_stencil.depthCompare = WGPUCompareFunction_Greater; break;
                case GPUCompareFunction::kGreaterEqual:
                    depth_stencil.depthCompare = WGPUCompareFunction_GreaterEqual; break;
            }
            pipeline_desc.depthStencil = &depth_stencil;
        }

        WGPURenderPipeline pipeline =
            wgpuDeviceCreateRenderPipeline(wgpu_device_, &pipeline_desc);
        if (!pipeline) {
            dawn_log("create_render_pipeline: returned NULL");
            return GPURenderPipelineHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        render_pipelines_[handle_id] = pipeline;
        return GPURenderPipelineHandle{handle_id};
    }

    void destroy_render_pipeline(GPURenderPipelineHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = render_pipelines_.find(handle.id);
        if (it == render_pipelines_.end()) return;
        if (it->second) wgpuRenderPipelineRelease(it->second);
        render_pipelines_.erase(it);
    }

    // Dawn-specific accessor for use by future DawnRenderEncoder.
    WGPURenderPipeline get_render_pipeline(GPURenderPipelineHandle handle) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = render_pipelines_.find(handle.id);
        return (it != render_pipelines_.end()) ? it->second : nullptr;
    }

    GPUComputePipelineHandle create_compute_pipeline(
        GPUShaderHandle compute_shader) noexcept override {
        if (!wgpu_device_) return GPUComputePipelineHandle{0};

        std::string entry_point;
        WGPUShaderModule module = get_shader_module(compute_shader, entry_point);
        if (!module) {
            dawn_log("create_compute_pipeline: invalid shader handle %u",
                     compute_shader.id);
            return GPUComputePipelineHandle{0};
        }

        WGPUComputePipelineDescriptor desc = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
        // layout = nullptr → auto layout (Dawn infers bind group layout
        // from WGSL @binding decls, exactly the harness convention).
        desc.compute.module = module;
        desc.compute.entryPoint.data = entry_point.data();
        desc.compute.entryPoint.length = entry_point.size();

        WGPUComputePipeline pipeline =
            wgpuDeviceCreateComputePipeline(wgpu_device_, &desc);
        if (!pipeline) {
            dawn_log("create_compute_pipeline: returned NULL");
            return GPUComputePipelineHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        compute_pipelines_[handle_id] = pipeline;
        return GPUComputePipelineHandle{handle_id};
    }

    void destroy_compute_pipeline(GPUComputePipelineHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = compute_pipelines_.find(handle.id);
        if (it == compute_pipelines_.end()) return;
        if (it->second) wgpuComputePipelineRelease(it->second);
        compute_pipelines_.erase(it);
    }

    // Dawn-specific accessor for use by future DawnComputeEncoder.
    WGPUComputePipeline get_compute_pipeline(GPUComputePipelineHandle handle) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = compute_pipelines_.find(handle.id);
        return (it != compute_pipelines_.end()) ? it->second : nullptr;
    }

    // ─── Command Buffer (Phase 6.2.J + 6.2.K) ───

    // Defined after DawnCommandBuffer (forward declaration handled by
    // class deferred-method parsing in C++17).
    std::unique_ptr<GPUCommandBuffer> create_command_buffer() noexcept override;

    // ─── Synchronization ───

    void wait_idle() noexcept override {
        if (!wgpu_queue_ || !wgpu_instance_) return;
        QueueWorkDoneCallbackData cb_state{};
        WGPUQueueWorkDoneCallbackInfo cb_info = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
        cb_info.mode = WGPUCallbackMode_WaitAnyOnly;
        cb_info.callback = on_queue_work_done;
        cb_info.userdata1 = &cb_state;
        WGPUFuture fut = wgpuQueueOnSubmittedWorkDone(wgpu_queue_, cb_info);
        WGPUFutureWaitInfo wait{};
        wait.future = fut;
        wait.completed = false;
        WGPUWaitStatus ws =
            wgpuInstanceWaitAny(wgpu_instance_, 1, &wait, UINT64_MAX);
        if (ws != WGPUWaitStatus_Success || !cb_state.done) {
            dawn_log("wait_idle: WaitAny status=%d done=%d", ws, cb_state.done);
        }
    }

    // ─── Telemetry accessors ───────────────────────────────────────────

    /// Total number of map_buffer calls that took the spin-wait path
    /// since device creation. Surfaced so tests / profilers can assert
    /// the hot-path stays at zero. Not part of GPUDevice virtual API
    /// — DawnGPUDevice-specific accessor.
    std::uint64_t spin_wait_count() const noexcept {
        return spin_wait_count_.load(std::memory_order_relaxed);
    }

    /// True if the device was created with WGPUFeatureName_Subgroups.
    /// Required by Brush rasterize_backwards.wgsl. Caller MUST check
    /// before loading that kernel; if false, fall back to cloud-trained
    /// pipelines per the Phase 6.3 v3 device matrix.
    bool supports_subgroups() const noexcept { return supports_subgroups_; }

    /// True if the device was created with
    /// WGPUFeatureName_SharedTextureMemoryIOSurface (Apple platforms).
    /// Required by the PocketWorld Flutter Texture bridge for zero-copy
    /// display. False on non-Apple adapters (Vulkan/D3D12 use platform-
    /// specific equivalents — DXGI shared handle / EGLImage).
    bool supports_iosurface() const noexcept { return supports_iosurface_; }

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

    // Optional-feature availability. False = adapter rejected the
    // feature at device-request time, fallback path was taken.
    bool supports_subgroups_{false};
    bool supports_iosurface_{false};

    mutable std::mutex mutex_;
    std::uint32_t next_id_{0};

    // Resource maps. Buffers populated by 6.2.F. Shaders by 6.2.G Step 2.
    // Compute pipelines by Step 3.
    std::unordered_map<std::uint32_t, DawnBuffer> buffers_;
    std::unordered_map<std::uint32_t, DawnShader> shaders_;                  // 6.2.G Step 2
    std::unordered_map<std::uint32_t, WGPUComputePipeline> compute_pipelines_;  // 6.2.G Step 3
    std::unordered_map<std::uint32_t, WGPURenderPipeline> render_pipelines_;    // 6.2.G Step 4
    std::unordered_map<std::uint32_t, DawnTexture> textures_;                // 6.2.I Step 5

    // WGSL source registry: name → {source, entry_point}. Populated by
    // callers via register_wgsl_source() free function. Read-only after
    // registration for the lifetime of the device (sources don't leave
    // once added).
    std::unordered_map<std::string, WgslEntry> wgsl_sources_;

    // Memory tracking
    std::size_t allocated_bytes_{0};
    std::size_t peak_bytes_{0};

    // Telemetry: total spin-wait-path map_buffer calls. Atomic so the
    // accessor + increment don't race; relaxed ordering is fine because
    // the value is only ever read for diagnostic purposes.
    std::atomic<std::uint64_t> spin_wait_count_{0};

    // Device-level warn-once flags
    std::atomic<bool> warned_map_write_discouraged_{false};

    // Stub-fired flags for methods 6.2.J-K still owe.
    std::atomic<bool> stub_create_buffer_{false};
    std::atomic<bool> stub_create_command_buffer_{false};
};

// ═══════════════════════════════════════════════════════════════════════
// DawnComputeEncoder (Phase 6.2.J)
// ═══════════════════════════════════════════════════════════════════════
//
// Records SetPipeline / SetBindGroup / DispatchWorkgroups onto a
// WGPUComputePassEncoder. The bind-group construction matches the
// harness pattern: bindings are collected by index (set_buffer index
// → @binding(N) in WGSL), bind group is built fresh per dispatch from
// the pipeline's auto-generated layout (pipeline.GetBindGroupLayout(0)).
//
// Threads-per-workgroup is INFORMATION ALREADY IN WGSL (@workgroup_size
// decoration), so the threads_x/y/z arguments in the GPUComputeEncoder
// virtual API are IGNORED on Dawn. This is the deliberate Metal/Dawn
// API mismatch — Metal's two-arg dispatch is fully encoded, while
// WGSL bakes the workgroup size into the shader.

class DawnComputeEncoder final : public GPUComputeEncoder {
public:
    DawnComputeEncoder(WGPUComputePassEncoder pass, DawnGPUDevice& dev) noexcept
        : pass_(pass), device_(dev) {}

    ~DawnComputeEncoder() override {
        // Safety net: if end_encoding() was missed, end + release here.
        if (pass_) {
            wgpuComputePassEncoderEnd(pass_);
            wgpuComputePassEncoderRelease(pass_);
        }
        // Bind groups must outlive the pass; release after the pass ends.
        for (WGPUBindGroup bg : bind_groups_) {
            if (bg) wgpuBindGroupRelease(bg);
        }
    }

    void set_pipeline(GPUComputePipelineHandle pipeline) noexcept override {
        WGPUComputePipeline p = device_.get_compute_pipeline(pipeline);
        if (!p) {
            dawn_log("DawnComputeEncoder::set_pipeline: invalid handle %u",
                     pipeline.id);
            return;
        }
        wgpuComputePassEncoderSetPipeline(pass_, p);
        current_pipeline_ = p;
    }

    void set_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                    std::uint32_t index) noexcept override {
        WGPUBuffer buf = device_.get_buffer(buffer);
        if (!buf) {
            dawn_log("DawnComputeEncoder::set_buffer: invalid handle %u",
                     buffer.id);
            return;
        }
        if (index >= bindings_.size()) {
            bindings_.resize(index + 1);
        }
        bindings_[index].buffer = buf;
        bindings_[index].offset = offset;
    }

    void set_texture(GPUTextureHandle /*texture*/,
                     std::uint32_t /*index*/) noexcept override {
        // Phase 6.4 wires this when compute kernels read sampled textures
        // (none of the 14 Brush kernels do today). For now log and skip;
        // a silent skip would leave the binding unfilled and Dawn would
        // abort via uncaptured-error on the next dispatch — that's fine.
        warn_once(warned_set_texture_, "DawnComputeEncoder::set_texture",
                  "compute texture binding not yet implemented (no Brush "
                  "kernel uses it as of Phase 6.3a)");
    }

    void set_bytes(const void* /*data*/, std::uint32_t /*size*/,
                   std::uint32_t /*index*/) noexcept override {
        // Metal-style inline-bytes has no WGPU equivalent. Phase 7 if a
        // caller needs this, allocate a transient kUniform buffer +
        // queueWriteBuffer + bind it here. For Phase 6 nobody uses it.
        warn_once(warned_set_bytes_, "DawnComputeEncoder::set_bytes",
                  "WebGPU has no inline-bytes path; use update_buffer + "
                  "set_buffer with a kUniform-flagged buffer instead");
    }

    void dispatch(std::uint32_t groups_x, std::uint32_t groups_y,
                  std::uint32_t groups_z,
                  std::uint32_t /*threads_x*/, std::uint32_t /*threads_y*/,
                  std::uint32_t /*threads_z*/) noexcept override {
        // threads_xyz unused on Dawn — WGSL @workgroup_size encodes them.
        if (!current_pipeline_ || !pass_) return;

        // Build a fresh bind group from the bindings_ vector.
        std::vector<WGPUBindGroupEntry> entries(bindings_.size());
        std::size_t valid_count = 0;
        for (std::size_t i = 0; i < bindings_.size(); ++i) {
            if (!bindings_[i].buffer) continue;
            entries[valid_count] = WGPU_BIND_GROUP_ENTRY_INIT;
            entries[valid_count].binding = static_cast<std::uint32_t>(i);
            entries[valid_count].buffer = bindings_[i].buffer;
            entries[valid_count].offset = bindings_[i].offset;
            entries[valid_count].size = WGPU_WHOLE_SIZE;
            ++valid_count;
        }

        WGPUBindGroupLayout layout =
            wgpuComputePipelineGetBindGroupLayout(current_pipeline_, 0);
        if (!layout) {
            dawn_log("DawnComputeEncoder::dispatch: GetBindGroupLayout NULL");
            return;
        }

        WGPUBindGroupDescriptor bg_desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg_desc.layout = layout;
        bg_desc.entryCount = valid_count;
        bg_desc.entries = entries.data();
        WGPUBindGroup bind_group =
            wgpuDeviceCreateBindGroup(device_.wgpu_device(), &bg_desc);
        wgpuBindGroupLayoutRelease(layout);
        if (!bind_group) {
            dawn_log("DawnComputeEncoder::dispatch: CreateBindGroup NULL");
            return;
        }
        // Bind group must remain valid through the pass; release in dtor.
        bind_groups_.push_back(bind_group);

        wgpuComputePassEncoderSetBindGroup(pass_, 0, bind_group,
                                           /*dynamicOffsetCount=*/0,
                                           /*dynamicOffsets=*/nullptr);
        wgpuComputePassEncoderDispatchWorkgroups(pass_, groups_x, groups_y, groups_z);
    }

    void end_encoding() noexcept override {
        if (pass_) {
            wgpuComputePassEncoderEnd(pass_);
            wgpuComputePassEncoderRelease(pass_);
            pass_ = nullptr;
        }
    }

private:
    WGPUComputePassEncoder pass_;
    DawnGPUDevice& device_;
    WGPUComputePipeline current_pipeline_{nullptr};

    struct BufBind { WGPUBuffer buffer{nullptr}; std::uint64_t offset{0}; };
    std::vector<BufBind> bindings_;
    std::vector<WGPUBindGroup> bind_groups_;  // alive until dtor

    std::atomic<bool> warned_set_texture_{false};
    std::atomic<bool> warned_set_bytes_{false};
};

// ═══════════════════════════════════════════════════════════════════════
// DawnRenderEncoder (Phase 6.2.K)
// ═══════════════════════════════════════════════════════════════════════
//
// Same pattern as DawnComputeEncoder but for render passes. Vertex-buffer
// bindings (set_vertex_buffer) and fragment-buffer bindings
// (set_fragment_buffer) BOTH translate to the same WGPU @group(0)
// bind group — WGSL has no vertex-vs-fragment binding namespace, all
// stages share the layout. We accept them through both methods to
// match the GPURenderEncoder virtual API but route them through the
// same indexed bindings_ array.
//
// The harness uses vertex_count + instance_count; our virtual encoder
// has draw_instanced(type, vertex_count, instance_count) which
// translates to wgpuRenderPassEncoderDraw with explicit instance count.

class DawnRenderEncoder final : public GPURenderEncoder {
public:
    DawnRenderEncoder(WGPURenderPassEncoder pass, DawnGPUDevice& dev) noexcept
        : pass_(pass), device_(dev) {}

    ~DawnRenderEncoder() override {
        if (pass_) {
            wgpuRenderPassEncoderEnd(pass_);
            wgpuRenderPassEncoderRelease(pass_);
        }
        for (WGPUBindGroup bg : bind_groups_) {
            if (bg) wgpuBindGroupRelease(bg);
        }
    }

    void set_pipeline(GPURenderPipelineHandle pipeline) noexcept override {
        WGPURenderPipeline p = device_.get_render_pipeline(pipeline);
        if (!p) {
            dawn_log("DawnRenderEncoder::set_pipeline: invalid handle %u",
                     pipeline.id);
            return;
        }
        wgpuRenderPassEncoderSetPipeline(pass_, p);
        current_pipeline_ = p;
    }

    void set_vertex_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                           std::uint32_t index) noexcept override {
        // Both vertex_buffer and fragment_buffer route into the shared
        // @group(0) bind group. WGSL has no per-stage binding namespace;
        // we collect by `index` and let the bind-group layout resolve.
        bind_buffer_at_(buffer, offset, index);
    }

    void set_fragment_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                             std::uint32_t index) noexcept override {
        bind_buffer_at_(buffer, offset, index);
    }

    void set_vertex_bytes(const void*, std::uint32_t, std::uint32_t) noexcept override {
        warn_once(warned_set_bytes_, "DawnRenderEncoder::set_vertex_bytes",
                  "WebGPU has no inline-bytes path");
    }
    void set_fragment_bytes(const void*, std::uint32_t, std::uint32_t) noexcept override {
        warn_once(warned_set_bytes_, "DawnRenderEncoder::set_fragment_bytes",
                  "WebGPU has no inline-bytes path");
    }
    void set_vertex_texture(GPUTextureHandle, std::uint32_t) noexcept override {
        warn_once(warned_set_texture_, "DawnRenderEncoder::set_vertex_texture",
                  "render-stage texture binding not yet wired (Phase 6.4)");
    }
    void set_fragment_texture(GPUTextureHandle, std::uint32_t) noexcept override {
        warn_once(warned_set_texture_, "DawnRenderEncoder::set_fragment_texture",
                  "render-stage texture binding not yet wired (Phase 6.4)");
    }

    void set_viewport(const GPUViewport& vp) noexcept override {
        wgpuRenderPassEncoderSetViewport(pass_, vp.origin_x, vp.origin_y,
                                          vp.width, vp.height,
                                          vp.near_depth, vp.far_depth);
    }
    void set_scissor(const GPUScissorRect& r) noexcept override {
        wgpuRenderPassEncoderSetScissorRect(pass_, r.x, r.y, r.width, r.height);
    }
    void set_cull_mode(GPUCullMode /*mode*/) noexcept override {
        // WebGPU bakes cull mode into the pipeline (PrimitiveState),
        // unlike Metal's per-encoder setting. No-op here; pipeline
        // already carries the cull setting. If an app needs to flip
        // cull mid-pass, it must use a different pipeline.
    }
    void set_winding(GPUWindingOrder /*order*/) noexcept override {
        // Same: WebGPU bakes front-face winding into the pipeline.
    }

    void draw(GPUPrimitiveType /*type*/, std::uint32_t vertex_start,
              std::uint32_t vertex_count) noexcept override {
        // type is baked into pipeline (see set_cull_mode comment).
        if (!apply_bind_group_()) return;
        wgpuRenderPassEncoderDraw(pass_, vertex_count, /*instanceCount=*/1,
                                   vertex_start, /*firstInstance=*/0);
    }
    void draw_indexed(GPUPrimitiveType /*type*/, std::uint32_t /*index_count*/,
                      GPUBufferHandle /*index_buffer*/,
                      std::uint32_t /*index_offset*/) noexcept override {
        warn_once(warned_draw_indexed_, "DawnRenderEncoder::draw_indexed",
                  "indexed draws not used by splat_render; not yet wired");
    }
    void draw_instanced(GPUPrimitiveType /*type*/, std::uint32_t vertex_count,
                        std::uint32_t instance_count) noexcept override {
        if (!apply_bind_group_()) return;
        wgpuRenderPassEncoderDraw(pass_, vertex_count, instance_count,
                                   /*firstVertex=*/0, /*firstInstance=*/0);
    }

    void end_encoding() noexcept override {
        if (pass_) {
            wgpuRenderPassEncoderEnd(pass_);
            wgpuRenderPassEncoderRelease(pass_);
            pass_ = nullptr;
        }
    }

private:
    void bind_buffer_at_(GPUBufferHandle buffer, std::uint32_t offset,
                         std::uint32_t index) noexcept {
        WGPUBuffer buf = device_.get_buffer(buffer);
        if (!buf) {
            dawn_log("DawnRenderEncoder::bind_buffer: invalid handle %u",
                     buffer.id);
            return;
        }
        if (index >= bindings_.size()) bindings_.resize(index + 1);
        bindings_[index].buffer = buf;
        bindings_[index].offset = offset;
    }

    bool apply_bind_group_() noexcept {
        if (!current_pipeline_) return false;

        std::vector<WGPUBindGroupEntry> entries(bindings_.size());
        std::size_t valid_count = 0;
        for (std::size_t i = 0; i < bindings_.size(); ++i) {
            if (!bindings_[i].buffer) continue;
            entries[valid_count] = WGPU_BIND_GROUP_ENTRY_INIT;
            entries[valid_count].binding = static_cast<std::uint32_t>(i);
            entries[valid_count].buffer = bindings_[i].buffer;
            entries[valid_count].offset = bindings_[i].offset;
            entries[valid_count].size = WGPU_WHOLE_SIZE;
            ++valid_count;
        }
        WGPUBindGroupLayout layout =
            wgpuRenderPipelineGetBindGroupLayout(current_pipeline_, 0);
        if (!layout) return false;

        WGPUBindGroupDescriptor bg_desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
        bg_desc.layout = layout;
        bg_desc.entryCount = valid_count;
        bg_desc.entries = entries.data();
        WGPUBindGroup bg = wgpuDeviceCreateBindGroup(device_.wgpu_device(), &bg_desc);
        wgpuBindGroupLayoutRelease(layout);
        if (!bg) return false;
        bind_groups_.push_back(bg);
        wgpuRenderPassEncoderSetBindGroup(pass_, 0, bg, 0, nullptr);
        return true;
    }

    WGPURenderPassEncoder pass_;
    DawnGPUDevice& device_;
    WGPURenderPipeline current_pipeline_{nullptr};

    struct BufBind { WGPUBuffer buffer{nullptr}; std::uint64_t offset{0}; };
    std::vector<BufBind> bindings_;
    std::vector<WGPUBindGroup> bind_groups_;

    std::atomic<bool> warned_set_texture_{false};
    std::atomic<bool> warned_set_bytes_{false};
    std::atomic<bool> warned_draw_indexed_{false};
};

// ═══════════════════════════════════════════════════════════════════════
// DawnCommandBuffer (Phase 6.2.J + 6.2.K)
// ═══════════════════════════════════════════════════════════════════════
//
// Owns one WGPUCommandEncoder; spawns one compute or render encoder at
// a time. commit() calls Finish + Submit; wait_until_completed uses
// OnSubmittedWorkDone + WaitAny — same sync bridge as the rest of the
// device.

class DawnCommandBuffer final : public GPUCommandBuffer {
public:
    explicit DawnCommandBuffer(DawnGPUDevice& dev) noexcept : device_(dev) {
        WGPUCommandEncoderDescriptor desc = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
        encoder_ = wgpuDeviceCreateCommandEncoder(device_.wgpu_device(), &desc);
        if (!encoder_) {
            dawn_log("DawnCommandBuffer: CreateCommandEncoder NULL");
        }
    }

    ~DawnCommandBuffer() override {
        // Encoders must be destroyed before the parent command encoder
        // is released (they hold raw refs into the encoder).
        compute_encoder_.reset();
        render_encoder_.reset();
        if (encoder_) wgpuCommandEncoderRelease(encoder_);
        if (cmd_buffer_) wgpuCommandBufferRelease(cmd_buffer_);
    }

    GPUComputeEncoder* make_compute_encoder() noexcept override {
        if (!encoder_) return nullptr;
        WGPUComputePassDescriptor desc = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
        WGPUComputePassEncoder pass =
            wgpuCommandEncoderBeginComputePass(encoder_, &desc);
        if (!pass) {
            dawn_log("make_compute_encoder: BeginComputePass NULL");
            return nullptr;
        }
        compute_encoder_ = std::make_unique<DawnComputeEncoder>(pass, device_);
        return compute_encoder_.get();
    }

    GPURenderEncoder* make_render_encoder(
        const GPURenderTargetDesc& /*target*/) noexcept override {
        // Legacy MetalGPUDevice path creates an offscreen texture inside
        // the encoder. We force callers to provide an explicit texture
        // via make_render_encoder(GPURenderPassDesc) instead — that
        // path is the one Phase 6.4 IOSurface bridge uses and it keeps
        // ownership of the target with the caller.
        warn_once(warned_target_desc_overload_,
                  "DawnCommandBuffer::make_render_encoder(GPURenderTargetDesc)",
                  "use make_render_encoder(GPURenderPassDesc) with an "
                  "explicit texture handle on Dawn (matches Phase 6.4 "
                  "IOSurface render-target ownership model)");
        return nullptr;
    }

    GPURenderEncoder* make_render_encoder(
        const GPURenderPassDesc& pass_desc) noexcept override {
        if (!encoder_) return nullptr;
        const std::uint32_t attach_count =
            std::min<std::uint32_t>(
                std::max<std::uint32_t>(pass_desc.color_attachment_count, 1),
                kMaxColorAttachments);

        // Build per-attachment color descriptors. Each needs a TextureView
        // created on the fly — released when the pass ends.
        WGPURenderPassColorAttachment color_attaches[kMaxColorAttachments] = {};
        WGPUTextureView color_views[kMaxColorAttachments] = {};

        for (std::uint32_t i = 0; i < attach_count; ++i) {
            WGPUTexture tex = device_.get_texture(pass_desc.color_attachments[i].texture);
            if (!tex) {
                dawn_log("make_render_encoder: invalid texture handle for "
                         "color attachment %u", i);
                // Release any views we already created.
                for (std::uint32_t j = 0; j < i; ++j) {
                    if (color_views[j]) wgpuTextureViewRelease(color_views[j]);
                }
                return nullptr;
            }
            WGPUTextureViewDescriptor view_desc = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
            color_views[i] = wgpuTextureCreateView(tex, &view_desc);

            color_attaches[i] = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
            color_attaches[i].view = color_views[i];
            const auto& a = pass_desc.color_attachments[i];
            color_attaches[i].loadOp =
                (a.load == GPULoadAction::kClear)    ? WGPULoadOp_Clear :
                (a.load == GPULoadAction::kLoad)     ? WGPULoadOp_Load :
                                                       WGPULoadOp_Undefined;
            color_attaches[i].storeOp =
                (a.store == GPUStoreAction::kStore) ? WGPUStoreOp_Store :
                                                      WGPUStoreOp_Discard;
            color_attaches[i].clearValue.r = a.clear_color[0];
            color_attaches[i].clearValue.g = a.clear_color[1];
            color_attaches[i].clearValue.b = a.clear_color[2];
            color_attaches[i].clearValue.a = a.clear_color[3];
            color_attaches[i].depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        }

        WGPURenderPassDescriptor rp_desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
        rp_desc.colorAttachmentCount = attach_count;
        rp_desc.colorAttachments = color_attaches;

        // Depth attachment — only if the caller provided a valid texture.
        WGPURenderPassDepthStencilAttachment depth_attach =
            WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
        WGPUTextureView depth_view = nullptr;
        if (pass_desc.depth_attachment.texture.valid()) {
            WGPUTexture dtex = device_.get_texture(pass_desc.depth_attachment.texture);
            if (dtex) {
                WGPUTextureViewDescriptor d_view_desc = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
                depth_view = wgpuTextureCreateView(dtex, &d_view_desc);
                depth_attach.view = depth_view;
                depth_attach.depthLoadOp =
                    (pass_desc.depth_attachment.load == GPULoadAction::kClear)
                        ? WGPULoadOp_Clear : WGPULoadOp_Load;
                depth_attach.depthStoreOp =
                    (pass_desc.depth_attachment.store == GPUStoreAction::kStore)
                        ? WGPUStoreOp_Store : WGPUStoreOp_Discard;
                depth_attach.depthClearValue = pass_desc.depth_attachment.clear_depth;
                rp_desc.depthStencilAttachment = &depth_attach;
            }
        }

        WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(encoder_, &rp_desc);

        // Texture views are referenced by the pass; we can release the
        // local handles immediately (Dawn ref-counts internally).
        for (std::uint32_t i = 0; i < attach_count; ++i) {
            if (color_views[i]) wgpuTextureViewRelease(color_views[i]);
        }
        if (depth_view) wgpuTextureViewRelease(depth_view);

        if (!pass) {
            dawn_log("make_render_encoder: BeginRenderPass NULL");
            return nullptr;
        }
        render_encoder_ = std::make_unique<DawnRenderEncoder>(pass, device_);
        return render_encoder_.get();
    }

    void commit() noexcept override {
        if (committed_ || !encoder_) return;
        // Make sure any active encoder ended before we finish the
        // command encoder. Defensive — caller SHOULD have called
        // end_encoding(), but a missed call would otherwise hang.
        if (compute_encoder_) compute_encoder_->end_encoding();
        if (render_encoder_)  render_encoder_->end_encoding();

        WGPUCommandBufferDescriptor cb_desc = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
        cmd_buffer_ = wgpuCommandEncoderFinish(encoder_, &cb_desc);
        if (cmd_buffer_) {
            wgpuQueueSubmit(device_.wgpu_queue(), 1, &cmd_buffer_);
        } else {
            dawn_log("DawnCommandBuffer::commit: CommandEncoderFinish NULL");
        }
        committed_ = true;
    }

    void wait_until_completed() noexcept override {
        if (!committed_) return;
        QueueWorkDoneCallbackData cb_state{};
        WGPUQueueWorkDoneCallbackInfo cb_info = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
        cb_info.mode = WGPUCallbackMode_WaitAnyOnly;
        cb_info.callback = on_queue_work_done;
        cb_info.userdata1 = &cb_state;
        WGPUFuture fut = wgpuQueueOnSubmittedWorkDone(device_.wgpu_queue(), cb_info);
        WGPUFutureWaitInfo wait{};
        wait.future = fut;
        wait.completed = false;
        WGPUWaitStatus ws = wgpuInstanceWaitAny(device_.wgpu_instance(),
                                                 1, &wait, UINT64_MAX);
        if (ws != WGPUWaitStatus_Success || !cb_state.done) {
            dawn_log("DawnCommandBuffer::wait_until_completed: WaitAny "
                     "status=%d done=%d", ws, cb_state.done);
        }
    }

    GPUTimestamp timestamp() const noexcept override {
        // Dawn timestamp queries require a feature opt-in and a query
        // set; not wired in Phase 6. Returns zeros — callers know to
        // not rely on it on Dawn until Phase 7.
        return GPUTimestamp{};
    }

    bool had_error() const noexcept override {
        // Dawn errors surface through the uncaptured-error callback
        // (which abort()s). A returned `false` here means "no error
        // visible to the GPUDevice contract".
        return false;
    }

private:
    DawnGPUDevice& device_;
    WGPUCommandEncoder encoder_{nullptr};
    WGPUCommandBuffer cmd_buffer_{nullptr};
    bool committed_{false};
    std::unique_ptr<DawnComputeEncoder> compute_encoder_;
    std::unique_ptr<DawnRenderEncoder>  render_encoder_;

    std::atomic<bool> warned_target_desc_overload_{false};
};

// ─── Out-of-line method defined after DawnCommandBuffer's full type ────

std::unique_ptr<GPUCommandBuffer> DawnGPUDevice::create_command_buffer() noexcept {
    if (!wgpu_device_) return nullptr;
    return std::make_unique<DawnCommandBuffer>(*this);
}

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
    auto* dawn_device = static_cast<DawnGPUDevice*>(&device);
    return std::make_unique<DawnCommandBuffer>(*dawn_device);
}

void register_wgsl_source(GPUDevice& device,
                          const char* name,
                          std::string_view wgsl_source,
                          const char* entry_point) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return;
    if (!name || !entry_point) return;
    // Type-tag dispatch (project compiles with -fno-rtti, dynamic_cast
    // unavailable). backend() == kDawn is the contract.
    auto* dawn_device = static_cast<DawnGPUDevice*>(&device);
    dawn_device->register_wgsl(name, wgsl_source, entry_point);
}

bool register_wgsl_from_file(GPUDevice& device,
                             const char* name,
                             const char* wgsl_path,
                             const char* entry_point) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return false;
    if (!name || !wgsl_path || !entry_point) return false;

    std::ifstream in(wgsl_path);
    if (!in) {
        dawn_log("register_wgsl_from_file: failed to open '%s'", wgsl_path);
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    std::string source = ss.str();
    register_wgsl_source(device, name, source, entry_point);
    return true;
}

GPUTextureHandle dawn_import_iosurface_texture(GPUDevice& device,
                                                void* iosurface,
                                                std::uint32_t width,
                                                std::uint32_t height,
                                                GPUTextureFormat format) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return GPUTextureHandle{0};
    auto* dawn_device = static_cast<DawnGPUDevice*>(&device);
    return dawn_device->import_iosurface(iosurface, width, height, format);
}

bool dawn_iosurface_begin_access(GPUDevice& device, GPUTextureHandle handle) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return false;
    return static_cast<DawnGPUDevice*>(&device)->iosurface_begin_access(handle);
}

bool dawn_iosurface_end_access(GPUDevice& device, GPUTextureHandle handle) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return false;
    return static_cast<DawnGPUDevice*>(&device)->iosurface_end_access(handle);
}

void register_baked_wgsl_into_device(GPUDevice& device) noexcept {
    // Register all 15 baked WGSL sources keyed by name. Each kernel uses
    // entry point "main" except splat_render which has separate vs_main +
    // fs_main; for the latter we register under two names (matches the
    // splat_render_via_device sentinel smoke convention).
    //
    // No-op if device.backend() != kDawn (delegated to register_wgsl_source).
    using namespace aether::shaders;

    register_wgsl_source(device, "project_forward",
                         project_forward_wgsl, "main");
    register_wgsl_source(device, "project_visible",
                         project_visible_wgsl, "main");
    register_wgsl_source(device, "project_backwards",
                         project_backwards_wgsl, "main");
    register_wgsl_source(device, "map_gaussian_to_intersects",
                         map_gaussian_to_intersects_wgsl, "main");
    register_wgsl_source(device, "rasterize",
                         rasterize_wgsl, "main");
    register_wgsl_source(device, "rasterize_backwards",
                         rasterize_backwards_wgsl, "main");
    register_wgsl_source(device, "sort_count",
                         sort_count_wgsl, "main");
    register_wgsl_source(device, "sort_reduce",
                         sort_reduce_wgsl, "main");
    register_wgsl_source(device, "sort_scan",
                         sort_scan_wgsl, "main");
    register_wgsl_source(device, "sort_scan_add",
                         sort_scan_add_wgsl, "main");
    register_wgsl_source(device, "sort_scatter",
                         sort_scatter_wgsl, "main");
    register_wgsl_source(device, "prefix_sum_scan",
                         prefix_sum_scan_wgsl, "main");
    register_wgsl_source(device, "prefix_sum_scan_sums",
                         prefix_sum_scan_sums_wgsl, "main");
    register_wgsl_source(device, "prefix_sum_add_scanned_sums",
                         prefix_sum_add_scanned_sums_wgsl, "main");

    // splat_render has two entry points; register under split names.
    register_wgsl_source(device, "splat_render_vs",
                         splat_render_wgsl, "vs_main");
    register_wgsl_source(device, "splat_render_fs",
                         splat_render_wgsl, "fs_main");
}

bool dawn_copy_buffer_to_buffer(GPUDevice& device,
                                GPUBufferHandle src,
                                GPUBufferHandle dst,
                                std::size_t size) noexcept {
    if (device.backend() != GraphicsBackend::kDawn) return false;
    if (size == 0) return true;
    auto* dawn_device = static_cast<DawnGPUDevice*>(&device);
    WGPUBuffer src_buf = dawn_device->get_buffer(src);
    WGPUBuffer dst_buf = dawn_device->get_buffer(dst);
    if (!src_buf || !dst_buf) {
        dawn_log("dawn_copy_buffer_to_buffer: invalid handle "
                 "src=%u dst=%u", src.id, dst.id);
        return false;
    }

    WGPUDevice wd = dawn_device->wgpu_device();
    WGPUQueue wq = dawn_device->wgpu_queue();
    WGPUInstance wi = dawn_device->wgpu_instance();

    WGPUCommandEncoderDescriptor enc_desc = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(wd, &enc_desc);
    if (!encoder) return false;
    wgpuCommandEncoderCopyBufferToBuffer(encoder, src_buf, 0, dst_buf, 0, size);
    WGPUCommandBufferDescriptor cb_desc = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish(encoder, &cb_desc);
    wgpuCommandEncoderRelease(encoder);
    if (!cb) return false;
    wgpuQueueSubmit(wq, 1, &cb);
    wgpuCommandBufferRelease(cb);

    QueueWorkDoneCallbackData state{};
    WGPUQueueWorkDoneCallbackInfo info = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
    info.mode = WGPUCallbackMode_WaitAnyOnly;
    info.callback = on_queue_work_done;
    info.userdata1 = &state;
    WGPUFuture fut = wgpuQueueOnSubmittedWorkDone(wq, info);
    WGPUFutureWaitInfo wait{fut, false};
    WGPUWaitStatus ws = wgpuInstanceWaitAny(wi, 1, &wait, UINT64_MAX);
    if (ws != WGPUWaitStatus_Success || !state.done) {
        dawn_log("dawn_copy_buffer_to_buffer: WaitAny status=%d done=%d",
                 ws, state.done);
        return false;
    }
    return true;
}

}  // namespace render
}  // namespace aether

#endif  // AETHER_ENABLE_DAWN
