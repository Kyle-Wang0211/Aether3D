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
