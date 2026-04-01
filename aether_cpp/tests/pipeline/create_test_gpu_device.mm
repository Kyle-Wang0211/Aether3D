// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Headless Metal GPU device creation for tests.
// Uses MTLCreateSystemDefaultDevice() to get the system GPU,
// then wraps it in a MetalGPUDevice for the full GPU training path.

#if defined(__APPLE__)

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "create_test_gpu_device.h"
#include "aether/render/metal_gpu_device.h"
#include <cstdio>

std::unique_ptr<aether::render::GPUDevice> create_test_gpu_device() noexcept {
    @autoreleasepool {
        // Get the system default Metal device (works headlessly, no window needed)
        id<MTLDevice> mtl_device = MTLCreateSystemDefaultDevice();
        if (!mtl_device) {
            std::fprintf(stderr, "[TestGPU] No Metal device available — falling back to CPU\n");
            return nullptr;
        }

        std::fprintf(stderr, "[TestGPU] Metal device: %s\n",
                     [[mtl_device name] UTF8String]);
        std::fprintf(stderr, "[TestGPU] Recommended max working set: %.0f MB\n",
                     [mtl_device recommendedMaxWorkingSetSize] / (1024.0 * 1024.0));

        // Create MetalGPUDevice wrapping the system GPU
        auto device = aether::render::create_metal_gpu_device((__bridge void*)mtl_device);
        if (!device) {
            std::fprintf(stderr, "[TestGPU] Failed to create MetalGPUDevice\n");
            return nullptr;
        }

        std::fprintf(stderr, "[TestGPU] MetalGPUDevice created successfully — GPU training enabled\n");
        return device;
    }
}

#else  // not __APPLE__

#include "create_test_gpu_device.h"
#include <cstdio>

std::unique_ptr<aether::render::GPUDevice> create_test_gpu_device() noexcept {
    std::fprintf(stderr, "[TestGPU] Not on Apple platform — no Metal GPU available\n");
    return nullptr;
}

#endif  // __APPLE__
