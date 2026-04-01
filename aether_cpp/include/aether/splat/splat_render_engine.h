// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_SPLAT_RENDER_ENGINE_H
#define AETHER_CPP_SPLAT_RENDER_ENGINE_H

#ifdef __cplusplus

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

#include "aether/core/status.h"
#include "aether/render/gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/splat/packed_splats.h"
#include "aether/splat/gaussian_math.h"

namespace aether {
namespace splat {

// ═══════════════════════════════════════════════════════════════════════
// SplatRenderEngine: GPU-accelerated 3DGS rendering orchestrator
// ═══════════════════════════════════════════════════════════════════════
// Renders Gaussian splats using the GPUDevice abstraction layer.
// Platform-independent: works with MetalGPUDevice, VulkanGPUDevice, or
// NullGPUDevice (headless testing).
//
// Rendering pipeline:
//   1. Upload PackedSplats to GPU buffer
//   2. Compute pass: depth calculation + GPU radix sort
//   3. Render pass: instanced quad with EWA projection
//   4. Alpha compositing: front-to-back
//
// Algorithm sources:
//   - gsplat.js RenderProgram.ts: EWA vertex shader math
//   - Spark: PackedSplats format, GPU-assisted sorting, pushSplat() API
//
// Thread safety:
//   - push_splats() is safe to call from training thread
//     (writes go to staging buffer, swapped at begin_frame)
//   - All encode_* calls must be on the same thread (rendering thread)

/// Configuration for the splat render engine.
struct SplatRenderConfig {
    std::size_t max_splats{500000};          // Max Gaussians on GPU
    std::uint32_t sort_precision_bits{32};   // Full 32-bit stable radix sort
    float max_screen_radius{1024.0f};        // Max splat screen radius (gsplat.js)
    std::size_t triple_buffer_count{3};      // Frame-in-flight count
};

/// Per-frame camera state for rendering.
/// Layout MUST match GaussianSplatTypes.h SplatCameraUniforms exactly (224 bytes).
struct SplatCameraState {
    float view[16];          // column-major 4x4 view matrix (world → camera)  — offset 0
    float proj[16];          // column-major 4x4 projection matrix              — offset 64
    float view_proj[16];     // column-major 4x4 viewProj = proj * view         — offset 128
    float fx, fy;            // focal length (pixels)                            — offset 192
    float cx, cy;            // principal point (pixels)                         — offset 200
    std::uint32_t vp_width;  // viewport width                                   — offset 208
    std::uint32_t vp_height; // viewport height                                  — offset 212
    std::uint32_t splat_count; // total splats to process                        — offset 216
    std::uint32_t render_splat_limit; // 0 = unlimited                          — offset 220
};
static_assert(sizeof(SplatCameraState) == 224,
              "SplatCameraState must be 224 bytes to match Metal SplatCameraUniforms");

/// Rendering statistics for the current frame.
struct SplatRenderStats {
    std::size_t total_splats;     // Total splats in buffer
    std::size_t visible_splats;   // Splats passing frustum cull
    std::uint32_t sort_mode;      // 0=none, 1=CPU stable sort, 2=GPU sort
    float sort_time_ms;           // Active sort time (ms)
    float render_time_ms;         // GPU render time (ms)
};

class SplatRenderEngine {
public:
    SplatRenderEngine(render::GPUDevice& device,
                      const SplatRenderConfig& config) noexcept;
    ~SplatRenderEngine() noexcept;

    // Non-copyable, non-movable (owns GPU resources)
    SplatRenderEngine(const SplatRenderEngine&) = delete;
    SplatRenderEngine& operator=(const SplatRenderEngine&) = delete;

    // ─── Data Loading ───

    /// Load Gaussians from a PLY file.
    core::Status load_from_ply(const char* path) noexcept;

    /// Load Gaussians from compressed SPZ data.
    core::Status load_from_spz(const std::uint8_t* data,
                                std::size_t size) noexcept;

    /// Load from pre-parsed GaussianParams array.
    core::Status load_gaussians(const GaussianParams* params,
                                 std::size_t count) noexcept;

    // ─── Incremental Update (Spark pushSplat API) ───

    /// Add Gaussians incrementally (thread-safe for training thread).
    /// Data goes to staging buffer, uploaded at next begin_frame().
    void push_splats(const GaussianParams* params, std::size_t count) noexcept;

    /// D3: Add Gaussians with per-splat region IDs for progressive reveal.
    /// region_ids[] is parallel to params[], one uint8 per splat.
    /// Legacy path (uint8, capped at 255 regions).
    void push_splats_with_regions(const GaussianParams* params,
                                   const std::uint8_t* region_ids,
                                   std::size_t count) noexcept;

    /// 区域化訓練: Add Gaussians with uint16 region IDs (no limit).
    void push_splats_with_regions_u16(const GaussianParams* params,
                                      const std::uint16_t* region_ids,
                                      std::size_t count) noexcept;

    /// D3: Update per-region fade alphas for progressive reveal rendering.
    /// fade_alphas[i] = alpha for region i, range [0,1].
    /// Dynamic: grows to accommodate any number of regions.
    static constexpr std::size_t kMaxRegions = 32;  // Legacy compat, not enforced
    void set_region_fade_alphas(const float* fade_alphas,
                                std::size_t count) noexcept;

    /// Clear all splats.
    void clear_splats() noexcept;

    // ─── Per-Frame Rendering ───

    /// Begin a new frame. Swaps staging buffer if push_splats was called.
    void begin_frame() noexcept;

    /// Set camera state for this frame.
    void update_camera(const SplatCameraState& camera) noexcept;

    /// Encode GPU radix sort compute pass.
    void encode_sort_pass(render::GPUCommandBuffer& cmd) noexcept;

    /// Encode instanced quad render pass (offscreen — creates own textures).
    void encode_render_pass(render::GPUCommandBuffer& cmd,
                            const render::GPURenderTargetDesc& target) noexcept;

    /// Encode instanced quad render pass using a platform-native render pass descriptor.
    /// On Metal: native_rpd is void* to MTLRenderPassDescriptor.
    /// Renders directly into the MTKView's drawable (no offscreen textures).
    void encode_render_pass_native(render::GPUCommandBuffer& cmd,
                                    void* native_rpd) noexcept;

    /// End frame. Returns render stats for profiling.
    SplatRenderStats end_frame() noexcept;

    // ─── Queries ───

    std::size_t splat_count() const noexcept { return splat_count_; }
    bool is_initialized() const noexcept { return initialized_; }

    /// Compute bounding sphere of loaded Gaussians.
    /// center[3] receives the centroid, *radius receives max distance from centroid.
    /// Returns false if no data loaded.
    bool get_bounds(float center[3], float* radius) const noexcept;

    /// Access the CPU-side packed splats buffer (read-only).
    /// Valid until next push_splats() or clear_splats() call.
    const PackedSplatsBuffer& packed_data() const noexcept { return cpu_buffer_; }

    /// Access the CPU-side SH degree-1 buffer (read-only).
    /// Layout is float4[splat_count * 3].
    const std::vector<float>& sh_data() const noexcept { return cpu_sh_data_; }

private:
    static constexpr std::uint32_t kRadixBuckets = 256;
    static constexpr std::uint32_t kRadixThreadgroupSize = 256;

    render::GPUDevice& device_;
    SplatRenderConfig config_;
    bool initialized_{false};

    // Splat data
    PackedSplatsBuffer cpu_buffer_;      // CPU-side packed splats
    PackedSplatsBuffer staging_buffer_;  // Staging for push_splats (training thread writes)
    std::mutex staging_mutex_;           // Protects staging_buffer_, staging_sh_data_,
                                         // staging_region_ids_, staging_dirty_, pending_clear_
    std::size_t splat_count_{0};
    std::size_t render_splat_count_{0};
    bool staging_dirty_{false};
    bool pending_clear_{false};          // Thread-safe: set by clear_splats(), consumed by begin_frame()

    // SH coefficient storage (parallel to PackedSplatsBuffer, lost during 16-byte packing)
    // GPU-ready layout: 12 floats per splat = 3 float4 (R/G/B channels × 3 SH1 basis)
    std::vector<float> cpu_sh_data_;       // Main SH buffer (12 * splat_count floats)
    std::vector<float> staging_sh_data_;   // Staging SH buffer for push_splats

    // D3: Per-splat region IDs (parallel to PackedSplatsBuffer, uint8 per splat)
    // Used for "破镜重圆" progressive reveal: each splat's region determines its fade alpha.
    std::vector<std::uint8_t> cpu_region_ids_;       // Main region IDs (uint8 legacy)
    std::vector<std::uint8_t> staging_region_ids_;   // Staging for push_splats_with_regions
    std::vector<float> region_fade_alphas_;          // Per-region fade alpha [0,1], dynamically sized
    std::size_t active_region_count_{0};             // How many regions have been set
    std::size_t region_fade_gpu_capacity_{0};        // Current GPU buffer capacity for fade alphas

    // GPU resources
    render::GPUBufferHandle splat_buffer_;        // PackedSplat[] on GPU
    render::GPUBufferHandle sh_buffer_;           // float4[N*3] SH coefficients (degree-1)
    render::GPUBufferHandle depth_buffer_;        // uint32[] sortable depth keys
    render::GPUBufferHandle index_buffer_;        // uint32[] sorted indices
    render::GPUBufferHandle camera_buffer_;       // SplatCameraState uniform
    render::GPUBufferHandle quad_buffer_;         // Instanced quad vertices
    // D3: Region fade GPU resources
    render::GPUBufferHandle region_id_buffer_;       // uint8[] per-splat region IDs
    render::GPUBufferHandle region_fade_buffer_;     // float[kMaxRegions] per-region fade alphas

    // Radix sort temporaries
    render::GPUBufferHandle sort_temp_indices_;   // uint32[] ping-pong index buffer
    render::GPUBufferHandle sort_histogram_;      // uint32[groupCount * 256] per-group bucket offsets

    // Pipeline state handles
    render::GPUComputePipelineHandle depth_pipeline_;
    render::GPUComputePipelineHandle clear_hist_pipeline_;    // radixClearHistogram
    render::GPUComputePipelineHandle histogram_pipeline_;     // radixHistogram
    render::GPUComputePipelineHandle prefix_sum_pipeline_;    // radixPrefixSum
    render::GPUComputePipelineHandle scatter_pipeline_;       // radixScatter
    render::GPURenderPipelineHandle  render_pipeline_;
    // Camera
    SplatCameraState camera_{};

    // Stats
    SplatRenderStats stats_{};

    // CPU depth sort fallback when GPU radix pipelines are unavailable.
    std::vector<std::uint32_t> cpu_sort_indices_;
    std::vector<float> cpu_sort_depths_;
    bool cpu_stable_sort_active_{false};

    // Internal methods
    core::Status create_gpu_resources() noexcept;
    void destroy_gpu_resources() noexcept;
    void upload_splats_to_gpu() noexcept;
    bool should_prefer_cpu_stable_sort() const noexcept;
    void cpu_depth_sort() noexcept;
    void push_splats_locked(const GaussianParams* params,
                             std::size_t count) noexcept;  // Must hold staging_mutex_
};

}  // namespace splat
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_SPLAT_RENDER_ENGINE_H
