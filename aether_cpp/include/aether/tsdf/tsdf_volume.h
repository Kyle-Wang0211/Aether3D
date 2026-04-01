// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_TSDF_VOLUME_H
#define AETHER_TSDF_TSDF_VOLUME_H

#include "aether/tsdf/spatial_hash_table.h"
#include "aether/tsdf/tsdf_types.h"
#include "aether/tsdf/voxel_block.h"
#include <cstdint>
#include <vector>

namespace aether {
namespace tsdf {

/// Surface point extracted from TSDF zero-crossing voxels.
/// Used for real-time visualization (replaces accumulated point cloud).
struct SurfacePoint {
    float position[3];
    float normal[3];     // SDF gradient-based surface normal
    std::uint8_t weight;
    std::uint8_t confidence;
};

/// Per-block quality sample for overlay heatmap.
/// Multi-factor quality assessment for S6+ rendering guarantee.
///
/// Quality score fuses 4 independent signals with cross-validation:
///   1. Geometric quality (TSDF voxel weight → surface certainty)
///   2. Angular diversity (24θ×12φ directional bitmask → multi-view completeness)
///   3. Training coverage (training_obs_count → 3DGS convergence guarantee)
///   4. Depth confidence (avg voxel confidence → depth reliability)
///
/// Theoretically grounded: each signal corresponds to a Fisher Information
/// component. Their product lower-bounds the CRLB for reconstruction error.
struct BlockQualitySample {
    float center[3];
    float normal[3];       // Dominant surface normal (SDF gradient average)
    float avg_weight;
    std::uint32_t occupied_count;
    std::uint16_t training_obs_count;   // Training frames covering this block

    // ── Angular diversity metrics (from 24θ×12φ directional bitmask) ──
    std::uint8_t theta_filled;     // popcount(theta_bits): how many of 24 horizontal dirs observed
    std::uint8_t phi_filled;       // popcount(phi_bits): how many of 12 vertical dirs observed
    std::uint8_t theta_span;       // Circular span in buckets (0-24): max contiguous filled arc
    std::uint8_t phi_span;         // Linear span in buckets (0-12): max-min filled range
    float angular_diversity;       // Composite angular diversity score [0,1]
    float depth_confidence;        // Average voxel confidence [0,1]
    float composite_quality;       // Multi-factor composite quality [0,1]
    float voxel_size;              // Adaptive voxel size (0.005/0.01/0.02) for tile sizing
    bool has_surface;              // True if block contains enough SDF zero-crossings
    std::uint32_t surf_count;      // Number of SDF zero-crossings in this block
    float surface_center[3];       // Average zero-crossing position (actual surface location)
    float normal_consistency;      // [0,1] How aligned the per-crossing normals are.
                                   // 1.0 = all crossings have identical normals (real flat surface).
                                   // 0.0 = chaotic normals (phantom block from depth conflicts).
    float sdf_smoothness;          // [0,1] How smooth the SDF field is (1 = perfectly smooth).
                                   // Computed from Laplacian: real surfaces have linear SDF
                                   // (Laplacian ≈ 0, smoothness ≈ 1). Phantom blocks from
                                   // depth conflicts have noisy SDF (high Laplacian, low smoothness).
};

struct TSDFBlockRuntimeInfo {
    uint32_t integration_generation{0};
    uint32_t mesh_generation{0};
    double last_observed_timestamp{0.0};
};

struct TSDFRuntimeState {
    uint64_t frame_count{0};
    bool has_last_pose{false};
    float last_pose[16]{};
    double last_timestamp{0.0};
    int system_thermal_ceiling{1};
    int current_integration_skip{1};
    int consecutive_good_frames{0};
    int consecutive_rejections{0};
    double last_thermal_change_time_s{0.0};
    int hash_table_size{0};
    int hash_table_capacity{0};
    int current_max_blocks_per_extraction{0};
    int consecutive_good_meshing_cycles{0};
    int forgiveness_window_remaining{0};
    int consecutive_teleport_count{0};
    float last_angular_velocity{0.0f};
    int recent_pose_count{0};
    double last_idle_check_time_s{0.0};
    int memory_water_level{0};
    float memory_pressure_ratio{0.0f};
    double last_memory_pressure_change_time_s{0.0};
    int free_block_slot_count{0};
    int last_evicted_blocks{0};
};

class TSDFVolume {
public:
    TSDFVolume();

    int integrate(const IntegrationInput& input, IntegrationResult& result);
    void handle_thermal_state(int state);
    void handle_memory_pressure(MemoryPressureLevel level);
    void handle_memory_pressure_ratio(float pressure_ratio);
    void apply_frame_feedback(double gpu_time_ms);
    void reset();
    void runtime_state(TSDFRuntimeState* out_state) const;
    void restore_runtime_state(const TSDFRuntimeState& state);
    bool query_block_runtime_info(
        const BlockIndex& block_index,
        TSDFBlockRuntimeInfo* out_info) const;

    int current_integration_skip() const { return current_integration_skip_; }
    int system_thermal_ceiling() const { return system_thermal_ceiling_; }

    /// Number of active TSDF blocks (proxy for scan coverage).
    /// O(N) scan of block pool — call sparingly (e.g. every 500ms).
    std::size_t active_block_count() const {
        std::size_t count = 0;
        for (const auto& b : blocks_) {
            if (b.active) ++count;
        }
        return count;
    }

    /// Extract surface points from zero-crossing voxels for visualization.
    /// Replaces accumulated point cloud (saves ~280MB).
    void extract_surface_points(
        std::vector<SurfacePoint>& out,
        std::size_t max_points) const;

    /// Get per-block quality samples for overlay heatmap.
    /// Non-const: updates peak_quality high-water mark for Lyapunov monotonicity.
    /// @param max_blocks    Maximum number of blocks to iterate (safety cap).
    ///                      Default = unlimited. Pass e.g. 5000 to bound latency
    ///                      to ~50ms regardless of total block count.
    /// @param start_offset  Starting index in the block array (wraps around).
    ///                      Caller increments by max_blocks each call to achieve
    ///                      rotating coverage: each rebuild samples a DIFFERENT
    ///                      slice of the block array, so over N rebuilds all
    ///                      blocks are covered without re-sampling the same ones.
    void get_block_quality_samples(
        std::vector<BlockQualitySample>& out,
        std::size_t max_blocks = ~static_cast<std::size_t>(0),
        std::size_t start_offset = 0);

    /// Mark TSDF blocks visible from a selected training frame.
    /// Increments training_obs_count for each block whose center projects
    /// into the camera frustum. Called when frame_selector passes a frame.
    void mark_training_coverage(
        const float camera_to_world[16],
        float fx, float fy, float cx, float cy,
        std::uint32_t img_width, std::uint32_t img_height);

private:
    enum class MemoryWaterLevel : int {
        kGreen = 0,
        kYellow = 1,
        kOrange = 2,
        kRed = 3,
        kCritical = 4,
    };

    struct BlockRecord {
        BlockIndex index{};
        VoxelBlock block{};
        bool active{false};
        // Peak quality high-water mark (Lyapunov monotonic guarantee).
        // Quality score only increases; once a block reaches S6+ it never regresses.
        // This prevents "state regression" where tiles flash between colors.
        float peak_quality{0.0f};
    };

    SpatialHashTable hash_table_{};
    std::vector<BlockRecord> blocks_{};
    std::vector<int> free_block_slots_{};
    uint64_t frame_count_{0};
    bool has_last_pose_{false};
    float last_pose_[16]{};
    double last_timestamp_{0.0};
    int system_thermal_ceiling_{1};
    int current_integration_skip_{1};
    int consecutive_good_frames_{0};
    int consecutive_rejections_{0};
    double last_thermal_change_time_s_{0.0};
    int current_max_blocks_per_extraction_{0};
    int consecutive_good_meshing_cycles_{0};
    int forgiveness_window_remaining_{0};
    int consecutive_teleport_count_{0};
    float last_angular_velocity_{0.0f};
    int recent_pose_count_{0};
    double last_idle_check_time_s_{0.0};
    MemoryWaterLevel memory_water_level_{MemoryWaterLevel::kGreen};
    float memory_pressure_ratio_{0.0f};
    double last_memory_pressure_change_time_s_{0.0};
    int last_evicted_blocks_{0};

    bool gate_pose_teleport(const float* pose) const;
    bool gate_pose_jitter(const float* pose) const;
    bool gate_integration_skip() const;
    void update_aimd(double frame_time_ms);
    int memory_skip_target() const;
    void apply_memory_pressure_eviction(double now_s);
};

int integrate(const IntegrationInput& input, IntegrationResult& result);
void handle_thermal_state(int state);
void handle_memory_pressure(int level);
void handle_memory_pressure_ratio(float pressure_ratio);
bool query_default_block_runtime_info(
    const BlockIndex& block_index,
    TSDFBlockRuntimeInfo* out_info);

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_TSDF_VOLUME_H
