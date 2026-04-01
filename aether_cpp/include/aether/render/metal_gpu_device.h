// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_METAL_GPU_DEVICE_H
#define AETHER_CPP_RENDER_METAL_GPU_DEVICE_H

#if defined(__APPLE__) && defined(__cplusplus)

#include "aether/render/gpu_device.h"
#include "aether/render/gpu_command.h"
#include <memory>

namespace aether {
namespace render {

/// Create a MetalGPUDevice wrapping an existing MTLDevice.
/// @param mtl_device  Pointer to an id<MTLDevice> (__bridge void*).
///                    The caller retains ownership — MetalGPUDevice will retain it.
/// @return Owning unique_ptr, or nullptr on failure.
std::unique_ptr<GPUDevice> create_metal_gpu_device(void* mtl_device) noexcept;

/// Create a MetalCommandBuffer from a MetalGPUDevice.
/// @param device  Must be a MetalGPUDevice created by create_metal_gpu_device().
/// @return Owning unique_ptr, or nullptr on failure.
std::unique_ptr<GPUCommandBuffer> create_metal_command_buffer(GPUDevice& device) noexcept;

/// Wrap an existing MTLCommandBuffer (from Swift) in a MetalCommandBuffer adapter.
/// Swift passes MTLCommandBuffer* as void* via Unmanaged.passUnretained().toOpaque().
/// The C++ GPU abstraction layer needs a GPUCommandBuffer with virtual dispatch.
/// @param mtl_cmd_buffer  Pointer to an id<MTLCommandBuffer> (__bridge void*).
/// @param device          Must be a MetalGPUDevice (for resource handle lookups).
/// @return Owning unique_ptr, or nullptr on failure.
std::unique_ptr<GPUCommandBuffer> wrap_metal_command_buffer(void* mtl_cmd_buffer,
                                                             GPUDevice& device) noexcept;

}  // namespace render
}  // namespace aether

#endif  // __APPLE__ && __cplusplus

#endif  // AETHER_CPP_RENDER_METAL_GPU_DEVICE_H
