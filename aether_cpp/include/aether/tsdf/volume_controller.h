// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_VOLUME_CONTROLLER_H
#define AETHER_TSDF_VOLUME_CONTROLLER_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/tsdf/thermal_engine.h"

#include <cstdint>

namespace aether {
namespace tsdf {

enum class TrackingState : std::int32_t {
    kUnavailable = 0,
    kLimited = 1,
    kNormal = 2,
};

enum class MemoryPressure : std::int32_t {
    kGreen = 0,
    kYellow = 1,
    kOrange = 2,
    kRed = 3,
    kCritical = 4,
};

struct PlatformSignals {
    // Legacy signals kept for bridge compatibility.
    std::int32_t thermal_level{2};          // 0..9
    float thermal_headroom{1.0f};           // 0..1
    std::int32_t memory_water_level{0};     // 0..4

    // Canonical signals for P8.
    AetherThermalState thermal{};
    MemoryPressure memory{MemoryPressure::kGreen};
    TrackingState tracking{TrackingState::kNormal};
    float camera_pose[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };
    float angular_velocity{0.0f};           // rad/s
    float frame_actual_duration_ms{0.0f};
    std::int32_t valid_pixel_count{0};
    std::int32_t total_pixel_count{0};
    double timestamp_s{0.0};

    // Altitude fields (G15 integration)
    float altitude_meters{0.0f};
    std::int32_t floor_level{0};
    std::uint32_t altitude_source_mask{0};
    float altitude_confidence{0.0f};
};

struct VolumeControllerState {
    std::uint64_t frame_counter{0};
    std::int32_t integration_skip_rate{1};
    std::int32_t consecutive_good_frames{0};
    std::int32_t consecutive_bad_frames{0};
    double consecutive_good_time_s{0.0};
    double consecutive_bad_time_s{0.0};
    std::int32_t system_thermal_ceiling{1};
    std::int32_t memory_skip_floor{1};
    double last_update_s{0.0};
};

struct ControllerDecision {
    bool should_skip_frame{false};
    std::int32_t integration_skip_rate{1};
    bool should_evict{false};
    std::int32_t blocks_to_evict{0};
    bool is_keyframe{false};
    std::int32_t blocks_to_preallocate{0};
    float quality_weight{1.0f};
};

core::Status volume_controller_decide(
    const PlatformSignals& signals,
    VolumeControllerState* state,
    ControllerDecision* out_decision);

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_VOLUME_CONTROLLER_H
