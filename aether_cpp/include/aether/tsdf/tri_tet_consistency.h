// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TSDF_TRI_TET_CONSISTENCY_H
#define AETHER_CPP_TSDF_TRI_TET_CONSISTENCY_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/math/vec3.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct TriTetTriangle {
    math::Vec3 a{};
    math::Vec3 b{};
    math::Vec3 c{};
};

struct TriTetVertex {
    std::int32_t index{0};
    math::Vec3 position{};
    std::int32_t view_count{0};
};

struct TriTetTetrahedron {
    std::int32_t id{0};
    std::int32_t v0{0};
    std::int32_t v1{0};
    std::int32_t v2{0};
    std::int32_t v3{0};
};

struct TriTetConfig {
    std::int32_t measured_min_view_count{4};
    std::int32_t estimated_min_view_count{2};
    float max_triangle_to_tet_distance{0.10f};
};

enum class TriTetConsistencyClass : std::uint8_t {
    kMeasured = 0u,
    kEstimated = 1u,
    kUnknown = 2u,
};

struct TriTetBinding {
    std::int32_t triangle_index{-1};
    std::int32_t tetrahedron_id{-1};
    TriTetConsistencyClass classification{TriTetConsistencyClass::kUnknown};
    float tri_to_tet_distance{0.0f};
    std::int32_t min_tet_view_count{0};
};

struct TriTetReport {
    float combined_score{0.0f};
    std::int32_t measured_count{0};
    std::int32_t estimated_count{0};
    std::int32_t unknown_count{0};
};

// Writes Kuhn 5-tet table as 20 ints: [tet0_v0,tet0_v1,tet0_v2,tet0_v3,...].
core::Status kuhn5_table(int parity, int out_vertices[20]);

core::Status evaluate_tri_tet_consistency(
    const TriTetTriangle* triangles,
    std::size_t triangle_count,
    const TriTetVertex* vertices,
    std::size_t vertex_count,
    const TriTetTetrahedron* tetrahedra,
    std::size_t tetrahedron_count,
    const TriTetConfig& config,
    TriTetBinding* out_bindings,
    std::size_t binding_capacity,
    TriTetReport* out_report);

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_TSDF_TRI_TET_CONSISTENCY_H
