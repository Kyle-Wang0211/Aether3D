// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_POSE_GRAPH_H
#define AETHER_TSDF_POSE_GRAPH_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct PoseGraphNode {
    std::uint32_t id{0};
    float pose[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };
    bool fixed{false};
};

struct PoseGraphEdge {
    std::uint32_t from_id{0};
    std::uint32_t to_id{0};
    float transform[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };
    float information[36] = {0.0f};
    bool is_loop{false};
};

struct PoseGraphConfig {
    int max_iterations{20};
    float step_size{0.2f};
    float huber_delta{0.02f};
    float stop_translation{1e-4f};
    float stop_rotation{1e-4f};
    float watchdog_max_diag_ratio{1e3f};
    int watchdog_max_residual_rise{2};
};

struct PoseGraphResult {
    int iterations{0};
    float initial_error{0.0f};
    float final_error{0.0f};
    float watchdog_diag_ratio{1.0f};
    bool watchdog_tripped{false};
    bool converged{false};
};

core::Status optimize_pose_graph(
    PoseGraphNode* nodes,
    std::size_t node_count,
    const PoseGraphEdge* edges,
    std::size_t edge_count,
    const PoseGraphConfig& config,
    PoseGraphResult* out_result);

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_POSE_GRAPH_H
