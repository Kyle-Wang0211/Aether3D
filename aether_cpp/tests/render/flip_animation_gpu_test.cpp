// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/flip_animation_gpu.h"

#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    int failed = 0;

    aether::render::FlipAnimationState flip{};
    flip.start_time_s = 0.0f;
    flip.flip_axis_direction = aether::innovation::make_float3(0.0f, 1.0f, 0.0f);
    const aether::innovation::Float3 rest = aether::innovation::make_float3(0.0f, 0.0f, 1.0f);

    aether::render::FlipComputeRuntimeCaps caps{};
    caps.prefer_gpu = true;
    caps.metal_compute_supported = true;
    caps.vulkan_compute_supported = true;
    caps.gles_compute_supported = true;
    caps.gpu_dispatch_min_flips = 1u;

    const auto ios_backend = aether::render::choose_flip_compute_backend(
        aether::render::RuntimePlatform::kIOS,
        aether::render::GraphicsBackend::kMetal,
        caps,
        8u);
    if (ios_backend != aether::render::FlipComputeBackend::kMetalCompute) {
        std::fprintf(stderr, "iOS Metal should choose Metal compute backend\n");
        failed++;
    }

    const auto android_backend = aether::render::choose_flip_compute_backend(
        aether::render::RuntimePlatform::kAndroid,
        aether::render::GraphicsBackend::kVulkan,
        caps,
        8u);
    if (android_backend != aether::render::FlipComputeBackend::kVulkanCompute) {
        std::fprintf(stderr, "Android Vulkan should choose Vulkan compute backend\n");
        failed++;
    }

    const auto ohos_backend = aether::render::choose_flip_compute_backend(
        aether::render::RuntimePlatform::kHarmonyOS,
        aether::render::GraphicsBackend::kOpenGLES,
        caps,
        8u);
    if (ohos_backend != aether::render::FlipComputeBackend::kOpenGLESCompute) {
        std::fprintf(stderr, "Harmony OpenGLES should choose GLES compute backend\n");
        failed++;
    }

    const auto ios_vulkan = aether::render::choose_flip_compute_backend(
        aether::render::RuntimePlatform::kIOS,
        aether::render::GraphicsBackend::kVulkan,
        caps,
        8u);
    if (ios_vulkan != aether::render::FlipComputeBackend::kCPUFallback) {
        std::fprintf(stderr, "iOS Vulkan must fallback to CPU on unsupported pair\n");
        failed++;
    }

    const auto android_metal = aether::render::choose_flip_compute_backend(
        aether::render::RuntimePlatform::kAndroid,
        aether::render::GraphicsBackend::kMetal,
        caps,
        8u);
    if (android_metal != aether::render::FlipComputeBackend::kCPUFallback) {
        std::fprintf(stderr, "Android Metal must fallback to CPU on unsupported pair\n");
        failed++;
    }

    caps.gpu_dispatch_min_flips = 200u;
    const auto small_batch_backend = aether::render::choose_flip_compute_backend(
        aether::render::RuntimePlatform::kIOS,
        aether::render::GraphicsBackend::kMetal,
        caps,
        32u);
    if (small_batch_backend != aether::render::FlipComputeBackend::kCPUFallback) {
        std::fprintf(stderr, "small batch should fallback to CPU\n");
        failed++;
    }

    std::vector<aether::render::FlipAnimationState> input(4u, flip);
    std::vector<aether::render::FlipAnimationState> cpu_out(4u);
    std::vector<aether::render::FlipAnimationState> gpu_out(4u);
    const aether::innovation::Float3 rest_normals[4] = {rest, rest, rest, rest};

    const aether::render::FlipEasingConfig easing{};
    aether::render::compute_flip_states(
        input.data(),
        input.size(),
        0.25f,
        easing,
        rest_normals,
        cpu_out.data());

    aether::render::FlipComputeRuntimeCaps gpu_caps{};
    gpu_caps.prefer_gpu = true;
    gpu_caps.metal_compute_supported = true;
    gpu_caps.vulkan_compute_supported = true;
    gpu_caps.gles_compute_supported = true;
    gpu_caps.gpu_dispatch_min_flips = 1u;
    aether::render::FlipComputeDispatchConfig dispatch_cfg{};
    dispatch_cfg.easing = easing;
    dispatch_cfg.workgroup_size = 2u;
    aether::render::FlipComputeMetrics metrics{};
    const aether::core::Status status = aether::render::compute_flip_states_accelerated(
        input.data(),
        input.size(),
        0.25f,
        dispatch_cfg,
        rest_normals,
        aether::render::RuntimePlatform::kIOS,
        aether::render::GraphicsBackend::kMetal,
        gpu_caps,
        gpu_out.data(),
        &metrics);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "compute_flip_states_accelerated failed\n");
        return 1;
    }
    if (!metrics.used_gpu) {
        std::fprintf(stderr, "accelerated path should report gpu usage\n");
        failed++;
    }

    for (std::size_t i = 0u; i < input.size(); ++i) {
        const float angle_diff = std::fabs(cpu_out[i].flip_angle - gpu_out[i].flip_angle);
        const float nx_diff = std::fabs(cpu_out[i].rotated_normal.x - gpu_out[i].rotated_normal.x);
        const float ny_diff = std::fabs(cpu_out[i].rotated_normal.y - gpu_out[i].rotated_normal.y);
        const float nz_diff = std::fabs(cpu_out[i].rotated_normal.z - gpu_out[i].rotated_normal.z);
        if (angle_diff > 1e-6f || nx_diff > 1e-6f || ny_diff > 1e-6f || nz_diff > 1e-6f) {
            std::fprintf(stderr, "accelerated path must match cpu fallback deterministically\n");
            failed++;
            break;
        }
    }

    return failed;
}
