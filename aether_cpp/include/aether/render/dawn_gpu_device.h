// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_DAWN_GPU_DEVICE_H
#define AETHER_CPP_RENDER_DAWN_GPU_DEVICE_H

// ─── Phase 6.2: Dawn (WebGPU) backend factory ──────────────────────────
//
// Provides the cross-platform GPU implementation that 3DGS viewer +
// training pipelines target. Dawn translates the same WGSL shaders into
// platform-native shader code (Metal on Apple, Vulkan on Android /
// HarmonyOS, D3D12 on Windows). Per the architectural commitment
// locked in PHASE_BACKLOG.md "Phase 6 prerequisite" — WGSL is the
// single source of truth for all shader code.
//
// This header is enabled whenever AETHER_ENABLE_DAWN is ON in CMake;
// no platform gate (Apple-vs-other) — Dawn itself is cross-platform.
// Apple-specific platforms still pull in metal_gpu_device.h alongside;
// the consumer chooses which factory to call based on its needs.
//
// Design parallels metal_gpu_device.h: opaque void* device handle,
// owning std::unique_ptr returned, factory functions for command-
// buffer creation. The Dawn equivalent of the IOSurface bridge for
// Flutter zero-copy texture interop lives in DawnGPUDevice::create_texture
// (with platform-specific extension fields in GPUTextureDesc when iOS).

#ifdef __cplusplus

#include "aether/render/gpu_device.h"
#include "aether/render/gpu_command.h"
#include <memory>
#include <string>
#include <string_view>

namespace aether {
namespace render {

// ─── Factory ────────────────────────────────────────────────────────────

/// Create a DawnGPUDevice. Internally requests an adapter + device from
/// Dawn's instance, picking the best available backend for the current
/// platform (Metal on Apple, Vulkan on Linux/Android, D3D12 on Windows).
///
/// @param request_high_performance  If true, request a high-perf
///                                  discrete GPU adapter (no-op on
///                                  iPhones — Apple Silicon has only
///                                  one GPU). Default true matches
///                                  Phase 4/5 macOS desktop behavior.
/// @return Owning unique_ptr, or nullptr on failure (no adapter, no
///         device, etc.).
///
/// Failure modes (all return nullptr):
///   - Dawn instance creation failed (very rare; OOM territory)
///   - No suitable adapter for the platform
///   - Adapter request returned an error
///   - Device request returned an error
/// Each writes a diagnostic via NSLog (Apple) or stderr (Linux/Win)
/// before returning nullptr — caller should not need to log again.
std::unique_ptr<GPUDevice> create_dawn_gpu_device(bool request_high_performance = true) noexcept;

/// Create a Dawn command buffer from an existing DawnGPUDevice.
/// @param device  Must be a DawnGPUDevice created by create_dawn_gpu_device().
/// @return Owning unique_ptr, or nullptr on failure (wrong backend on
///         the device, OOM creating wgpu::CommandEncoder).
std::unique_ptr<GPUCommandBuffer> create_dawn_command_buffer(GPUDevice& device) noexcept;

// ─── Shader registry (Dawn-specific) ───────────────────────────────────
//
// Metal's load_shader looks up entry-point names in a precompiled
// .metallib library. Dawn has no equivalent — WGSL is supplied as raw
// source. To keep the GPUDevice virtual API unchanged, callers register
// WGSL sources by name with this free function before calling
// device.load_shader(name, stage). The registered name should match the
// WGSL filename without extension (e.g. "project_forward").
//
// Safe to call before or after device.load_shader; the registry is
// thread-safe via the device's internal mutex.
//
// No-op if device.backend() != kDawn (so smoke / wrapper code can safely
// call this regardless of which backend the device is).

/// Register a WGSL source string under `name`. Subsequent
/// device.load_shader(name, stage) returns a handle to a compiled
/// WGPUShaderModule with `entry_point` bound for pipeline creation.
///
/// @param device       Any GPUDevice; no-op if backend != kDawn.
/// @param name         Lookup key; must remain valid for the lifetime
///                     of the registry entry (typically a string literal).
/// @param wgsl_source  WGSL bytes; copied into the device's registry.
/// @param entry_point  Function name in the WGSL source. Brush kernels
///                     all use "main" (default). For multi-entry-point
///                     modules (splat_render.wgsl: vs_main + fs_main),
///                     register the same source twice under different
///                     names, each with its own entry_point.
void register_wgsl_source(GPUDevice& device,
                          const char* name,
                          std::string_view wgsl_source,
                          const char* entry_point = "main") noexcept;

/// Convenience overload — load the WGSL source from `wgsl_path`, then
/// register it under `name` with the given entry_point. Returns false
/// (and logs) if the file can't be read or device backend isn't kDawn.
///
/// This path is for development tools (smoke binaries) where iterating
/// on .wgsl without rebuilding C++ is the productivity win. Production
/// callers should use register_baked_wgsl_into_device() (below).
bool register_wgsl_from_file(GPUDevice& device,
                             const char* name,
                             const char* wgsl_path,
                             const char* entry_point = "main") noexcept;

/// Register all 15 baked WGSL sources into the device's registry, keyed
/// by canonical name (filename without extension; splat_render is
/// registered twice with `_vs`/`_fs` suffixes for its two entry points).
///
/// This is the production-path WGSL load — zero filesystem dependency,
/// sources are baked into the binary by the CMake bake step (see
/// aether_cpp/scripts/bake_one_wgsl.cmake).
///
/// Safe to call multiple times (re-registration overwrites).
/// No-op if device.backend() != kDawn.
void register_baked_wgsl_into_device(GPUDevice& device) noexcept;

// ─── 6.4a: IOSurface bridge (Apple platforms only) ─────────────────────
//
// Imports an IOSurface as a Dawn-writable texture via the
// SharedTextureMemoryIOSurface feature. The texture's bytes ARE the
// IOSurface's bytes (zero-copy). Used by the PocketWorld Flutter Texture
// plugin to display Dawn-rendered splat output without going through a
// CPU readback.
//
// Per-frame usage:
//   dawn_iosurface_begin_access(device, tex);   // before render pass
//   ... render ...
//   dawn_iosurface_end_access(device, tex);     // after commit
//
// On non-Apple adapters (or if SharedTextureMemoryIOSurface feature
// wasn't granted at device creation), all three functions return invalid
// handle / false with a diagnostic.

/// Import an IOSurface (passed as void* — the caller is responsible for
/// keeping it alive for the texture's lifetime; on Apple side this is
/// typically an `IOSurfaceRef` cast to void* via Unmanaged.toOpaque() or
/// __bridge_retained).
GPUTextureHandle dawn_import_iosurface_texture(GPUDevice& device,
                                                void* iosurface,
                                                std::uint32_t width,
                                                std::uint32_t height,
                                                GPUTextureFormat format) noexcept;

/// Begin access fence — call BEFORE the render pass that writes to the
/// IOSurface-backed texture. Returns false on invalid handle / non-IOSurface
/// texture / Dawn validation error.
bool dawn_iosurface_begin_access(GPUDevice& device, GPUTextureHandle handle) noexcept;

/// End access fence — call AFTER the command buffer that wrote to the
/// IOSurface-backed texture has committed (and ideally completed).
/// Returns false on invalid handle / Dawn validation error.
bool dawn_iosurface_end_access(GPUDevice& device, GPUTextureHandle handle) noexcept;

/// One-shot GPU→GPU buffer-to-buffer copy. Creates a transient command
/// encoder + CopyBufferToBuffer + Submit, then blocks until the GPU has
/// finished. Used to move data from a kStorage buffer into a kStaging
/// buffer prior to readback via map_buffer.
///
/// Metal's MetalGPUDevice has no equivalent because shared-storage
/// buffers are CPU-readable directly via map_buffer; this helper is
/// strictly for the Dawn path.
///
/// @return false on any failure (wrong backend, invalid handles, GPU
///         submission rejected). Diagnostic logged via stderr on failure.
bool dawn_copy_buffer_to_buffer(GPUDevice& device,
                                GPUBufferHandle src,
                                GPUBufferHandle dst,
                                std::size_t size) noexcept;

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_DAWN_GPU_DEVICE_H
