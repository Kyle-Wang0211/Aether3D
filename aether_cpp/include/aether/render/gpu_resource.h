// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_GPU_RESOURCE_H
#define AETHER_CPP_RENDER_GPU_RESOURCE_H

#ifdef __cplusplus

#include "aether/render/runtime_backend.h"
#include <cstddef>
#include <cstdint>

namespace aether {
namespace render {

// ═══════════════════════════════════════════════════════════════════════
// GPU Resource Enumerations
// ═══════════════════════════════════════════════════════════════════════

enum class GPUStorageMode : std::uint8_t {
    kShared = 0,      // CPU+GPU shared memory (Apple Silicon unified)
    kPrivate = 1,     // GPU-only (fastest on discrete GPUs)
    kManaged = 2,     // CPU-managed with explicit sync (macOS only)
};

enum class GPUBufferUsage : std::uint8_t {
    kVertex   = 1 << 0,
    kIndex    = 1 << 1,
    kUniform  = 1 << 2,
    kStorage  = 1 << 3,  // Compute shader read/write
    kIndirect = 1 << 4,  // Indirect draw/dispatch arguments
    kStaging  = 1 << 5,  // CPU readback
};

enum class GPUTextureFormat : std::uint8_t {
    kR8Unorm = 0,
    kRG8Unorm,
    kRGBA8Unorm,
    kBGRA8Unorm,       // Native display format on Apple (MTLPixelFormatBGRA8Unorm)
    kRGBA8Srgb,
    kR16Float,
    kRG16Float,
    kRGBA16Float,
    kR32Float,
    kRG32Float,
    kRGBA32Float,
    kDepth32Float,
    kDepth32Float_Stencil8,
    kR32Uint,
    kRG32Uint,
    kInvalid = 255,
};

enum class GPUTextureUsage : std::uint8_t {
    kShaderRead  = 1 << 0,
    kShaderWrite = 1 << 1,
    kRenderTarget = 1 << 2,
};

enum class GPUShaderStage : std::uint8_t {
    kVertex = 0,
    kFragment = 1,
    kCompute = 2,
};

enum class GPULoadAction : std::uint8_t {
    kDontCare = 0,
    kLoad = 1,
    kClear = 2,
};

enum class GPUStoreAction : std::uint8_t {
    kDontCare = 0,
    kStore = 1,
};

enum class GPUPrimitiveType : std::uint8_t {
    kTriangle = 0,
    kTriangleStrip = 1,
    kLine = 2,
    kLineStrip = 3,
    kPoint = 4,
};

enum class GPUCullMode : std::uint8_t {
    kNone = 0,
    kFront = 1,
    kBack = 2,
};

enum class GPUWindingOrder : std::uint8_t {
    kClockwise = 0,
    kCounterClockwise = 1,
};

enum class GPUCompareFunction : std::uint8_t {
    kAlways = 0,
    kLess = 1,
    kLessEqual = 2,
    kGreater = 3,
    kGreaterEqual = 4,
};

enum class GPUBlendOperation : std::uint8_t {
    kAdd = 0,
    kSubtract = 1,
    kReverseSubtract = 2,
};

enum class GPUBlendFactor : std::uint8_t {
    kZero = 0,
    kOne = 1,
    kSourceColor = 2,
    kOneMinusSourceColor = 3,
    kDestinationColor = 4,
    kOneMinusDestinationColor = 5,
    kSourceAlpha = 6,
    kOneMinusSourceAlpha = 7,
    kDestinationAlpha = 8,
    kOneMinusDestinationAlpha = 9,
};

// ═══════════════════════════════════════════════════════════════════════
// GPU Resource Descriptors (POD — no virtual, no allocation)
// ═══════════════════════════════════════════════════════════════════════

struct GPUBufferDesc {
    std::size_t size_bytes{0};
    GPUStorageMode storage{GPUStorageMode::kShared};
    std::uint8_t usage_mask{0};  // OR of GPUBufferUsage
    const char* label{nullptr};
};

struct GPUTextureDesc {
    std::uint32_t width{0};
    std::uint32_t height{0};
    std::uint32_t depth{1};
    std::uint32_t mip_levels{1};
    GPUTextureFormat format{GPUTextureFormat::kRGBA8Unorm};
    std::uint8_t usage_mask{0};  // OR of GPUTextureUsage
    GPUStorageMode storage{GPUStorageMode::kPrivate};
    const char* label{nullptr};
};

constexpr std::uint32_t kMaxColorAttachments = 4;

struct GPUColorAttachmentBlendDesc {
    bool blending_enabled{false};
    GPUBlendOperation rgb_blend_op{GPUBlendOperation::kAdd};
    GPUBlendOperation alpha_blend_op{GPUBlendOperation::kAdd};
    GPUBlendFactor source_rgb_blend{GPUBlendFactor::kOne};
    GPUBlendFactor destination_rgb_blend{GPUBlendFactor::kZero};
    GPUBlendFactor source_alpha_blend{GPUBlendFactor::kOne};
    GPUBlendFactor destination_alpha_blend{GPUBlendFactor::kZero};
};

struct GPUColorAttachmentTargetDesc {
    GPUTextureFormat format{GPUTextureFormat::kRGBA8Unorm};
    GPUColorAttachmentBlendDesc blend{};
};

struct GPURenderTargetDesc {
    // Legacy compatibility fields for attachment 0.
    GPUTextureFormat color_format{GPUTextureFormat::kRGBA8Unorm};
    GPUTextureFormat depth_format{GPUTextureFormat::kDepth32Float};
    std::uint32_t width{0};
    std::uint32_t height{0};
    std::uint32_t sample_count{1};
    bool blending_enabled{true};
    bool depth_test_enabled{false};
    bool depth_write_enabled{false};
    GPUCompareFunction depth_compare{GPUCompareFunction::kAlways};

    // Extended pipeline description: multiple color attachments with
    // per-attachment blend state. Attachment 0 falls back to the legacy
    // fields above when callers do not explicitly populate this array.
    std::uint32_t color_attachment_count{1};
    GPUColorAttachmentTargetDesc color_attachments[kMaxColorAttachments]{};

    float clear_color[4]{0.0f, 0.0f, 0.0f, 1.0f};
    float clear_depth{1.0f};
    GPULoadAction color_load{GPULoadAction::kClear};
    GPUStoreAction color_store{GPUStoreAction::kStore};
    GPULoadAction depth_load{GPULoadAction::kClear};
    GPUStoreAction depth_store{GPUStoreAction::kDontCare};
};

struct GPUViewport {
    float origin_x{0.0f};
    float origin_y{0.0f};
    float width{0.0f};
    float height{0.0f};
    float near_depth{0.0f};
    float far_depth{1.0f};
};

struct GPUScissorRect {
    std::uint32_t x{0};
    std::uint32_t y{0};
    std::uint32_t width{0};
    std::uint32_t height{0};
};

// ═══════════════════════════════════════════════════════════════════════
// GPU Resource Handles (type-safe opaque IDs)
// ═══════════════════════════════════════════════════════════════════════
// These are lightweight handles that can be stored in arrays.
// The actual GPU objects live in the backend implementation.

struct GPUBufferHandle {
    std::uint32_t id{0};
    bool valid() const noexcept { return id != 0; }
};

struct GPUTextureHandle {
    std::uint32_t id{0};
    bool valid() const noexcept { return id != 0; }
};

struct GPUShaderHandle {
    std::uint32_t id{0};
    bool valid() const noexcept { return id != 0; }
};

struct GPURenderPipelineHandle {
    std::uint32_t id{0};
    bool valid() const noexcept { return id != 0; }
};

struct GPUComputePipelineHandle {
    std::uint32_t id{0};
    bool valid() const noexcept { return id != 0; }
};

struct GPURenderPassColorAttachmentDesc {
    GPUTextureHandle texture{};
    GPULoadAction load{GPULoadAction::kClear};
    GPUStoreAction store{GPUStoreAction::kStore};
    float clear_color[4]{0.0f, 0.0f, 0.0f, 0.0f};
};

struct GPURenderPassDepthAttachmentDesc {
    GPUTextureHandle texture{};
    GPULoadAction load{GPULoadAction::kClear};
    GPUStoreAction store{GPUStoreAction::kDontCare};
    float clear_depth{1.0f};
};

struct GPURenderPassDesc {
    std::uint32_t width{0};
    std::uint32_t height{0};
    std::uint32_t sample_count{1};
    std::uint32_t color_attachment_count{1};
    GPURenderPassColorAttachmentDesc color_attachments[kMaxColorAttachments]{};
    GPURenderPassDepthAttachmentDesc depth_attachment{};
};

// ═══════════════════════════════════════════════════════════════════════
// GPU Timing & Diagnostics
// ═══════════════════════════════════════════════════════════════════════

struct GPUTimestamp {
    double gpu_time_ms{0.0};
    double cpu_submit_ms{0.0};
    double cpu_complete_ms{0.0};
};

struct GPUMemoryStats {
    std::size_t allocated_bytes{0};
    std::size_t peak_bytes{0};
    std::uint32_t buffer_count{0};
    std::uint32_t texture_count{0};
};

// ═══════════════════════════════════════════════════════════════════════
// Compile-Time GPU Backend Capabilities
// ═══════════════════════════════════════════════════════════════════════

struct GPUCaps {
    GraphicsBackend backend{GraphicsBackend::kUnknown};
    std::uint32_t max_buffer_size{0};
    std::uint32_t max_texture_size{0};
    std::uint32_t max_compute_workgroup_size{0};
    std::uint32_t max_threadgroup_memory{0};
    bool supports_compute{false};
    bool supports_indirect_draw{false};
    bool supports_shared_memory{false};
    bool supports_half_precision{false};
    bool supports_simd_group{false};
    std::uint32_t simd_width{0};  // 32 for Apple, 32/64 for AMD/NVIDIA
};

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_GPU_RESOURCE_H
