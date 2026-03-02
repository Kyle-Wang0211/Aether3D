// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_PIPELINE_COORDINATOR_H
#define AETHER_PIPELINE_PIPELINE_COORDINATOR_H

#ifdef __cplusplus

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <memory>
#include <unordered_set>
#include <vector>

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

    // LiDAR depth (optional, NULL-equivalent if no LiDAR)
    std::vector<float> lidar_depth;
    std::uint32_t lidar_w{0};
    std::uint32_t lidar_h{0};

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

/// Maximum overlay vertices (1 tile per active block, 4K × 20B = 80KB)
/// Capped at 4000 to prevent GPU/CPU overload from rendering too many quads.
static constexpr std::size_t kMaxOverlayPoints = 4000;

// ─── S6+ Quality-Driven Training Region ───
// Formed by connected-component clustering of S6+ TSDF blocks.
// Each region trains independently in temporal order.
// Part of "破镜重圆" (progressive reveal) architecture.

struct TrainingRegion {
    std::uint16_t region_id{0};           // uint16, no artificial limit (0..65535)

    // Spatial extent (world space)
    float aabb_min[3]{};                  // Tight bounding box
    float aabb_max[3]{};
    float centroid[3]{};                  // Geometric center

    // TSDF block membership
    std::vector<tsdf::BlockIndex> blocks; // S6+ blocks in this region
    std::uint32_t block_count{0};

    // Temporal ordering
    double first_s6_timestamp{0.0};       // When first block reached S6+

    // Training state machine
    enum class State : std::uint8_t {
        kPending = 0,     // S6+ reached, queued for training
        kTraining = 1,    // Actively being trained by Thread C
        kConverged = 2,   // Training complete, splats staged as hidden
        kRevealed = 3,    // Fly-in animation complete (fully visible)
        kFailed = 4,      // Training failed, region stays as point cloud
    };
    State state{State::kPending};

    // Training progress
    std::uint32_t current_step{0};
    std::uint32_t max_steps{3000};        // Per-region budget (adaptive)
    float best_loss{1e9f};
    std::uint32_t gaussian_count{0};

    // Frame assignment (indices into all_frames pool in training thread)
    std::vector<std::size_t> frame_indices;

    // Boundary overlap: extended AABB (2 blocks wider for seamless stitching)
    float extended_aabb_min[3]{};
    float extended_aabb_max[3]{};

    // Animation timing (set when viewer_entered triggers reveal)
    double anim_start_time_{0.0};
};

/// Snapshot from Thread B → Swift main (lock-free triple buffer).
struct EvidenceSnapshot {
    float coverage{0.0f};             // [0, 1]
    float overall_quality{0.0f};      // [0, 1]
    float training_progress{0.0f};    // [0, 1]
    std::size_t frame_count{0};
    std::size_t selected_frames{0};
    std::size_t min_frames_needed{4}; // min_frames_to_start_training (for HUD)
    std::size_t num_gaussians{0};
    std::size_t converged_regions{0};
    std::size_t total_regions{0};
    bool training_active{false};
    bool scan_complete{false};
    bool has_s6_quality{false};    // True when ANY TSDF block reached S6+ (quality ≥ 0.85)
    thermal::ThermalLevel thermal_level{thermal::ThermalLevel::kNominal};

    // ── 区域化训练状态 (破镜重圆) ──
    std::uint32_t training_region_total{0};       // Total regions formed
    std::uint32_t training_region_completed{0};   // Converged + revealed
    std::uint16_t active_region_id{0xFFFF};       // Currently training (0xFFFF = none)
    float active_region_progress{0.0f};           // Current region [0, 1]
    bool is_animating{false};                     // Any region doing fly-in
    std::uint32_t staged_count{0};                // Regions waiting to fly in
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

    /// Get latest evidence snapshot (lock-free read from triple buffer).
    EvidenceSnapshot get_snapshot() const noexcept;

    /// Signal that scanning has finished. Training continues to convergence.
    void finish_scanning() noexcept;

    /// Set thermal state. Thread-safe (atomic).
    void set_thermal_state(int level) noexcept;

    /// Request additional training after scan completion.
    void request_enhance(std::size_t extra_iterations) noexcept;

    /// Export final PLY (trained Gaussians).
    core::Status export_ply(const char* path) noexcept;

    /// Export accumulated point cloud as Gaussian-format PLY.
    /// Each feature point → tiny Gaussian (3mm radius, identity rotation).
    /// Reuses GaussianSplatViewController for orbit-camera 3D viewing.
    core::Status export_point_cloud_ply(const char* path) noexcept;

    /// Wait for training to reach a minimum quality threshold before export.
    /// Blocks until training reaches min_steps or timeout_seconds elapses.
    /// Call this after finish_scanning() and before export_ply().
    /// Returns the actual step count reached.
    std::size_t wait_for_training(std::size_t min_steps,
                                  double timeout_seconds) noexcept;

    /// Check if training is currently active.
    bool is_training_active() const noexcept;

    /// Check if training is running on GPU (true) or CPU fallback (false).
    /// Returns false before training starts.
    bool is_gpu_training() const noexcept;

    /// Get training progress (lock-free).
    training::TrainingProgress training_progress() const noexcept;

    // ─── D4: Temporal Region State ("破镜重圆") ───

    /// Get number of temporal regions being tracked.
    std::size_t trained_region_count() const noexcept;

    /// Get state of a specific temporal region.
    /// Returns nullptr if index out of bounds.
    const training::TemporalRegion* get_region_state(
        std::size_t region_idx) const noexcept;

    // ─── 区域化训练 (破镜重圆 Progressive Reveal) ───

    /// Signal that user has entered the 3D viewer space.
    /// Triggers sequential fly-in animation for completed regions.
    void signal_viewer_entered() noexcept;

private:
    render::GPUDevice& device_;
    splat::SplatRenderEngine& renderer_;
    CoordinatorConfig config_;

    // ─── Thread A: Frame Ingestion ───
    std::thread frame_thread_;
    core::SPSCQueue<FrameInput, 8> frame_queue_;  // 8 frames: absorbs thermal hiccups
    void frame_thread_func() noexcept;

    // Frame processing helpers
    float compute_brightness(const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept;
    float compute_blur_score(const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept;

    // ─── Thread B: Evidence + Quality ───
    std::thread evidence_thread_;
    core::SPSCQueue<ObservationBatch, 8> evidence_queue_;
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
    core::SPSCQueue<pipeline::SelectedFrame, 64> selected_queue_;  // Thread A → C

    // ─── Shared State (lock-free) ───
    core::TripleBuffer<EvidenceSnapshot> evidence_snapshot_;
    core::TripleBuffer<PointCloudData> pointcloud_buffer_;
    core::TripleBuffer<SplatUpdate> splat_updates_;  // Thread C → GPU

    // ─── Control Flags ───
    std::atomic<bool> running_{false};
    std::atomic<bool> scanning_active_{false};
    std::atomic<bool> training_started_{false};
    std::atomic<bool> features_frozen_{false};  // Set in finish_scanning; blocks Thread A accumulation
    std::atomic<bool> tsdf_idle_{true};          // Thread A clears during TSDF ops; export waits for idle
    std::atomic<bool> has_s6_quality_{false};    // Thread A sets when ANY TSDF block reaches S6+ (quality ≥ 0.85)
    std::atomic<std::size_t> enhance_iters_{0};
    std::atomic<std::uint32_t> frame_counter_{0};
    std::atomic<std::uint32_t> frame_drop_count_{0};  // Frames dropped due to queue overflow
    std::atomic<std::size_t> selected_frame_count_{0};

    // Mutex protecting training_engine_ params during export.
    // Prevents data race: training thread writes params_ while
    // export_ply() reads them on the main thread.
    mutable std::mutex training_export_mutex_;

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

    // Cross-validated depth cache (latest from each model)
    DepthInferenceResult latest_small_depth_;
    DepthInferenceResult latest_large_depth_;
    bool has_small_depth_{false};
    bool has_large_depth_{false};

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

    // ─── DAv2 Relative-to-Metric Depth Scale (online estimation) ───
    // DAv2 outputs relative depth in [0,1]. To backproject to metric world
    // coordinates, we multiply by this estimated scale.
    // estimate_metric_scale_online() updates this from ARKit baselines.
    float dav2_metric_scale_{2.0f};       // Default: assume 2m mean depth
    float prev_cam_x_{0}, prev_cam_y_{0}, prev_cam_z_{0};  // Previous camera position
    bool has_prev_cam_{false};
    std::vector<float> scale_samples_;    // Running scale estimates for median

    // ─── Overlay throttle cache ───
    // Regenerating overlay from TSDF blocks every frame is CPU-heavy.
    // Cache result and only regenerate every 100ms (was 500ms).
    std::vector<OverlayVertex> overlay_cache_;
    std::chrono::steady_clock::time_point overlay_last_gen_time_{};

    // ─── 区域化训练 (破镜重圆) ───
    // Connected-component clustering of S6+ TSDF blocks → per-region training.
    std::vector<TrainingRegion> training_regions_;
    std::deque<std::uint16_t> region_queue_;           // Pending region IDs (temporal order)
    std::uint16_t next_region_id_{0};
    std::unordered_set<std::int64_t> assigned_blocks_; // Spatial hash of blocks already assigned
    std::mutex regions_mutex_;                          // Protects training_regions_ + staged_regions_

    // ── Animation orchestration ──
    std::atomic<bool> viewer_entered_{false};           // Set by signal_viewer_entered()
    std::vector<std::uint16_t> staged_regions_;         // Completed but not yet animated regions

    /// Form training regions from S6+ TSDF blocks (connected-component clustering).
    /// Called from generate_overlay_vertices() every 500ms.
    void form_training_regions(
        const std::vector<tsdf::BlockQualitySample>& samples) noexcept;

    /// Train a single region (called from training_thread_func).
    void train_single_region(
        TrainingRegion& region,
        const std::vector<pipeline::SelectedFrame>& all_frames) noexcept;

    /// Publish region's trained splats to GPU (initially hidden).
    void publish_region_splats(TrainingRegion& region) noexcept;

    /// Update fly-in animations for all revealed regions (called per-frame).
    void update_region_animations(double dt) noexcept;

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

    /// Generate overlay billboard vertices from TSDF block weights into pc_data.
    void generate_overlay_vertices(PointCloudData& pc_data) noexcept;

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
