// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_GPU_DEVICE_H
#define AETHER_CPP_RENDER_GPU_DEVICE_H

#ifdef __cplusplus

#include "aether/render/gpu_resource.h"
#include <cstdint>
#include <memory>
#include <vector>

namespace aether {
namespace render {

// Forward declare
class GPUCommandBuffer;

// ═══════════════════════════════════════════════════════════════════════
// GPUDevice: Abstract GPU device interface
// ═══════════════════════════════════════════════════════════════════════
// Each platform provides a concrete implementation:
//   - MetalGPUDevice (iOS/macOS)
//   - VulkanGPUDevice (Android/HarmonyOS)
//   - NullGPUDevice (testing/headless)
//
// Design principles:
//   1. Handle-based resource management (no raw GPU pointers in user code)
//   2. Descriptors for creation (POD structs, no allocation)
//   3. Thread-safe resource creation, single-thread command submission
//   4. Explicit synchronization points

class GPUDevice {
public:
    virtual ~GPUDevice() = default;

    // ─── Device Info ───
    virtual GraphicsBackend backend() const noexcept = 0;
    virtual GPUCaps capabilities() const noexcept = 0;
    virtual GPUMemoryStats memory_stats() const noexcept = 0;

    // ─── Buffer Management ───
    virtual GPUBufferHandle create_buffer(const GPUBufferDesc& desc) noexcept = 0;
    virtual void destroy_buffer(GPUBufferHandle handle) noexcept = 0;
    virtual void* map_buffer(GPUBufferHandle handle) noexcept = 0;
    virtual void unmap_buffer(GPUBufferHandle handle) noexcept = 0;
    virtual void update_buffer(GPUBufferHandle handle, const void* data,
                               std::size_t offset, std::size_t size) noexcept = 0;

    // ─── Texture Management ───
    virtual GPUTextureHandle create_texture(const GPUTextureDesc& desc) noexcept = 0;
    virtual void destroy_texture(GPUTextureHandle handle) noexcept = 0;
    virtual void update_texture(GPUTextureHandle handle, const void* data,
                                std::uint32_t width, std::uint32_t height,
                                std::uint32_t bytes_per_row) noexcept = 0;

    /// Read back the contents of a texture into a tightly-packed vector
    /// of bytes (no row padding). Returns an empty vector on failure.
    /// Synchronous: the call blocks until the GPU has finished writing
    /// the texture and the data is in the returned vector.
    ///
    /// Used by Phase 6.4 IOSurface bridge (Flutter Texture widget needs
    /// CPU-readable pixels) and Phase 6.5 cross-validation against
    /// MetalSplatter (pixel-by-pixel diff).
    ///
    /// Default impl returns empty vector — backends that don't support
    /// CPU readback (e.g. NullGPUDevice) inherit this no-op safely.
    virtual std::vector<std::uint8_t> readback_texture(
        GPUTextureHandle handle,
        std::uint32_t width,
        std::uint32_t height,
        std::uint32_t bytes_per_pixel) noexcept {
        (void)handle; (void)width; (void)height; (void)bytes_per_pixel;
        return {};
    }

    // ─── Shader Management ───
    virtual GPUShaderHandle load_shader(const char* name,
                                        GPUShaderStage stage) noexcept = 0;
    virtual void destroy_shader(GPUShaderHandle handle) noexcept = 0;

    // ─── Pipeline Management ───
    virtual GPURenderPipelineHandle create_render_pipeline(
        GPUShaderHandle vertex_shader,
        GPUShaderHandle fragment_shader,
        const GPURenderTargetDesc& target_desc) noexcept = 0;
    virtual void destroy_render_pipeline(GPURenderPipelineHandle handle) noexcept = 0;

    virtual GPUComputePipelineHandle create_compute_pipeline(
        GPUShaderHandle compute_shader) noexcept = 0;
    virtual void destroy_compute_pipeline(GPUComputePipelineHandle handle) noexcept = 0;

    // ─── Command Buffer ───
    /// Create a command buffer for GPU work submission.
    /// Returns nullptr if the backend doesn't support command buffers (e.g. NullGPUDevice).
    virtual std::unique_ptr<GPUCommandBuffer> create_command_buffer() noexcept = 0;

    // ─── Synchronization ───
    // Wait for all submitted GPU work to complete.
    virtual void wait_idle() noexcept = 0;

    // Non-copyable
    GPUDevice(const GPUDevice&) = delete;
    GPUDevice& operator=(const GPUDevice&) = delete;

protected:
    GPUDevice() = default;
};

// ═══════════════════════════════════════════════════════════════════════
// NullGPUDevice: No-op implementation for testing and headless mode
// ═══════════════════════════════════════════════════════════════════════

class NullGPUDevice final : public GPUDevice {
public:
    NullGPUDevice() = default;

    GraphicsBackend backend() const noexcept override { return GraphicsBackend::kUnknown; }
    GPUCaps capabilities() const noexcept override { return GPUCaps{}; }
    GPUMemoryStats memory_stats() const noexcept override { return GPUMemoryStats{}; }

    GPUBufferHandle create_buffer(const GPUBufferDesc&) noexcept override {
        return GPUBufferHandle{++next_id_};
    }
    void destroy_buffer(GPUBufferHandle) noexcept override {}
    void* map_buffer(GPUBufferHandle) noexcept override { return nullptr; }
    void unmap_buffer(GPUBufferHandle) noexcept override {}
    void update_buffer(GPUBufferHandle, const void*, std::size_t, std::size_t) noexcept override {}

    GPUTextureHandle create_texture(const GPUTextureDesc&) noexcept override {
        return GPUTextureHandle{++next_id_};
    }
    void destroy_texture(GPUTextureHandle) noexcept override {}
    void update_texture(GPUTextureHandle, const void*, std::uint32_t,
                        std::uint32_t, std::uint32_t) noexcept override {}

    GPUShaderHandle load_shader(const char*, GPUShaderStage) noexcept override {
        return GPUShaderHandle{++next_id_};
    }
    void destroy_shader(GPUShaderHandle) noexcept override {}

    GPURenderPipelineHandle create_render_pipeline(
        GPUShaderHandle, GPUShaderHandle,
        const GPURenderTargetDesc&) noexcept override {
        return GPURenderPipelineHandle{++next_id_};
    }
    void destroy_render_pipeline(GPURenderPipelineHandle) noexcept override {}

    GPUComputePipelineHandle create_compute_pipeline(GPUShaderHandle) noexcept override {
        return GPUComputePipelineHandle{++next_id_};
    }
    void destroy_compute_pipeline(GPUComputePipelineHandle) noexcept override {}

    std::unique_ptr<GPUCommandBuffer> create_command_buffer() noexcept override {
        return nullptr;  // NullGPUDevice: no real GPU
    }

    void wait_idle() noexcept override {}

private:
    std::uint32_t next_id_{0};
};

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_GPU_DEVICE_H
