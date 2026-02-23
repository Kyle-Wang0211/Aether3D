// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_ISOTROPIC_REMESHER_H
#define AETHER_TSDF_ISOTROPIC_REMESHER_H

#include "aether/core/status.h"
#include "aether/tsdf/mesh_output.h"

#include <cstddef>

namespace aether {
namespace tsdf {

struct RemeshConfig {
    float target_edge_length{0.008f};
    int max_iterations{5};
    float split_threshold_ratio{1.333f};
    float collapse_threshold_ratio{0.8f};
    float smoothing_lambda{0.5f};
    bool adaptive_target{false};
    float curvature_scale{10.0f};
    bool enforce_manifold{true};
    float max_normal_deviation_deg{75.0f};
    bool preserve_boundary_vertices{true};
    bool reject_local_self_intersection{true};
};

struct RemeshResult {
    std::size_t output_vertex_count{0};
    std::size_t output_triangle_count{0};
    std::size_t splits_performed{0};
    std::size_t collapses_performed{0};
    std::size_t flips_performed{0};
    int iterations_used{0};
    std::size_t collapse_reject_nonmanifold{0};
    std::size_t collapse_reject_normal_flip{0};
    std::size_t flip_reject_nonmanifold{0};
    std::size_t collapse_reject_self_intersection{0};
    std::size_t flip_reject_self_intersection{0};
};

float adaptive_target_length(float curvature, float base_length, float curvature_scale);

core::Status isotropic_remesh(
    MeshVertex* vertices,
    std::size_t* vertex_count,
    MeshTriangle* triangles,
    std::size_t* triangle_count,
    std::size_t vertex_capacity,
    std::size_t triangle_capacity,
    const RemeshConfig& config,
    RemeshResult* out_result);

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_ISOTROPIC_REMESHER_H
