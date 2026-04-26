// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_RUNTIME_BACKEND_H
#define AETHER_CPP_RENDER_RUNTIME_BACKEND_H

#ifdef __cplusplus

#include <cstdint>

namespace aether {
namespace render {

enum class RuntimePlatform : std::uint8_t {
    kIOS = 0u,
    kAndroid = 1u,
    kHarmonyOS = 2u,
    kUnknown = 3u,
};

enum class GraphicsBackend : std::uint8_t {
    kMetal = 0u,
    kVulkan = 1u,
    kOpenGLES = 2u,
    kUnknown = 3u,
    // Phase 6.2: Dawn (WebGPU) backend. Maps to Metal on Apple, Vulkan on
    // Android/HarmonyOS, D3D12 on Windows internally — but exposed
    // uniformly as kDawn so application code is platform-agnostic. Used
    // by DawnGPUDevice (see aether/render/dawn_gpu_device.h).
    kDawn = 4u,
};

inline constexpr bool is_backend_supported_for_platform(
    RuntimePlatform platform,
    GraphicsBackend backend) {
    switch (platform) {
        case RuntimePlatform::kIOS:
            // Phase 6.2: Dawn iOS is supported (translates to Metal internally).
            return backend == GraphicsBackend::kMetal || backend == GraphicsBackend::kDawn;
        case RuntimePlatform::kAndroid:
        case RuntimePlatform::kHarmonyOS:
            return backend == GraphicsBackend::kVulkan
                || backend == GraphicsBackend::kOpenGLES
                || backend == GraphicsBackend::kDawn;
        case RuntimePlatform::kUnknown:
            return false;
    }
    return false;
}

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_RUNTIME_BACKEND_H
