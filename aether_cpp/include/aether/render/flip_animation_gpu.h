// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_FLIP_ANIMATION_GPU_H
#define AETHER_CPP_RENDER_FLIP_ANIMATION_GPU_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/render/flip_animation.h"
#include "aether/render/runtime_backend.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {

enum class FlipComputeBackend : std::uint8_t {
    kCPUFallback = 0u,
    kMetalCompute = 1u,
    kVulkanCompute = 2u,
    kOpenGLESCompute = 3u,
};

struct FlipComputeRuntimeCaps {
    bool metal_compute_supported{false};
    bool vulkan_compute_supported{false};
    bool gles_compute_supported{false};
    bool prefer_gpu{true};
    std::size_t gpu_dispatch_min_flips{200u};
};

struct FlipComputeDispatchConfig {
    FlipEasingConfig easing{};
    std::size_t workgroup_size{64u};
};

struct FlipComputeMetrics {
    FlipComputeBackend backend{FlipComputeBackend::kCPUFallback};
    std::size_t flip_count{0u};
    bool used_gpu{false};
    float estimated_cpu_ms{0.0f};
    float estimated_gpu_ms{0.0f};
};

FlipComputeBackend choose_flip_compute_backend(
    RuntimePlatform platform,
    GraphicsBackend graphics_backend,
    const FlipComputeRuntimeCaps& caps,
    std::size_t flip_count);

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
    FlipComputeMetrics* out_metrics);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_FLIP_ANIMATION_GPU_H
