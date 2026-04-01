// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// C API entry point for MetalGPUDevice creation.
// Objective-C++ (.mm) because it bridges Metal ↔ C++ ↔ C.

#if defined(__APPLE__)

#import <Metal/Metal.h>
#include "aether/render/metal_gpu_device.h"
#include "aether_tsdf_c.h"

using namespace aether::render;

// The aether_gpu_device struct is defined in c_api.cpp.
// We forward-declare the same layout here so we can populate it.
struct aether_gpu_device {
    GPUDevice* impl;  // owned
};

extern "C" {

aether_gpu_device_t* aether_gpu_device_create_metal(void* mtl_device_ptr) {
    if (!mtl_device_ptr) return nullptr;

    auto device = create_metal_gpu_device(mtl_device_ptr);
    if (!device) return nullptr;

    auto* wrapper = new (std::nothrow) aether_gpu_device_t();
    if (!wrapper) return nullptr;

    wrapper->impl = device.release();  // Transfer ownership to C wrapper
    return wrapper;
}

}  // extern "C"

#else  // !__APPLE__

#include "aether_tsdf_c.h"

extern "C" {

aether_gpu_device_t* aether_gpu_device_create_metal(void* /*mtl_device_ptr*/) {
    return nullptr;  // Metal not available on non-Apple platforms
}

}  // extern "C"

#endif  // __APPLE__
