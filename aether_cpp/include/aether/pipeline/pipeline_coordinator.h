// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_PIPELINE_COORDINATOR_H
#define AETHER_PIPELINE_PIPELINE_COORDINATOR_H

#ifdef __cplusplus

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>
#include <memory>
#include <unordered_set>
#include <vector>

#include "aether_tsdf_c.h"
#include "aether/core/spsc_queue.h"
#include "aether/core/status.h"
#include "aether/core/triple_buffer.h"
#include "aether/capture/frame_selector.h"
#include "aether/render/gpu_device.h"
#include "aether/splat/packed_splats.h"
#include "aether/splat/splat_render_engine.h"
#include "aether/pipeline/depth_inference_engine.h"
#include "aether/pipeline/streaming_pipeline.h"
#include "aether/thermal/thermal_predictor.h"
#include "aether/training/gaussian_training_engine.h"
#include "aether/tsdf/tsdf_volume.h"

namespace aether {
namespace pipeline {

// ═══════════════════════════════════════════════════════════════════════
// PipelineCoordinator: 3-thread unified scan→train→render pipeline
// ═══════════════════════════════════════════════════════════════════════
// Architecture:
//   Thread A (ingestion):  depth→TSDF integrate, surface extraction, GPU dispatch
//   Thread B (evidence):   DS fusion, coverage, quality, admission control
//   Thread C (training):   MVS init → 3DGS training → push_splats
//
// All devices get unified UX: dense point cloud → 3DGS progressive.
// DAv2 depth provided externally (Neural Engine, async, platform-specific).
// MAESTRO predictive thermal management for stability.
//
// Thread safety:
//   on_frame()              — main thread only
//   get_snapshot()          — main thread only (lock-free read)
//   set_thermal_state()    — any thread (atomic)
//   finish_scanning()      — main thread only

// ─── Input/Output Structures ───

/// Frame input from ARKit/camera (passed from Swift main thread).
struct FrameInput {
    std::vector<std::uint8_t> rgba;  // Pixel data copy (RGBA)
    std::uint32_t width{0};
    std::uint32_t height{0};
    float transform[16]{};           // Camera-to-world, column-major
    float intrinsics[9]{};           // 3x3 camera intrinsics
    float feature_points[1024 * 3]{};  // xyz feature points (max 1024), zero-init
    std::uint32_t feature_count{0};

    // Depth from Neural Engine (DAv2, every frame)
    std::vector<float> ne_depth;     // Dense depth map (float32)
    std::uint32_t ne_depth_w{0};
    std::uint32_t ne_depth_h{0};
    bool ne_depth_is_metric{false};  // true = values are absolute meters (metric DAv2/Metric3D)
                                     // false = relative disparity [0,1] → needs affine calibration

    // LiDAR depth (optional, NULL-equivalent if no LiDAR)
    std::vector<float> lidar_depth;
    std::uint32_t lidar_w{0};
    std::uint32_t lidar_h{0};

    bool imported_video{false};
    int imported_intrinsics_source{0};  // 1=real, 2=metadata_35mm, 3=colmap_default
    std::uint32_t source_frame_index{0};
    std::uint32_t source_total_frames{0};
    int thermal_state{0};
    double timestamp{0.0};
};

/// Point cloud vertex for GPU rendering.
struct PointCloudVertex {
    float position[3];
    float color[3];      // sRGB
    float size;          // Point size in pixels
    float alpha;         // Blend alpha (fades out as 3DGS takes over)
};

// ─── Per-Region Quality Heatmap (TSDF voxel-weight driven) ───

/// Overlay vertex for quality heatmap (C++ generates, system layer renders).
/// Each vertex expands into a surface-aligned quad (not billboard).
///
/// "Reverse logic": overlay is VISIBLE on low-quality regions, TRANSPARENT
/// on high-quality (S6+) regions. The Metal shader maps `quality` to:
///   - Color: Red(low) → Orange → Yellow → Green(high) → Transparent
///   - Alpha: high when quality is low, fades to 0 as quality → 1.0
/// This matches the Polycam/Scaniverse UX (overlay disappears as you scan)
/// but SURPASSES them with quality-graded feedback instead of binary coverage.
struct OverlayVertex {
    float position[3];     // World space
    float normal[3];       // Surface normal (for oriented quad)
    float size;            // Quad half-size in world units (meters)
    float quality;         // Composite quality [0,1] — shader maps to color+alpha
};
// sizeof = 32 bytes

/// S6+ quality thresholds (TSDF voxel weight based).
/// weight = min(64, old + obs) monotonically increases → surface certainty.
struct QualityThresholds {
    std::uint8_t overlay_start_weight{2};   // weight≥2 → start faint overlay (was 4)
    std::uint8_t overlay_full_weight{24};   // weight≥24 → S6+ quality (was 32)
    float overlay_alpha_min{0.20f};         // More visible as sole UI element (was 0.15)
    float overlay_alpha_max{0.55f};         // Strong coverage indication at S6+ (was 0.45)
};

/// Overlay vertex budget: NO hard cap.
/// All qualifying TSDF blocks get an overlay tile.
/// 32 bytes per vertex; 50K blocks = 1.6MB — well within GPU budget.
/// Camera-distance sorting ensures nearest blocks are rendered first
/// for best GPU z-buffer utilization.

/// Snapshot from Thread B → Swift main (lock-free triple buffer).
struct EvidenceSnapshot {
    float coverage{0.0f};             // [0, 1]
    float overall_quality{0.0f};      // [0, 1]
    float training_progress{0.0f};    // [0, 1]
    std::size_t frame_count{0};
    std::size_t selected_frames{0};
    std::size_t min_frames_needed{4}; // min_frames_to_start_training (for HUD)
    std::size_t num_gaussians{0};
    bool training_active{false};
    bool scan_complete{false};
    bool has_s6_quality{false};    // True when ANY block reached S6+ (composite_quality ≥ 0.85). DISPLAY ONLY.
    thermal::ThermalLevel thermal_level{thermal::ThermalLevel::kNominal};

    // ── 全局训练状态 ──
    float training_loss{0.0f};                    // Current training loss
    std::size_t training_step{0};                 // Current global training step
    std::size_t assigned_blocks{0};               // Surface blocks → Gaussians (geometry gate, separate from S6+)
    std::size_t pending_gaussian_count{0};        // Gaussians waiting in queue for engine

    // ── Local preview diagnostics (internal archival, cloud leaves zero) ──
    std::uint64_t preview_elapsed_ms{0};
    std::uint64_t preview_phase_depth_ms{0};
    std::uint64_t preview_phase_seed_ms{0};
    std::uint64_t preview_phase_refine_ms{0};
    std::uint32_t preview_depth_batches_submitted{0};
    std::uint32_t preview_depth_results_ready{0};
    std::uint32_t preview_depth_reuse_frames{0};
    std::uint32_t preview_prefilter_accepts{0};
    std::uint32_t preview_prefilter_brightness_rejects{0};
    std::uint32_t preview_prefilter_blur_rejects{0};
    std::uint32_t preview_keyframe_gate_accepts{0};
    std::uint32_t preview_keyframe_gate_rejects{0};
    std::uint32_t preview_seed_candidates{0};
    std::uint32_t preview_seed_accepted{0};
    std::uint32_t preview_seed_rejected{0};
    float preview_seed_quality_mean{0.0f};
    std::uint32_t preview_frames_enqueued{0};
    std::uint32_t preview_frames_ingested{0};
    std::uint32_t preview_frame_backlog{0};
};

/// Observation batch from Thread A → Thread B (SPSC queue).
struct ObservationBatch {
    std::uint32_t frame_index{0};
    float blur_score{0.0f};
    float exposure_score{0.0f};
    float motion_score{0.0f};
    float brightness{0.0f};           // Average frame brightness [0, 255]
    float transform[16]{};
    float intrinsics[9]{};
    // Depth stats for evidence
    float depth_mean{0.0f};
    float depth_variance{0.0f};
    float depth_confidence{1.0f};     // Lowered in low-light
    // Color transform (per-image affine, 6 params)
    float color_affine[6]{1.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f};
    bool frame_selected{false};       // Was this frame selected for training?
};

/// Point cloud + overlay data for GPU (triple-buffered, atomic publish).
struct PointCloudData {
    std::vector<PointCloudVertex> vertices;
    std::vector<OverlayVertex> overlay;   // Quality heatmap billboards
    float blend_alpha{1.0f};  // Global point cloud opacity (fades as 3DGS grows)
    std::size_t tsdf_block_count{0};  // Active TSDF blocks (scan coverage metric)
};

/// Coordinator configuration.
struct CoordinatorConfig {
    // Frame ingestion — TSDF surface point display budget (GPU render limit).
    // TSDF extract_surface_points outputs at most this many points for rendering.
    std::uint32_t max_point_cloud_vertices{5000000}; // 5M GPU display

    // Training (reuses StreamingPipeline config)
    std::size_t min_frames_to_start_training{4};  // 4 frames — start ASAP (heatmap coverage = rendering readiness)
    std::size_t training_batch_size{4};
    float low_quality_loss_weight{0.3f};
    bool local_preview_mode{false};               // Monocular on-device preview path (bounded/faster)
    capture::FrameSelectionConfig frame_selection;
    training::TrainingConfig training;

    // Thermal management
    thermal::ThermalConfig thermal;

    // Low-light adaptation (more lenient with DAv2 depth)
    float low_light_brightness_threshold{40.0f};  // Lower threshold (DAv2 handles dim scenes)
    float low_light_blur_strictness{1.5f};        // Less strict (was 2.0)
    float low_light_depth_weight_min{0.3f};       // Min depth weight in darkness
    std::uint32_t low_light_consecutive_reject_limit{5};  // Pause training if N bad frames

    // Rendering stability
    std::uint32_t max_consecutive_gpu_errors{3};  // → fallback to point cloud
    float nan_check_interval_steps{10};            // Check splats every N steps

    // TSDF→Gaussian creation: geometry-focused gate (NOT composite_quality).
    // Gaussian creation uses: has_surface (≥12 SDF crossings) + avg_weight ≥ 4.
    // composite_quality (0.85 S6+) is display-only (overlay heatmap).
    // See pipeline_coordinator.cpp TSDF→Gaussian section for full criteria.

    // Point cloud → 3DGS transition
    float blend_start_splat_count{1000};    // Start fading point cloud
    float blend_end_splat_count{50000};     // Fully 3DGS

    // Depth inference (DAv2 model paths — dual-model cross-validation)
    // Must point to compiled .mlmodelc directory on iOS/macOS.
    // Set from Swift: Bundle.main.resourcePath + "/DepthAnythingV2Small.mlmodelc"
    // nullptr → that model unavailable. Both nullptr → fallback to MVS-only.
    //
    // Dual-model cross-validation:
    //   Small (~48MB, ~31ms on A14): fast, every frame
    //   Large (~638MB, ~80ms on A14): high quality, every Nth frame
    //   Cross-validation: compare depth maps where both available,
    //   use consensus to filter outliers, improve confidence.
    const char* depth_model_path{nullptr};           // Small model (primary, fast)
    const char* depth_model_path_large{nullptr};     // Large model (cross-validation)
    std::uint32_t large_model_interval{5};           // Run Large every N frames (saves NE bandwidth)
};

class PipelineCoordinator {
public:
    PipelineCoordinator(render::GPUDevice& device,
                        splat::SplatRenderEngine& renderer,
                        const CoordinatorConfig& config) noexcept;
    ~PipelineCoordinator() noexcept;

    // Non-copyable
    PipelineCoordinator(const PipelineCoordinator&) = delete;
    PipelineCoordinator& operator=(const PipelineCoordinator&) = delete;

    // ─── Render Data Snapshot ───

    /// Point cloud + blend state for Metal rendering (main thread read).
    struct RenderSnapshot {
        const PointCloudVertex* pc_vertices{nullptr};
        std::size_t pc_count{0};
        float pc_alpha{1.0f};  // Global point cloud opacity [0→1], fades as 3DGS grows
        std::size_t tsdf_block_count{0};  // Active TSDF blocks (scan coverage)

        // Packed splats from SplatRenderEngine (16 bytes each, PackedSplat format)
        const void* packed_splats{nullptr};
        std::size_t splat_count{0};

        // Quality overlay (C++ generated billboard vertices, ~63KB)
        const OverlayVertex* overlay_vertices{nullptr};
        std::size_t overlay_count{0};
    };

    /// Get latest point cloud render data (lock-free read from triple buffer).
    /// Main thread only. Pointer valid until next call.
    RenderSnapshot get_render_snapshot() noexcept;

    // ─── Main Thread API (must be <0.3ms) ───

    /// Submit a frame. Returns 0=accepted, 1=dropped (queue full).
    int on_frame(const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
                 const float* transform, const float* intrinsics,
                 const float* feature_xyz, std::uint32_t feature_count,
                 const float* ne_depth, std::uint32_t ne_depth_w, std::uint32_t ne_depth_h,
                 const float* lidar_depth, std::uint32_t lidar_w, std::uint32_t lidar_h,
                 int thermal_state) noexcept;

    /// Submit imported-video frame using native bootstrap pose/intrinsics.
    /// Local-preview only; cloud path continues to use explicit camera inputs.
    int on_imported_video_frame(const std::uint8_t* rgba,
                                std::uint32_t w,
                                std::uint32_t h,
                                const float* imported_intrinsics,
                                int imported_intrinsics_source,
                                double timestamp_seconds,
                                std::uint32_t frame_index,
                                std::uint32_t total_frames,
                                int thermal_state) noexcept;

    /// Get latest evidence snapshot (lock-free read from triple buffer).
    EvidenceSnapshot get_snapshot() const noexcept;

    /// Signal that scanning has finished. Training continues to convergence.
    void finish_scanning() noexcept;

    /// Set thermal state. Thread-safe (atomic).
    void set_thermal_state(int level) noexcept;

    /// Set whether the app is currently foreground-active.
    /// Local-preview training pauses GPU work while inactive to avoid iOS
    /// background execution denials and quality loss from CPU fallback.
    void set_foreground_active(bool active) noexcept;

    /// Request additional training after scan completion.
    void request_enhance(std::size_t extra_iterations) noexcept;

    /// Export final PLY (trained Gaussians).
    core::Status export_ply(const char* path) noexcept;

    /// Export accumulated point cloud as Gaussian-format PLY.
    /// Each feature point → tiny Gaussian (3mm radius, identity rotation).
    /// Reuses GaussianSplatViewController for orbit-camera 3D viewing.
    core::Status export_point_cloud_ply(const char* path) noexcept;

    /// Copy TSDF surface sample positions for export-time world-state metrics.
    /// Blocks briefly if Thread A is still accessing the TSDF volume.
    std::size_t copy_surface_points_xyz(float* out_xyz,
                                        std::size_t max_points) noexcept;

    /// Wait for training to reach a minimum quality threshold before export.
    /// Blocks until training reaches min_steps or timeout_seconds elapses.
    /// Call this after finish_scanning() and before export_ply().
    /// Returns the actual step count reached.
    std::size_t wait_for_training(std::size_t min_steps,
                                  double timeout_seconds) noexcept;

    /// Check if training is currently active.
    bool is_training_active() const noexcept;

    /// Service async local-preview bootstrap work (e.g. depth prior results)
    /// even when imported-video ingestion is temporarily idle.
    /// Returns true once a usable cached depth prior exists.
    bool service_local_preview_bootstrap() noexcept;

    /// Check if training is running on GPU (true) or CPU fallback (false).
    /// Returns false before training starts.
    bool is_gpu_training() const noexcept;

    /// Get training progress (lock-free).
    training::TrainingProgress training_progress() const noexcept;

    /// Signal that user has entered the 3D viewer space.
    void signal_viewer_entered() noexcept;

private:
    render::GPUDevice& device_;
    splat::SplatRenderEngine& renderer_;
    CoordinatorConfig config_;

    // ─── Thread A: Frame Ingestion ───
    std::thread frame_thread_;
    core::SPSCQueue<FrameInput, 256> frame_queue_;  // Imported-video local preview needs a true firehose window.
    void frame_thread_func() noexcept;

    // Frame processing helpers
    float compute_brightness(const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept;
    float compute_blur_score(const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept;

    // ─── Thread B: Evidence + Quality ───
    std::thread evidence_thread_;
    core::SPSCQueue<ObservationBatch, 256> evidence_queue_;
    void evidence_thread_func() noexcept;

    // Evidence state
    float accumulated_coverage_{0.0f};
    float accumulated_quality_{0.0f};
    std::uint32_t evidence_frame_count_{0};

    // ─── Thread C: Training (reuses StreamingPipeline) ───
    std::thread training_thread_;
    void training_thread_func() noexcept;

    // Training data
    capture::FrameSelector frame_selector_;
    training::GaussianTrainingEngine* training_engine_{nullptr};
    core::SPSCQueue<pipeline::SelectedFrame, 256> selected_queue_;  // Thread A → C (imported-video preview needs wider bootstrap headroom)

    // ─── Shared State (lock-free) ───
    core::TripleBuffer<EvidenceSnapshot> evidence_snapshot_;
    core::TripleBuffer<PointCloudData> pointcloud_buffer_;
    core::TripleBuffer<SplatUpdate> splat_updates_;  // Thread C → GPU

    // ─── Control Flags ───
    std::atomic<bool> running_{false};
    std::atomic<bool> renderer_alive_{true};   // False after stop_threads(); guards renderer_ access
    std::atomic<bool> scanning_active_{false};
    std::atomic<bool> foreground_active_{true};
    std::atomic<bool> training_started_{false};
    std::atomic<bool> features_frozen_{false};  // Set in finish_scanning; blocks Thread A accumulation
    std::atomic<bool> tsdf_idle_{true};          // Thread A clears during TSDF ops; export waits for idle
    std::atomic<bool> has_s6_quality_{false};    // Thread A sets when ANY TSDF block reaches S6+ (quality ≥ 0.85)
    std::atomic<bool> training_converged_{false}; // Thread C sets on convergence; progress() reads for 100%
    std::atomic<std::size_t> enhance_iters_{0};
    // Dynamic training budget (core-owned): progress denominator adapts to scene scale.
    // Keeps UI progress meaningful for small scans while allowing large scenes to run longer.
    std::atomic<std::size_t> training_target_steps_{20000};
    std::atomic<std::size_t> training_hard_cap_steps_{120000};
    std::atomic<std::uint32_t> frame_counter_{0};
    std::atomic<std::uint32_t> frame_drop_count_{0};  // Frames dropped due to queue overflow
    std::atomic<std::size_t> selected_frame_count_{0};
    std::chrono::steady_clock::time_point preview_started_at_{};
    std::atomic<std::uint64_t> preview_depth_phase_ms_{0};
    std::atomic<std::uint64_t> preview_seed_phase_ms_{0};
    std::atomic<std::uint64_t> preview_refine_phase_ms_{0};
    std::atomic<std::uint32_t> preview_depth_batches_submitted_{0};
    std::atomic<std::uint32_t> preview_depth_results_ready_{0};
    std::atomic<std::uint32_t> preview_depth_reuse_frames_{0};
    std::atomic<std::uint32_t> preview_prefilter_accepts_{0};
    std::atomic<std::uint32_t> preview_prefilter_brightness_rejects_{0};
    std::atomic<std::uint32_t> preview_prefilter_blur_rejects_{0};
    std::atomic<std::uint32_t> preview_keyframe_gate_accepts_{0};
    std::atomic<std::uint32_t> preview_keyframe_gate_rejects_{0};
    std::atomic<std::uint32_t> preview_seed_candidates_{0};
    std::atomic<std::uint32_t> preview_seed_accepted_{0};
    std::atomic<std::uint32_t> preview_seed_rejected_{0};
    std::atomic<std::uint64_t> preview_seed_quality_milli_sum_{0};
    std::atomic<std::uint32_t> preview_frames_enqueued_{0};
    std::atomic<std::uint32_t> preview_frames_ingested_{0};

    // Mutex protecting training_engine_ params during export.
    // Prevents data race: training thread writes params_ while
    // export_ply() reads them on the main thread.
    mutable std::mutex training_export_mutex_;
    mutable std::mutex depth_cache_mutex_;

    // ─── DAv2 Depth Inference — Dual-Model Cross-Validation ───
    // Replaces Swift-layer DepthAnythingV2Bridge.
    // Runs on Neural Engine via CoreML Obj-C++ bridge.
    //
    // Architecture:
    //   depth_engine_small_: runs every frame (~31ms on A14, async)
    //   depth_engine_large_: runs every N frames (~80ms, async, higher quality)
    //   Cross-validation: when both available, compare depth maps.
    //   Consensus depth = weighted average where Small/Large agree (< 15% delta).
    //   Outlier pixels (> 15% delta): use Large's depth (higher quality).
    //   Result: more robust depth than either model alone.
    //
    // On iPhone 12 (A14): Small only is acceptable if Large is too slow.
    // On iPhone 14+: both models concurrently on Neural Engine.
    std::unique_ptr<DepthInferenceEngine> depth_engine_small_;
    std::unique_ptr<DepthInferenceEngine> depth_engine_large_;
    std::uint32_t frame_counter_for_large_{0};   // Counts frames since last Large inference
    std::uint32_t preview_depth_frames_since_submit_{0};

    // Cross-validated depth cache (latest from each model)
    DepthInferenceResult latest_small_depth_;
    DepthInferenceResult latest_large_depth_;
    bool has_small_depth_{false};
    bool has_large_depth_{false};
    float preview_last_depth_request_pos_[3]{0.0f, 0.0f, 0.0f};
    float preview_last_depth_request_fwd_[3]{0.0f, 0.0f, -1.0f};
    bool has_preview_depth_request_{false};

    /// Cross-validate Small vs Large depth maps, output consensus depth.
    /// If only one model available, pass through its depth.
    /// Both empty → returns false.
    bool cross_validate_depth(
        const DepthInferenceResult& small_result,
        const DepthInferenceResult& large_result,
        bool have_small, bool have_large,
        DepthInferenceResult& consensus_out) noexcept;

    // ─── Thermal Management ───
    thermal::ThermalPredictor thermal_predictor_;

    // ─── Low-light State ───
    std::atomic<bool> low_light_mode_{false};
    std::uint32_t consecutive_low_quality_{0};

    // ─── Depth Availability Tracking (Risk A defense) ───
    std::uint32_t no_depth_consecutive_{0};  // Consecutive frames without any depth
    bool lidar_scale_bootstrapped_{false};   // Risk C: LiDAR-bootstrapped metric scale

    // ─── DAv2 Relative-to-Metric Depth: Per-Frame Affine Alignment ───
    // DAv2 outputs min-max normalized [0,1] values. The normalization
    // subtracts the per-frame minimum, introducing a SHIFT that varies
    // every frame. A single scale factor is WRONG — we need full affine:
    //   metric_depth = scale * d_pred + shift
    //
    // Per-frame affine parameters recovered from ARKit feature points via
    // robust iterative least-squares. Feature points provide metric 3D
    // positions (z-depth in camera space) paired with DAv2 depth values.
    //
    // References:
    //   - Murre (2025): RANSAC affine alignment for TSDF fusion
    //   - VIMD (2026): per-pixel scale refinement via ConvGRU
    //   - Prior Depth Anything (2025): coarse-to-fine pixel-level alignment
    //
    // ─── CRITICAL: DAv2 outputs INVERSE DEPTH (disparity-like) ───
    // The model outputs values where larger = closer, smaller = farther.
    // After min-max normalization: d_pred ∈ [0,1], where 1.0 = closest pixel.
    // The correct conversion is RECIPROCAL AFFINE in inverse-depth space:
    //   1/metric_depth = scale * d_pred + shift
    //   metric_depth   = 1 / (scale * d_pred + shift)
    //
    // The WRONG linear model (metric = scale*d + shift) causes ~0.6m errors
    // in mid-range depths because it approximates a hyperbola with a line.
    // This manifests as TSDF blocks placed at wrong positions → floating tiles.
    float dav2_affine_scale_{2.8f};       // Inverse-depth affine: 1/z = scale * d + shift
    float dav2_affine_shift_{0.2f};       // Default: 1/z_max ≈ 1/5m = 0.2
    bool dav2_affine_valid_{false};       // True once first affine fit succeeds
    float prev_cam_x_{0}, prev_cam_y_{0}, prev_cam_z_{0};  // Previous camera position
    bool has_prev_cam_{false};
    std::vector<float> scale_samples_;    // Running scale estimates for diagnostics

    // ─── Overlay throttle cache ───
    // Regenerating overlay from TSDF blocks every frame is CPU-heavy.
    // Cache result and only regenerate every 100ms (was 500ms).
    std::vector<OverlayVertex> overlay_cache_;
    // Last depth-backed surface overlay (TSDF confirmed). Used as a hold frame
    // during temporary no-depth windows so we do not emit floating fallback tiles.
    std::vector<OverlayVertex> last_stable_surface_overlay_;
    std::chrono::steady_clock::time_point overlay_last_gen_time_{};

    // ─── Monotonic tile confirmation (prevents overlay "state regression") ───
    // Once a grid cell passes the depth consistency filter, it is permanently
    // confirmed. Subsequent frames never remove confirmed tiles — only update
    // quality (Lyapunov monotonic: quality only increases). This prevents the
    // visual "flickering" caused by borderline tiles toggling pass/fail as
    // new depth keyframes are added.
    struct ConfirmedTile {
        float position[3];   // Grid-center-snapped position (for rendering)
        float normal[3];     // Smoothed surface normal
        float quality;       // Peak quality (only increases)
        float support_count{1.0f};   // WildGS-style multi-view support count
        float stability{1.0f};       // Bounded anchor stability score [0,1]
        double last_update_ts{0.0};  // Timestamp of last geometric refinement
    };
    std::unordered_map<std::int64_t, ConfirmedTile> confirmed_overlay_cells_;

    // Camera state for overlay frustum culling (updated by Thread A each frame)
    float overlay_cam_pos_[3]{0.0f, 0.0f, 0.0f};
    float overlay_cam_fwd_[3]{0.0f, 0.0f, -1.0f};  // Camera forward (ARKit -col2)

    // ─── Depth keyframe ring buffer for overlay depth-consistency filter ───
    // Stores recent depth frames from different viewpoints to detect phantom tiles.
    // A tile is "depth-consistent" if its projected depth matches the actual depth
    // frame value from multiple cameras. Phantom tiles (from depth estimation errors)
    // float in air and won't match the real surface depth from different angles.
    struct DepthKeyframe {
        std::vector<float> depth;       // Metric depth map (row-major)
        std::vector<unsigned char> conf; // Per-pixel confidence (0=invalid,1=low,2=high)
        int width{0}, height{0};
        float fx{0}, fy{0}, cx{0}, cy{0};  // Intrinsics (scaled to depth resolution)
        float pose[16]{};               // Camera-to-world (column-major, ARKit convention)
        // Color data for Gaussian seed initialization (fix colorHit=0% bug)
        std::vector<unsigned char> rgba;  // Full-res BGRA color frame
        int rgba_w{0}, rgba_h{0};
        float rgba_intrinsics[9]{};        // fx,0,cx,0,fy,cy,0,0,1
    };
    std::vector<DepthKeyframe> depth_keyframes_;
    static constexpr std::size_t kMaxDepthKeyframes = 24;
    float last_keyframe_pos_[3]{0.0f, 0.0f, 0.0f};
    float last_keyframe_fwd_[3]{0.0f, 0.0f, -1.0f};
    bool has_keyframe_{false};
    float preview_last_selected_pos_[3]{0.0f, 0.0f, 0.0f};
    float preview_last_selected_fwd_[3]{0.0f, 0.0f, -1.0f};
    bool has_preview_selected_keyframe_{false};
    bool imported_video_bootstrap_pose_initialized_{false};
    float imported_video_bootstrap_pose_[16]{};
    std::vector<aether_icp_point_t> imported_video_bootstrap_target_points_world_;
    std::vector<aether_icp_point_t> imported_video_bootstrap_target_normals_world_;
    bool imported_video_bootstrap_intrinsics_initialized_{false};
    float imported_video_bootstrap_intrinsics_[9]{};

    // ─── 全局训练 (TSDF 直接初始化) ───
    // S6+ TSDF blocks → Gaussian creation via add_gaussians() (no region clustering).
    std::unordered_set<std::int64_t> assigned_blocks_; // Spatial hash of blocks already assigned Gaussians
    std::unordered_set<std::int64_t> gsf_seeded_cells_; // GSFusion 5mm spatial hash for per-frame dedup
    std::mutex training_mutex_;                         // Protects pending_gaussians_ handoff
    std::vector<splat::GaussianParams> pending_gaussians_; // Thread A → Thread C (TSDF S6+ → Gaussian)

    // ─── Gaussian Creation Rate Limiter (Token Bucket) ───
    // Prevents burst creation of Gaussians when many blocks qualify simultaneously.
    // Smooth flow: max kGaussianBucketCapacity per second, refilled continuously.
    std::size_t gaussian_bucket_tokens_{0};
    std::chrono::steady_clock::time_point gaussian_bucket_last_refill_{};
    bool gaussian_bucket_initialized_{false};
    static constexpr std::size_t kGaussianBucketCapacity = 2000000;  // 2M burst (million-seed target)
    static constexpr std::size_t kGaussianRefillRate = 500000;       // 500K/s (fast refill for bursts)
    bool preview_dav2_seed_initialized_{false};
    std::size_t preview_last_seed_attempt_depth_frames_{0};

    /// Pack block coordinates into int64 spatial hash key.
    static std::int64_t block_hash_key(const tsdf::BlockIndex& idx) noexcept {
        return (static_cast<std::int64_t>(idx.x) << 40) |
               ((static_cast<std::int64_t>(idx.y) & 0xFFFFF) << 20) |
               (static_cast<std::int64_t>(idx.z) & 0xFFFFF);
    }

    // ─── TSDF Volume (replaces accumulated point cloud + quality grid) ───
    // Provides: visualization (surface points), quality tracking (voxel weight),
    // multi-frame depth fusion. Thread A exclusive access.
    // Memory: ~200MB vs old 485MB (480MB point cloud + 5MB quality grid).
    std::unique_ptr<tsdf::TSDFVolume> tsdf_volume_;

    // ─── TSDF-driven Quality Overlay ───
    QualityThresholds quality_thresholds_;

    /// Generate overlay billboard vertices and TSDF→Gaussian seeds.
    /// Uses current frame for world→image color sampling of new Gaussian seeds.
    void generate_overlay_vertices(PointCloudData& pc_data,
                                   const FrameInput& frame_input) noexcept;

    /// GSFusion per-frame quadtree Gaussian seeding.
    /// Builds quadtree on RGB frame, backprojects leaf centres via depth,
    /// deduplicates at 5mm hash cells, pushes to pending_gaussians_.
    void seed_gaussians_per_frame_gsf(
        const unsigned char* bgra, int img_w, int img_h,
        const float* depth, int depth_w, int depth_h,
        float fx, float fy, float cx, float cy,
        const float* cam2world,
        bool imported_video) noexcept;

    // ─── Rendering Stability ───
    std::atomic<std::uint32_t> consecutive_gpu_errors_{0};
    std::atomic<std::uint32_t> render_fallback_level_{0};  // 0=full, 4=camera-only

    // ─── Point Cloud → 3DGS Blend ───
    std::atomic<float> pointcloud_alpha_{1.0f};

    // ─── Lifecycle ───
    void start_threads() noexcept;
    void stop_threads() noexcept;
};

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_PIPELINE_COORDINATOR_H
