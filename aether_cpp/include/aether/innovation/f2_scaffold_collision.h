// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F2_SCAFFOLD_COLLISION_H
#define AETHER_INNOVATION_F2_SCAFFOLD_COLLISION_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {

struct F2CollisionTriangle {
    std::uint64_t unit_id{0};
    std::uint32_t v0{0};
    std::uint32_t v1{0};
    std::uint32_t v2{0};
    Float3 normal{};
    Float3 bounds_min{};
    Float3 bounds_max{};
};

struct F2CollisionGrid {
    Float3 origin{};
    float cell_size{0.0f};
    std::uint32_t dim_x{0};
    std::uint32_t dim_y{0};
    std::uint32_t dim_z{0};
    std::vector<std::uint32_t> cell_offsets{};
    std::vector<std::uint32_t> cell_triangle_indices{};
};

struct F2CollisionMesh {
    std::vector<ScaffoldVertex> vertices{};
    std::vector<F2CollisionTriangle> triangles{};
    Aabb bounds{};
    F2CollisionGrid grid{};
};

struct F2CollisionDelta {
    const ScaffoldUnit* upsert_units{nullptr};
    std::size_t upsert_count{0};
    const std::uint64_t* remove_unit_ids{nullptr};
    std::size_t remove_count{0};
};

struct F2CollisionHit {
    bool hit{false};
    float distance{0.0f};
    Float3 position{};
    Float3 normal{};
    std::uint64_t unit_id{0};
    std::uint32_t triangle_index{0};
};

struct F2PointDistanceResult {
    bool valid{false};
    float distance{0.0f};
    Float3 closest_point{};
    Float3 normal{};
    std::uint64_t unit_id{0};
    std::uint32_t triangle_index{0};
};

core::Status f2_build_collision_mesh(
    const ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const ScaffoldUnit* units,
    std::size_t unit_count,
    F2CollisionMesh* out_mesh);

core::Status f2_apply_collision_delta(
    const ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const F2CollisionDelta& delta,
    F2CollisionMesh* inout_mesh);

core::Status f2_intersect_ray(
    const F2CollisionMesh& mesh,
    const Float3& origin,
    const Float3& direction,
    float max_distance,
    F2CollisionHit* out_hit);

core::Status f2_query_point_distance(
    const F2CollisionMesh& mesh,
    const Float3& point,
    float max_distance,
    F2PointDistanceResult* out_result);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F2_SCAFFOLD_COLLISION_H
