// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_GPU_COMMAND_H
#define AETHER_CPP_RENDER_GPU_COMMAND_H

#ifdef __cplusplus

#include "aether/render/gpu_resource.h"
#include <cstdint>

namespace aether {
namespace render {

// ═══════════════════════════════════════════════════════════════════════
// GPUComputeEncoder: Records compute dispatch commands
// ═══════════════════════════════════════════════════════════════════════

class GPUComputeEncoder {
public:
    virtual ~GPUComputeEncoder() = default;

    virtual void set_pipeline(GPUComputePipelineHandle pipeline) noexcept = 0;
    virtual void set_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                           std::uint32_t index) noexcept = 0;
    virtual void set_texture(GPUTextureHandle texture, std::uint32_t index) noexcept = 0;
    virtual void set_bytes(const void* data, std::uint32_t size,
                          std::uint32_t index) noexcept = 0;

    // 3D dispatch: threadgroups x threads_per_threadgroup
    virtual void dispatch(std::uint32_t groups_x, std::uint32_t groups_y,
                         std::uint32_t groups_z,
                         std::uint32_t threads_x, std::uint32_t threads_y,
                         std::uint32_t threads_z) noexcept = 0;

    // 1D convenience
    void dispatch_1d(std::uint32_t total_threads,
                     std::uint32_t threadgroup_size) noexcept {
        std::uint32_t groups =
            (total_threads + threadgroup_size - 1) / threadgroup_size;
        dispatch(groups, 1, 1, threadgroup_size, 1, 1);
    }

    virtual void end_encoding() noexcept = 0;

protected:
    GPUComputeEncoder() = default;
};

// ═══════════════════════════════════════════════════════════════════════
// GPURenderEncoder: Records render pass commands
// ═══════════════════════════════════════════════════════════════════════

class GPURenderEncoder {
public:
    virtual ~GPURenderEncoder() = default;

    virtual void set_pipeline(GPURenderPipelineHandle pipeline) noexcept = 0;
    virtual void set_vertex_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                                   std::uint32_t index) noexcept = 0;
    virtual void set_fragment_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                                     std::uint32_t index) noexcept = 0;
    virtual void set_vertex_bytes(const void* data, std::uint32_t size,
                                  std::uint32_t index) noexcept = 0;
    virtual void set_fragment_bytes(const void* data, std::uint32_t size,
                                    std::uint32_t index) noexcept = 0;
    virtual void set_vertex_texture(GPUTextureHandle texture,
                                    std::uint32_t index) noexcept = 0;
    virtual void set_fragment_texture(GPUTextureHandle texture,
                                      std::uint32_t index) noexcept = 0;

    virtual void set_viewport(const GPUViewport& viewport) noexcept = 0;
    virtual void set_scissor(const GPUScissorRect& rect) noexcept = 0;
    virtual void set_cull_mode(GPUCullMode mode) noexcept = 0;
    virtual void set_winding(GPUWindingOrder order) noexcept = 0;

    virtual void draw(GPUPrimitiveType type, std::uint32_t vertex_start,
                     std::uint32_t vertex_count) noexcept = 0;
    virtual void draw_indexed(GPUPrimitiveType type, std::uint32_t index_count,
                             GPUBufferHandle index_buffer,
                             std::uint32_t index_offset) noexcept = 0;
    virtual void draw_instanced(GPUPrimitiveType type,
                               std::uint32_t vertex_count,
                               std::uint32_t instance_count) noexcept = 0;

    virtual void end_encoding() noexcept = 0;

protected:
    GPURenderEncoder() = default;
};

// ═══════════════════════════════════════════════════════════════════════
// GPUCommandBuffer: Collects encoded commands for GPU submission
// ═══════════════════════════════════════════════════════════════════════

class GPUCommandBuffer {
public:
    virtual ~GPUCommandBuffer() = default;

    // Create encoders. Caller must call end_encoding() before creating another.
    virtual GPUComputeEncoder* make_compute_encoder() noexcept = 0;
    virtual GPURenderEncoder* make_render_encoder(
        const GPURenderTargetDesc& target) noexcept = 0;
    virtual GPURenderEncoder* make_render_encoder(
        const GPURenderPassDesc& pass) noexcept = 0;

    /// Create a render encoder from a platform-native render pass descriptor.
    /// On Metal: native_rpd is void* to MTLRenderPassDescriptor (via __bridge).
    /// This renders directly into the drawable (no offscreen textures created).
    /// Default returns nullptr (unsupported on non-Metal backends).
    virtual GPURenderEncoder* make_render_encoder_native(
        void* native_rpd) noexcept {
        (void)native_rpd;
        return nullptr;
    }

    // Submit to GPU and begin execution.
    virtual void commit() noexcept = 0;

    // Wait until GPU finishes this command buffer.
    virtual void wait_until_completed() noexcept = 0;

    // Get timing info (valid after wait_until_completed).
    virtual GPUTimestamp timestamp() const noexcept = 0;

    // Check if GPU reported an error.
    virtual bool had_error() const noexcept = 0;

protected:
    GPUCommandBuffer() = default;
};

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_GPU_COMMAND_H
