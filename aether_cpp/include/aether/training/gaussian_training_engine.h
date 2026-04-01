// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TRAINING_GAUSSIAN_TRAINING_ENGINE_H
#define AETHER_TRAINING_GAUSSIAN_TRAINING_ENGINE_H

#ifdef __cplusplus

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "aether/core/status.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/packed_splats.h"
#include "aether/training/adam_optimizer.h"
#include "aether/training/device_preset.h"
#include "aether/training/memory_budget.h"

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// GaussianTrainingEngine: On-device 3DGS training
// ═══════════════════════════════════════════════════════════════════════
// Manages the full training loop:
//   1. MVS initialization (dense point cloud from frames)
//   2. Differentiable rendering (forward pass → GPU rasterize)
//   3. Loss computation (L1 + D-SSIM)
//   4. Backward pass (gradient computation)
//   5. Adam optimizer step
//   6. Densification (clone/split) and pruning
//
// Called from StreamingPipeline's training thread.
// GPU work dispatched via GPUDevice on a dedicated command queue.

struct TrainingConfig {
    // ═══════════════════════════════════════════════════════════════
    // Training parameters — calibrated against SOTA (Sprint 3)
    // ═══════════════════════════════════════════════════════════════
    // Reference (minimums to surpass):
    //   3DGS-MCMC: 30K iters, grad_thresh=0.0002, densify_interval=100
    //   gsplat:    30K iters, lr_pos=1.6e-4, ssim_lambda=0.2
    //   SSS:       30K iters, 83-624K Student-t, 29.9dB PSNR
    //   PocketGS:  500 iters, 33-168K gaussians, 23.5dB
    // Our target: ≥31dB, no artificial Gaussian cap — device preset is the real limit

    std::size_t max_gaussians{100000000};      // 100M = effectively unlimited; device preset caps to real limit
    std::size_t max_iterations{3000};          // Global engine: TSDF init + MCMC converges in ~2-3K steps

    // Learning rates (match SOTA standard: 3DGS-MCMC, gsplat, SSS)
    float lr_position{0.00016f};               // Matches all SOTA exactly
    float lr_color{0.0025f};                   // SH band-0 (gsplat: sh0_lr=0.0025)
    float lr_opacity{0.05f};                   // Universal standard
    float lr_scale{0.005f};                    // Universal standard
    float lr_rotation{0.001f};                 // Universal standard

    // Densification (Fraunhofer 2025 adaptive + MCMC hybrid)
    std::size_t densify_interval{100};         // 3DGS-MCMC: 100 (standard)
    float densify_grad_threshold{0.00005f};    // Adaptive init (rises to 0.0005)
    float densify_max_screen_size{20.0f};      // Max 2D size for split

    // Pruning (MCMC importance + floater suppression)
    float prune_opacity_threshold{0.005f};
    std::size_t prune_interval{100};

    // Loss (3DGS-MCMC, gsplat: lambda_dssim=0.2)
    float lambda_dssim{0.2f};

    // Training resolution (device preset overrides)
    std::uint32_t render_width{800};
    std::uint32_t render_height{600};

    // Local-preview baseline mode: align training closer to baseline 3DGS /
    // repo-original semantics by disabling Aether-specific training extras.
    bool align_to_baseline_3dgs{false};

};

struct TrainingProgress {
    std::size_t step{0};
    std::size_t total_steps{0};
    float loss{0.0f};
    std::size_t num_gaussians{0};
    bool is_complete{false};
};

/// Training frame stored in memory for sampling.
struct TrainingFrame {
    std::vector<std::uint8_t> rgba;  // Pixel data (RGBA)
    std::uint32_t width;
    std::uint32_t height;
    std::vector<std::vector<std::uint8_t>> pyramid_rgba;  // Photo-SLAM-style image pyramid
    std::vector<std::uint32_t> pyramid_widths;
    std::vector<std::uint32_t> pyramid_heights;
    float transform[16];             // Camera-to-world
    float intrinsics[4];             // [fx, fy, cx, cy]
    float quality_weight;            // Loss weight (1.0 for S5+, 0.3 for S0-S4)
    int remaining_times_of_use{0};   // Photo-SLAM-style usage budget

    // Bug 0.26 fix: temporal metadata for time-ordered focal training.
    double timestamp{0.0};           // Capture timestamp (seconds since epoch)
    std::uint64_t frame_index{0};    // Sequential frame index from capture

    // B6: DAv2 relative depth for Pearson-invariant depth supervision.
    // May be empty if depth unavailable for this frame.
    std::vector<float> ref_depth;    // Relative depth [0,1] from DAv2
    std::uint32_t ref_depth_w{0};    // Reference depth width
    std::uint32_t ref_depth_h{0};    // Reference depth height

    // LiDAR metric depth (optional, Pro devices only — "120% enhancement").
    // Direct metric depth in meters from ARKit sceneDepth.
    // Empty on non-LiDAR devices. Provides absolute L1 depth constraint.
    std::vector<float> lidar_depth;  // Metric depth [meters]
    std::uint32_t lidar_w{0};
    std::uint32_t lidar_h{0};
};

class GaussianTrainingEngine {
public:
    GaussianTrainingEngine(render::GPUDevice& device,
                           const TrainingConfig& config) noexcept;
    ~GaussianTrainingEngine() noexcept;

    // Non-copyable
    GaussianTrainingEngine(const GaussianTrainingEngine&) = delete;
    GaussianTrainingEngine& operator=(const GaussianTrainingEngine&) = delete;

    // ─── Data Management (called from streaming pipeline) ───

    /// Set initial point cloud from MVS.
    core::Status set_initial_point_cloud(
        const splat::GaussianParams* pts, std::size_t count) noexcept;

    /// Add a training frame (image + pose + temporal metadata + optional depth).
    /// @param ref_depth    DAv2 relative depth [0,1] (100% experience, all phones)
    /// @param lidar_depth  LiDAR metric depth [meters] (120% enhancement, Pro only)
    void add_training_frame(const std::uint8_t* rgba,
                            std::uint32_t w, std::uint32_t h,
                            const float transform[16],
                            const float intrinsics[4],
                            float quality_weight = 1.0f,
                            double timestamp = 0.0,
                            std::uint64_t frame_index = 0,
                            const float* ref_depth = nullptr,
                            std::uint32_t ref_depth_w = 0,
                            std::uint32_t ref_depth_h = 0,
                            const float* lidar_depth = nullptr,
                            std::uint32_t lidar_w = 0,
                            std::uint32_t lidar_h = 0) noexcept;

    /// Number of training frames added.
    std::size_t frame_count() const noexcept { return frames_.size(); }

    /// Append additional Gaussians to a running engine (global training mode).
    /// Reuses optimizer_.grow() pattern from densify_and_prune().
    /// Thread-safe: called from pipeline coordinator while train_step() runs.
    /// @param pts    GaussianParams in natural space (positions, real opacity/scale)
    /// @param count  Number of Gaussians to add
    /// @return kOk or kInvalidArgument
    core::Status add_gaussians(
        const splat::GaussianParams* pts, std::size_t count) noexcept;

    // ─── Training Loop ───

    /// Execute one training step: forward → loss → backward → adam → densify?
    core::Status train_step() noexcept;

    /// Current progress (lock-free read).
    TrainingProgress progress() const noexcept;

    // ─── Thermal Management ───

    /// Set thermal state (0=nominal, 1=elevated, 2=serious, 3=critical).
    /// Higher levels reduce training frequency.
    void set_thermal_state(int level) noexcept;

    // ─── Export ───

    /// Export all Gaussians.
    core::Status export_gaussians(
        std::vector<splat::GaussianParams>& out) const noexcept;

    /// Export to PLY file.
    core::Status export_ply(const char* path) const noexcept;

    /// Whether training is running on GPU (true) or CPU fallback (false).
    bool is_gpu_training() const noexcept { return gpu_training_ready_; }

    /// Current Gaussian count.
    std::size_t gaussian_count() const noexcept { return num_gaussians_; }

    /// Signal that training should stop ASAP. Called before deletion to
    /// prevent train_step_gpu() from accessing GPU buffers during shutdown.
    void request_stop() noexcept { stop_requested_.store(true, std::memory_order_release); }

private:
    render::GPUDevice& device_;
    TrainingConfig config_;

    // Gaussian parameters (flattened: N * 14 floats)
    std::vector<float> params_;      // [pos(3), color(3), opacity(1), scale(3), rot(4)] per gaussian
    std::vector<float> gradients_;   // Same layout as params_
    std::size_t num_gaussians_{0};

    // Adam optimizer
    AdamOptimizer optimizer_;

    // Training frames
    std::vector<TrainingFrame> frames_;

    // Rendered image buffer (CPU, for loss computation)
    std::vector<float> rendered_image_;
    std::vector<float> target_image_;
    std::vector<float> cpu_rendered_depth_;  // B6: CPU-side rendered depth for Pearson loss

    // Reusable per-step buffers (class members to avoid per-step heap allocation)
    std::vector<float> cpu_transmittance_;   // W×H, reused in forward + backward
    std::vector<float> cpu_image_grad_;      // W×H×3, reused in backward pass
    std::vector<float> cpu_depth_grad_;      // W×H, reused in depth loss

    // Pre-allocated zero buffers (avoid per-step heap allocation in gradient clear).
    // Re-used across steps; grown on demand after densification.
    std::vector<float> zero_buf_float_;
    std::vector<std::uint32_t> zero_buf_uint_;

    // Densification statistics
    std::vector<float> screen_grad_accum_;  // Accumulated screen-space gradients
    std::vector<std::uint32_t> grad_count_; // Count of gradient accumulations

    // Training stability: NaN/Inf rollback snapshot
    std::vector<float> params_snapshot_;
    std::size_t nan_rollback_count_{0};

    // ── C1: Student-t Primitive Support (SSS, CVPR 2025) ──
    // Each Gaussian has an extra nu parameter (degrees of freedom).
    // Stored separately from params_[] to avoid breaking kParamsPerGaussian=14.
    // nu = exp(log_nu) + 2.0, heavy tails → 82% fewer primitives @ same quality.
    bool use_student_t_{true};               // Enable Student-t (default: ON for S6+)
    std::vector<float> nu_params_;           // log(nu-2) per Gaussian (parallel to params_)
    std::vector<float> nu_grad_;             // Nu gradients
    std::vector<float> nu_m1_, nu_m2_;       // Adam moments for nu
    static constexpr float kNuLrInit = 0.01f; // Learning rate for nu parameter

    // ── C2: MCMC Noise Injection (3DGS-MCMC, NeurIPS 2024) ──
    bool use_mcmc_noise_{true};              // Enable SGLD noise (default: ON)

    // ── C2b: SteepGS Saddle Escape (CVPR 2025, Meta) ──
    bool use_steepgs_{true};                 // Enable saddle detection (default: ON)
    std::vector<float> prev_position_grad_;  // Previous position gradients (for Hessian est.)
    std::vector<float> prev_position_;       // Previous positions

    // Last rendered frame index (for backward pass to use the same camera)
    std::size_t last_frame_idx_{0};

    // B1: Device preset (applied at construction time)
    DevicePreset preset_{};

    // Memory budget controller — per-Gaussian accounting + OOM protection.
    // Automatically switches from kFull → kCompact → kMinimal as Gaussian
    // count grows. Controls Student-t/SteepGS enable, densification gates.
    MemoryBudgetController memory_budget_;

    // B3: Temporal-focal training state
    std::size_t focal_window_start_{0};  // Start index of focal window in frames_

    // B7: Opacity reset tracking
    std::size_t last_opacity_reset_step_{0};

    // Progress (atomic for lock-free reading)
    std::atomic<std::size_t> current_step_{0};
    std::atomic<float> current_loss_{0.0f};
    std::atomic<int> thermal_state_{0};
    std::atomic<bool> stop_requested_{false};  // Set by request_stop() for early exit

    // GPU params round-trip optimization: skip upload/download when GPU already has latest.
    // Set true after CPU modifies params_ (init, densification, NaN rollback).
    // Set false after upload_gaussians_to_gpu() — GPU is authoritative until next CPU mod.
    bool cpu_params_modified_{true};

    // ── Position Anchor Regularization ──
    // Stores initial positions (x,y,z) per Gaussian. Penalizes drift from surface.
    // L_anchor = lambda * ||pos - anchor||^2, gradient = 2*lambda*(pos - anchor).
    // Decays over training: strong early (geometry settling), weak late (fine detail).
    std::vector<float> anchor_positions_;  // N*3 floats (x,y,z per Gaussian)

    // ── GPU Resources ──
    bool gpu_training_ready_{false};  // True when GPU pipeline is initialized

    // ── GPU Error Recovery ──
    // After a GPU error (IOGPUMetalError), wait before retrying.
    // Exponential backoff: 2s, 4s, 8s, 16s, 32s. Max 5 retries then permanent disable.
    // Increased from 3→5 retries: transient GPU errors (thermal, memory pressure)
    // often recover after a longer cooldown.
    int gpu_fail_count_{0};
    std::chrono::steady_clock::time_point gpu_fail_time_{};
    static constexpr int kMaxGPURetries = 5;

    // Core data buffers
    render::GPUBufferHandle gaussian_buffer_;      // N × 14 floats (params)
    render::GPUBufferHandle gradient_buffer_;       // N × 14 floats (gradients)
    render::GPUBufferHandle rendered_buffer_;       // W×H×3 floats
    render::GPUBufferHandle target_buffer_;         // W×H×3 floats
    render::GPUBufferHandle training_uniform_buffer_;

    // Tile rasterization buffers
    render::GPUBufferHandle projected_buffer_;      // N × ProjectedGaussian
    render::GPUBufferHandle depth_keys_buffer_;     // N × uint32 (sortable depth)
    render::GPUBufferHandle sort_indices_buffer_;   // N × uint32
    render::GPUBufferHandle sort_keys_tmp_;         // N × uint32 (sort scratch)
    render::GPUBufferHandle sort_vals_tmp_;         // N × uint32 (sort scratch)
    render::GPUBufferHandle sort_histogram_;        // 256 × uint32
    render::GPUBufferHandle transmittance_buffer_;  // W×H floats
    render::GPUBufferHandle last_contributor_buf_;  // W×H uint32
    render::GPUBufferHandle rendered_depth_buffer_;  // B5: W×H floats (rendered depth)
    render::GPUBufferHandle image_grad_buffer_;     // W×H×3 floats
    render::GPUBufferHandle absgrad_buffer_;        // N × uint32 (atomic float)
    render::GPUBufferHandle grad_count_gpu_buf_;    // N × uint32 (atomic)
    render::GPUBufferHandle adam_moments_buffer_;   // N × AdamMoments
    render::GPUBufferHandle cov2d_grad_buffer_;    // N × 3 (atomic float: dL/d(c00,c01,c11))

    // ── GPU Depth Supervision (dual depth source) ──
    render::GPUBufferHandle ref_depth_buffer_;         // DAv2 relative depth (1024×1024 max)
    render::GPUBufferHandle lidar_depth_buffer_;        // LiDAR metric depth (256×192)
    render::GPUBufferHandle depth_grad_buffer_;         // Combined depth gradient (W×H)
    render::GPUBufferHandle depth_stats_buffer_;        // Pearson statistics (8 floats)
    render::GPUBufferHandle depth_partial_sums_buffer_; // Partial reduction (groups×7)
    render::GPUBufferHandle depth_config_buffer_;       // DepthConfig struct (48 bytes)

    render::GPUComputePipelineHandle depth_reduce_partial_pipeline_;
    render::GPUComputePipelineHandle depth_reduce_final_pipeline_;
    render::GPUComputePipelineHandle depth_gradient_pipeline_;
    render::GPUComputePipelineHandle tangent_project_pipeline_;

    bool depth_gpu_ready_{false};  // True when all depth buffers + pipelines valid

    // Compute pipelines
    render::GPUComputePipelineHandle preprocess_pipeline_;
    render::GPUComputePipelineHandle forward_pipeline_;
    render::GPUComputePipelineHandle l1_gradient_pipeline_;
    render::GPUComputePipelineHandle backward_pipeline_;
    render::GPUComputePipelineHandle adam_pipeline_;
    render::GPUComputePipelineHandle densify_pipeline_;
    render::GPUComputePipelineHandle compact_pipeline_;
    render::GPUComputePipelineHandle sort_histogram_pipeline_;
    render::GPUComputePipelineHandle sort_prefix_sum_pipeline_;
    render::GPUComputePipelineHandle sort_scatter_pipeline_;
    render::GPUComputePipelineHandle sort_clear_pipeline_;
    render::GPUComputePipelineHandle scale_rot_grad_pipeline_;

    // ── Internal methods ──
    core::Status create_gpu_resources() noexcept;
    void upload_gaussians_to_gpu() noexcept;
    void download_gradients_from_gpu() noexcept;

    // CPU path (current, correct)
    void forward_render(std::size_t frame_idx) noexcept;
    void backward_pass() noexcept;

    // GPU path (tile-based)
    core::Status train_step_gpu() noexcept;
    void gpu_radix_sort(render::GPUComputeEncoder* enc,
                        std::uint32_t count) noexcept;

    void densify_and_prune() noexcept;

    // B3: Temporal-focal frame sampling (replaces uniform random)
    std::size_t sample_focal_frame() noexcept;
    void build_training_pyramid(TrainingFrame& frame) const noexcept;
    std::size_t training_frame_budget() const noexcept;
    void trim_training_frames() noexcept;
    std::size_t select_pyramid_level(const TrainingFrame& frame,
                                     std::uint32_t target_w,
                                     std::uint32_t target_h) const noexcept;
    void prepare_target_image_from_frame(const TrainingFrame& frame,
                                         std::uint32_t target_w,
                                         std::uint32_t target_h) noexcept;
    void sample_frame_color(const TrainingFrame& frame,
                            float px,
                            float py,
                            std::uint32_t target_w,
                            std::uint32_t target_h,
                            float rgb[3]) const noexcept;

    // B7: Opacity reset (every N steps, reset all opacities to near-zero)
    void maybe_opacity_reset() noexcept;

    // Flatten/unflatten between GaussianParams and float[]
    void params_to_flat(const splat::GaussianParams* src, std::size_t count) noexcept;
    void flat_to_params(splat::GaussianParams* dst, std::size_t count) const noexcept;
};

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_GAUSSIAN_TRAINING_ENGINE_H
