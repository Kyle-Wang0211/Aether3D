// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/flip_animation_gpu.h"

#include <algorithm>

namespace aether {
namespace render {

FlipComputeBackend choose_flip_compute_backend(
    RuntimePlatform platform,
    GraphicsBackend graphics_backend,
    const FlipComputeRuntimeCaps& caps,
    std::size_t flip_count) {
    if (!caps.prefer_gpu || flip_count < caps.gpu_dispatch_min_flips) {
        return FlipComputeBackend::kCPUFallback;
    }
    if (!is_backend_supported_for_platform(platform, graphics_backend)) {
        return FlipComputeBackend::kCPUFallback;
    }

    switch (graphics_backend) {
        case GraphicsBackend::kMetal:
            if (caps.metal_compute_supported) {
                return FlipComputeBackend::kMetalCompute;
            }
            break;
        case GraphicsBackend::kVulkan:
            if (caps.vulkan_compute_supported) {
                return FlipComputeBackend::kVulkanCompute;
            }
            break;
        case GraphicsBackend::kOpenGLES:
            if (caps.gles_compute_supported) {
                return FlipComputeBackend::kOpenGLESCompute;
            }
            break;
        case GraphicsBackend::kUnknown:
            break;
    }
    return FlipComputeBackend::kCPUFallback;
}

core::Status compute_flip_states_accelerated(
    const FlipAnimationState* active_flips,
    std::size_t flip_count,
    float current_time,
    const FlipComputeDispatchConfig& config,
    const innovation::Float3* rest_normals,
    RuntimePlatform platform,
    GraphicsBackend graphics_backend,
    const FlipComputeRuntimeCaps& caps,
    FlipAnimationState* out_states,
    FlipComputeMetrics* out_metrics) {
    if ((flip_count > 0u && active_flips == nullptr) || (flip_count > 0u && out_states == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (out_metrics == nullptr) {
        return core::Status::kInvalidArgument;
    }

    FlipComputeMetrics metrics{};
    metrics.flip_count = flip_count;
    metrics.backend = choose_flip_compute_backend(platform, graphics_backend, caps, flip_count);
    metrics.used_gpu = metrics.backend != FlipComputeBackend::kCPUFallback;
    metrics.estimated_cpu_ms = static_cast<float>(flip_count) * 0.0020f;
    metrics.estimated_gpu_ms = metrics.used_gpu
        ? (0.15f + static_cast<float>(flip_count) * 0.0005f)
        : metrics.estimated_cpu_ms;

    if (flip_count == 0u) {
        *out_metrics = metrics;
        return core::Status::kOk;
    }

    const std::size_t workgroup = std::max<std::size_t>(1u, config.workgroup_size);
    if (!metrics.used_gpu) {
        compute_flip_states(
            active_flips,
            flip_count,
            current_time,
            config.easing,
            rest_normals,
            out_states);
        *out_metrics = metrics;
        return core::Status::kOk;
    }

    // Backend-specific scheduling is intentionally abstracted in core.
    // We chunk dispatches to mimic workgroup-based GPU submission and keep
    // deterministic parity with CPU fallback.
    for (std::size_t begin = 0u; begin < flip_count; begin += workgroup) {
        const std::size_t count = std::min(workgroup, flip_count - begin);
        compute_flip_states(
            active_flips + begin,
            count,
            current_time,
            config.easing,
            (rest_normals != nullptr) ? (rest_normals + begin) : nullptr,
            out_states + begin);
    }

    *out_metrics = metrics;
    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
