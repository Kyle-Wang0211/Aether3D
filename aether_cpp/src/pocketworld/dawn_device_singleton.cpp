// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#if defined(AETHER_ENABLE_DAWN)

#include "dawn_device_singleton.h"
#include "aether/render/dawn_gpu_device.h"

#include <cstddef>
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

// Teardown-hook table. Deliberately a constant-initialized POD array
// rather than a std::vector in a function-local static: this table is
// read during refcount-zero teardown, which can happen at any point in
// a process's life INCLUDING from a static destructor, and a POD array
// has no destructor that could run first and leave us reading freed
// storage.
constexpr std::size_t kMaxTeardownHooks = 8;
DawnSingletonTeardownHook g_teardown_hooks[kMaxTeardownHooks] = {};
std::size_t g_teardown_hook_count = 0;

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

void dawn_singleton_add_teardown_hook(DawnSingletonTeardownHook fn) {
    if (!fn) return;
    std::lock_guard<std::mutex> lock(mtx());
    for (std::size_t i = 0; i < g_teardown_hook_count; ++i) {
        if (g_teardown_hooks[i] == fn) return;  // idempotent
    }
    if (g_teardown_hook_count >= kMaxTeardownHooks) {
        std::fprintf(stderr, "[dawn_singleton] teardown hook table full (%zu); "
                             "hook dropped — device-owned resources may dangle\n",
                     kMaxTeardownHooks);
        return;
    }
    g_teardown_hooks[g_teardown_hook_count++] = fn;
}

void dawn_singleton_release() {
    std::lock_guard<std::mutex> lock(mtx());
    if (refcount() == 0) return;  // defensive — release-without-acquire
    --refcount();
    if (refcount() == 0) {
        // Run the hooks FIRST, while the device is still alive, so
        // holders of device-owned resources (GPU buffer handles + a raw
        // GPUDevice*) can free them legally. Dropping them after the
        // reset below would be a use-after-free; leaving them alive
        // would dangle into the NEXT device. See the header contract:
        // a hook must not re-enter acquire/release.
        for (std::size_t i = 0; i < g_teardown_hook_count; ++i) {
            g_teardown_hooks[i]();
        }
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
void dawn_singleton_add_teardown_hook(DawnSingletonTeardownHook) {}

}  // namespace pocketworld
}  // namespace aether

#endif  // AETHER_ENABLE_DAWN
