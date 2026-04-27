// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#if defined(AETHER_ENABLE_DAWN)

#include "dawn_device_singleton.h"
#include "aether/render/dawn_gpu_device.h"

#include <cstdio>
#include <memory>
#include <mutex>

namespace aether {
namespace pocketworld {

namespace {

std::mutex& mtx() {
    static std::mutex m;
    return m;
}

std::unique_ptr<::aether::render::GPUDevice>& device_ref() {
    static std::unique_ptr<::aether::render::GPUDevice> d;
    return d;
}

std::uint32_t& refcount() {
    static std::uint32_t c = 0;
    return c;
}

}  // namespace

::aether::render::GPUDevice* dawn_singleton_acquire() {
    std::lock_guard<std::mutex> lock(mtx());
    auto& d = device_ref();
    if (!d) {
        d = ::aether::render::create_dawn_gpu_device(/*request_high_performance=*/true);
        if (!d) {
            std::fprintf(stderr, "[dawn_singleton] FATAL: create_dawn_gpu_device "
                                 "returned nullptr\n");
            return nullptr;
        }
        // Production-path WGSL: zero filesystem dependency, all 16 .wgsl
        // files baked into the binary at compile time.
        ::aether::render::register_baked_wgsl_into_device(*d);
    }
    ++refcount();
    return d.get();
}

void dawn_singleton_release() {
    std::lock_guard<std::mutex> lock(mtx());
    if (refcount() == 0) return;  // defensive — release-without-acquire
    --refcount();
    if (refcount() == 0) {
        device_ref().reset();
    }
}

}  // namespace pocketworld
}  // namespace aether

#else  // !AETHER_ENABLE_DAWN

#include "dawn_device_singleton.h"

namespace aether {
namespace pocketworld {

::aether::render::GPUDevice* dawn_singleton_acquire() { return nullptr; }
void dawn_singleton_release() {}

}  // namespace pocketworld
}  // namespace aether

#endif  // AETHER_ENABLE_DAWN
