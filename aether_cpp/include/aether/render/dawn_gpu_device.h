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

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_DAWN_GPU_DEVICE_H
