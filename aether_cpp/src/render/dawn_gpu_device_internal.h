// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_RENDER_DAWN_GPU_DEVICE_INTERNAL_H
#define AETHER_RENDER_DAWN_GPU_DEVICE_INTERNAL_H

// ─── INTERNAL API — same library only ──────────────────────────────────
//
// DawnGPUDevice is implemented in src/render/dawn_gpu_device.cpp inside
// an anonymous namespace so app code can't accidentally bind to its
// concrete type. But other TUs WITHIN the aether_cpp library
// (specifically src/pocketworld/scene_iosurface_renderer.cpp) need
// access to its raw WGPU handles to author multi-pass / depth /
// sampler / vertex-buffer-layout render pipelines that the public
// GPUDevice virtual API doesn't expose.
//
// This header gives same-library code a few narrow accessors
// (functions, not class methods) to those WGPU handles. App code MUST
// NOT include this header — keep it under src/.
//
// All accessors return nullptr when device.backend() != kDawn or when
// the handle can't be resolved. They never abort.

#if defined(AETHER_ENABLE_DAWN)

#include "aether/render/gpu_device.h"
#include "aether/render/gpu_resource.h"

#include <webgpu/webgpu.h>
#include <string>

namespace aether {
namespace render {
namespace internal {

WGPUDevice    dawn_internal_wgpu_device(GPUDevice& device) noexcept;
WGPUQueue     dawn_internal_wgpu_queue(GPUDevice& device) noexcept;
WGPUInstance  dawn_internal_wgpu_instance(GPUDevice& device) noexcept;

WGPUBuffer         dawn_internal_get_buffer(GPUDevice&, GPUBufferHandle) noexcept;
WGPUTexture        dawn_internal_get_texture(GPUDevice&, GPUTextureHandle) noexcept;
WGPURenderPipeline dawn_internal_get_render_pipeline(GPUDevice&, GPURenderPipelineHandle) noexcept;
WGPUShaderModule   dawn_internal_get_shader_module(GPUDevice&, GPUShaderHandle,
                                                    std::string& out_entry_point) noexcept;

}  // namespace internal
}  // namespace render
}  // namespace aether

#endif  // AETHER_ENABLE_DAWN
#endif  // AETHER_RENDER_DAWN_GPU_DEVICE_INTERNAL_H
