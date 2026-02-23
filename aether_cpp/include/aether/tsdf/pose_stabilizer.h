// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_POSE_STABILIZER_H
#define AETHER_TSDF_POSE_STABILIZER_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <array>
#include <cstdint>

namespace aether {
namespace tsdf {

struct PoseStabilizerConfig {
    float translation_alpha{0.22f};
    float rotation_alpha{0.18f};
    float max_prediction_horizon_s{0.15f};
    float bias_alpha{0.03f};
    std::uint32_t init_frames{4u};
    bool fast_init{true};
    bool use_ieskf{false};
};

class PoseStabilizer {
public:
    explicit PoseStabilizer(const PoseStabilizerConfig& config = PoseStabilizerConfig());

    void reset();

    core::Status update(
        const float raw_pose_16[16],
        const float gyro_xyz[3],
        const float accel_xyz[3],
        std::uint64_t timestamp_ns,
        float out_stabilized_pose_16[16],
        float* out_pose_quality);

    core::Status predict(
        std::uint64_t target_timestamp_ns,
        float out_predicted_pose_16[16]) const;

private:
    PoseStabilizerConfig config_;
    bool initialized_{false};
    std::uint64_t last_timestamp_ns_{0u};
    std::uint32_t frame_count_{0u};
    float pose_quality_{0.0f};

    std::array<float, 3> filtered_position_{{0.0f, 0.0f, 0.0f}};
    std::array<float, 4> filtered_rotation_{{1.0f, 0.0f, 0.0f, 0.0f}};  // wxyz
    std::array<float, 3> linear_velocity_{{0.0f, 0.0f, 0.0f}};
    std::array<float, 3> angular_velocity_{{0.0f, 0.0f, 0.0f}};
    std::array<float, 3> gyro_bias_{{0.0f, 0.0f, 0.0f}};
    std::array<float, 3> accel_bias_{{0.0f, 0.0f, 0.0f}};
};

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_POSE_STABILIZER_H
