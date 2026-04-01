// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Factory for headless GPU device creation in tests.
// On macOS with Metal: creates a real MetalGPUDevice using the system default GPU.
// Otherwise: returns nullptr (caller should fall back to NullGPUDevice).

#ifndef AETHER_TEST_CREATE_TEST_GPU_DEVICE_H
#define AETHER_TEST_CREATE_TEST_GPU_DEVICE_H

#include "aether/render/gpu_device.h"
#include <memory>

/// Create a real GPU device for testing (Metal on macOS).
/// Returns nullptr if no GPU is available (headless CI, Linux, etc.).
std::unique_ptr<aether::render::GPUDevice> create_test_gpu_device() noexcept;

#endif  // AETHER_TEST_CREATE_TEST_GPU_DEVICE_H
