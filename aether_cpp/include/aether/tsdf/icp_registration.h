// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_ICP_REGISTRATION_H
#define AETHER_TSDF_ICP_REGISTRATION_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct ICPPoint {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

struct ICPConfig {
    int max_iterations{20};
    float distance_threshold{0.03f};
    float normal_threshold_deg{65.0f};
    float huber_delta{0.01f};
    float convergence_translation{1e-5f};
    float convergence_rotation{1e-4f};
    float watchdog_max_diag_ratio{1e3f};
    int watchdog_max_residual_rise{2};
};

struct ICPResult {
    float pose_out[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };
    int iterations{0};
    int correspondence_count{0};
    float rmse{0.0f};
    float watchdog_diag_ratio{1.0f};
    bool watchdog_tripped{false};
    bool converged{false};
};

core::Status icp_refine(
    const ICPPoint* source_points,
    std::size_t source_count,
    const ICPPoint* target_points,
    std::size_t target_count,
    const ICPPoint* target_normals,
    const float initial_pose[16],
    float angular_velocity,
    const ICPConfig& config,
    ICPResult* out_result);

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_ICP_REGISTRATION_H
