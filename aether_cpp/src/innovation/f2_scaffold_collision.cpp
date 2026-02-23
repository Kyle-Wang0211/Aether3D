// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f2_scaffold_collision.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace aether {
namespace innovation {
namespace {

constexpr float kEpsilon = 1e-6f;
constexpr std::uint32_t kMaxGridCells = 262144u;

inline std::uint32_t clampu32(std::uint32_t value, std::uint32_t low, std::uint32_t high) {
    return std::max(low, std::min(value, high));
}

Float3 min3(const Float3& a, const Float3& b, const Float3& c) {
    return make_float3(
        std::min(a.x, std::min(b.x, c.x)),
        std::min(a.y, std::min(b.y, c.y)),
        std::min(a.z, std::min(b.z, c.z)));
}

Float3 max3(const Float3& a, const Float3& b, const Float3& c) {
    return make_float3(
        std::max(a.x, std::max(b.x, c.x)),
        std::max(a.y, std::max(b.y, c.y)),
        std::max(a.z, std::max(b.z, c.z)));
}

bool make_triangle(
    const ScaffoldUnit& unit,
    const std::vector<ScaffoldVertex>& vertices,
    F2CollisionTriangle* out_triangle) {
    if (out_triangle == nullptr) {
        return false;
    }
    if (unit.v0 >= vertices.size() || unit.v1 >= vertices.size() || unit.v2 >= vertices.size()) {
        return false;
    }

    const Float3 p0 = vertices[unit.v0].position;
    const Float3 p1 = vertices[unit.v1].position;
    const Float3 p2 = vertices[unit.v2].position;

    const Float3 n = triangle_normal(p0, p1, p2);
    if (length_sq(n) <= kEpsilon) {
        return false;
    }

    F2CollisionTriangle tri{};
    tri.unit_id = unit.unit_id;
    tri.v0 = unit.v0;
    tri.v1 = unit.v1;
    tri.v2 = unit.v2;
    tri.normal = n;
    tri.bounds_min = min3(p0, p1, p2);
    tri.bounds_max = max3(p0, p1, p2);
    *out_triangle = tri;
    return true;
}

std::uint32_t cell_index(
    std::uint32_t x,
    std::uint32_t y,
    std::uint32_t z,
    const F2CollisionGrid& grid) {
    return x + grid.dim_x * (y + grid.dim_y * z);
}

std::uint32_t coord_to_cell(float v, float origin, float cell_size, std::uint32_t dim) {
    if (dim == 0u || !(cell_size > 0.0f)) {
        return 0u;
    }
    const float t = (v - origin) / cell_size;
    const std::int64_t c = static_cast<std::int64_t>(std::floor(t));
    if (c <= 0) {
        return 0u;
    }
    if (c >= static_cast<std::int64_t>(dim - 1u)) {
        return dim - 1u;
    }
    return static_cast<std::uint32_t>(c);
}

void compute_grid_dims(
    const Aabb& bounds,
    float* inout_cell_size,
    std::uint32_t* out_x,
    std::uint32_t* out_y,
    std::uint32_t* out_z) {
    float cell_size = *inout_cell_size;
    if (!(cell_size > 0.0f)) {
        cell_size = 0.1f;
    }

    const float span_x = std::max(bounds.max.x - bounds.min.x, cell_size);
    const float span_y = std::max(bounds.max.y - bounds.min.y, cell_size);
    const float span_z = std::max(bounds.max.z - bounds.min.z, cell_size);

    std::uint32_t dim_x = clampu32(static_cast<std::uint32_t>(std::ceil(span_x / cell_size)), 1u, 1024u);
    std::uint32_t dim_y = clampu32(static_cast<std::uint32_t>(std::ceil(span_y / cell_size)), 1u, 1024u);
    std::uint32_t dim_z = clampu32(static_cast<std::uint32_t>(std::ceil(span_z / cell_size)), 1u, 1024u);

    std::uint64_t total_cells = static_cast<std::uint64_t>(dim_x) * dim_y * dim_z;
    while (total_cells > kMaxGridCells) {
        cell_size *= 1.5f;
        dim_x = clampu32(static_cast<std::uint32_t>(std::ceil(span_x / cell_size)), 1u, 1024u);
        dim_y = clampu32(static_cast<std::uint32_t>(std::ceil(span_y / cell_size)), 1u, 1024u);
        dim_z = clampu32(static_cast<std::uint32_t>(std::ceil(span_z / cell_size)), 1u, 1024u);
        total_cells = static_cast<std::uint64_t>(dim_x) * dim_y * dim_z;
    }

    *inout_cell_size = cell_size;
    *out_x = dim_x;
    *out_y = dim_y;
    *out_z = dim_z;
}

void rebuild_bounds(F2CollisionMesh& mesh) {
    mesh.bounds = Aabb{};
    for (const auto& v : mesh.vertices) {
        expand_aabb(v.position, mesh.bounds);
    }
    if (!mesh.bounds.valid) {
        mesh.bounds.min = make_float3(0.0f, 0.0f, 0.0f);
        mesh.bounds.max = make_float3(1.0f, 1.0f, 1.0f);
        mesh.bounds.valid = true;
    }
}

core::Status rebuild_grid(F2CollisionMesh* mesh) {
    if (mesh == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (mesh->triangles.empty()) {
        mesh->grid = F2CollisionGrid{};
        return core::Status::kOutOfRange;
    }

    float edge_sum = 0.0f;
    std::size_t edge_count = 0u;
    for (const auto& tri : mesh->triangles) {
        if (tri.v0 >= mesh->vertices.size() || tri.v1 >= mesh->vertices.size() || tri.v2 >= mesh->vertices.size()) {
            return core::Status::kOutOfRange;
        }
        const Float3 p0 = mesh->vertices[tri.v0].position;
        const Float3 p1 = mesh->vertices[tri.v1].position;
        const Float3 p2 = mesh->vertices[tri.v2].position;
        edge_sum += length(sub(p1, p0));
        edge_sum += length(sub(p2, p1));
        edge_sum += length(sub(p0, p2));
        edge_count += 3u;
    }
    float cell_size = (edge_count > 0u) ? (edge_sum / static_cast<float>(edge_count)) : 0.1f;
    cell_size = std::max(cell_size * 1.5f, 1e-3f);

    F2CollisionGrid grid{};
    grid.origin = mesh->bounds.min;
    compute_grid_dims(mesh->bounds, &cell_size, &grid.dim_x, &grid.dim_y, &grid.dim_z);
    grid.cell_size = cell_size;

    const std::uint32_t cell_count = grid.dim_x * grid.dim_y * grid.dim_z;
    std::vector<std::uint32_t> counts(cell_count, 0u);

    for (const auto& tri : mesh->triangles) {
        const std::uint32_t min_x = coord_to_cell(tri.bounds_min.x, grid.origin.x, grid.cell_size, grid.dim_x);
        const std::uint32_t min_y = coord_to_cell(tri.bounds_min.y, grid.origin.y, grid.cell_size, grid.dim_y);
        const std::uint32_t min_z = coord_to_cell(tri.bounds_min.z, grid.origin.z, grid.cell_size, grid.dim_z);
        const std::uint32_t max_x = coord_to_cell(tri.bounds_max.x, grid.origin.x, grid.cell_size, grid.dim_x);
        const std::uint32_t max_y = coord_to_cell(tri.bounds_max.y, grid.origin.y, grid.cell_size, grid.dim_y);
        const std::uint32_t max_z = coord_to_cell(tri.bounds_max.z, grid.origin.z, grid.cell_size, grid.dim_z);

        for (std::uint32_t z = min_z; z <= max_z; ++z) {
            for (std::uint32_t y = min_y; y <= max_y; ++y) {
                for (std::uint32_t x = min_x; x <= max_x; ++x) {
                    const std::uint32_t idx = cell_index(x, y, z, grid);
                    counts[idx] += 1u;
                }
            }
        }
    }

    grid.cell_offsets.resize(static_cast<std::size_t>(cell_count) + 1u, 0u);
    for (std::uint32_t i = 0u; i < cell_count; ++i) {
        grid.cell_offsets[static_cast<std::size_t>(i) + 1u] = grid.cell_offsets[i] + counts[i];
    }
    grid.cell_triangle_indices.resize(grid.cell_offsets.back(), 0u);
    std::vector<std::uint32_t> cursor = grid.cell_offsets;

    for (std::size_t tri_idx = 0u; tri_idx < mesh->triangles.size(); ++tri_idx) {
        const auto& tri = mesh->triangles[tri_idx];
        const std::uint32_t min_x = coord_to_cell(tri.bounds_min.x, grid.origin.x, grid.cell_size, grid.dim_x);
        const std::uint32_t min_y = coord_to_cell(tri.bounds_min.y, grid.origin.y, grid.cell_size, grid.dim_y);
        const std::uint32_t min_z = coord_to_cell(tri.bounds_min.z, grid.origin.z, grid.cell_size, grid.dim_z);
        const std::uint32_t max_x = coord_to_cell(tri.bounds_max.x, grid.origin.x, grid.cell_size, grid.dim_x);
        const std::uint32_t max_y = coord_to_cell(tri.bounds_max.y, grid.origin.y, grid.cell_size, grid.dim_y);
        const std::uint32_t max_z = coord_to_cell(tri.bounds_max.z, grid.origin.z, grid.cell_size, grid.dim_z);

        for (std::uint32_t z = min_z; z <= max_z; ++z) {
            for (std::uint32_t y = min_y; y <= max_y; ++y) {
                for (std::uint32_t x = min_x; x <= max_x; ++x) {
                    const std::uint32_t idx = cell_index(x, y, z, grid);
                    const std::uint32_t dst = cursor[idx]++;
                    grid.cell_triangle_indices[dst] = static_cast<std::uint32_t>(tri_idx);
                }
            }
        }
    }

    mesh->grid = std::move(grid);
    return core::Status::kOk;
}

bool intersect_triangle_ray(
    const Float3& ray_origin,
    const Float3& ray_dir,
    const Float3& p0,
    const Float3& p1,
    const Float3& p2,
    float* out_t) {
    const Float3 edge1 = sub(p1, p0);
    const Float3 edge2 = sub(p2, p0);
    const Float3 pvec = cross(ray_dir, edge2);
    const float det = dot(edge1, pvec);
    if (std::fabs(det) < kEpsilon) {
        return false;
    }
    const float inv_det = 1.0f / det;
    const Float3 tvec = sub(ray_origin, p0);
    const float u = dot(tvec, pvec) * inv_det;
    if (u < 0.0f || u > 1.0f) {
        return false;
    }
    const Float3 qvec = cross(tvec, edge1);
    const float v = dot(ray_dir, qvec) * inv_det;
    if (v < 0.0f || u + v > 1.0f) {
        return false;
    }
    const float t = dot(edge2, qvec) * inv_det;
    if (t < 0.0f) {
        return false;
    }
    *out_t = t;
    return true;
}

float point_triangle_sq_distance(
    const Float3& p,
    const Float3& a,
    const Float3& b,
    const Float3& c,
    Float3* out_closest) {
    const Float3 ab = sub(b, a);
    const Float3 ac = sub(c, a);
    const Float3 ap = sub(p, a);

    const float d1 = dot(ab, ap);
    const float d2 = dot(ac, ap);
    if (d1 <= 0.0f && d2 <= 0.0f) {
        *out_closest = a;
        return length_sq(sub(p, a));
    }

    const Float3 bp = sub(p, b);
    const float d3 = dot(ab, bp);
    const float d4 = dot(ac, bp);
    if (d3 >= 0.0f && d4 <= d3) {
        *out_closest = b;
        return length_sq(sub(p, b));
    }

    const float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f) {
        const float v = d1 / (d1 - d3);
        *out_closest = add(a, mul(ab, v));
        return length_sq(sub(p, *out_closest));
    }

    const Float3 cp = sub(p, c);
    const float d5 = dot(ab, cp);
    const float d6 = dot(ac, cp);
    if (d6 >= 0.0f && d5 <= d6) {
        *out_closest = c;
        return length_sq(sub(p, c));
    }

    const float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f) {
        const float w = d2 / (d2 - d6);
        *out_closest = add(a, mul(ac, w));
        return length_sq(sub(p, *out_closest));
    }

    const float va = d3 * d6 - d5 * d4;
    if (va <= 0.0f && (d4 - d3) >= 0.0f && (d5 - d6) >= 0.0f) {
        const Float3 bc = sub(c, b);
        const float w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        *out_closest = add(b, mul(bc, w));
        return length_sq(sub(p, *out_closest));
    }

    const float denom = 1.0f / (va + vb + vc);
    const float v = vb * denom;
    const float w = vc * denom;
    *out_closest = add(a, add(mul(ab, v), mul(ac, w)));
    return length_sq(sub(p, *out_closest));
}

void collect_candidates_in_aabb(
    const F2CollisionMesh& mesh,
    const Float3& qmin,
    const Float3& qmax,
    std::vector<std::uint32_t>* out_candidates) {
    out_candidates->clear();
    if (mesh.grid.cell_offsets.empty() || mesh.grid.cell_size <= 0.0f) {
        return;
    }

    const std::uint32_t min_x = coord_to_cell(qmin.x, mesh.grid.origin.x, mesh.grid.cell_size, mesh.grid.dim_x);
    const std::uint32_t min_y = coord_to_cell(qmin.y, mesh.grid.origin.y, mesh.grid.cell_size, mesh.grid.dim_y);
    const std::uint32_t min_z = coord_to_cell(qmin.z, mesh.grid.origin.z, mesh.grid.cell_size, mesh.grid.dim_z);
    const std::uint32_t max_x = coord_to_cell(qmax.x, mesh.grid.origin.x, mesh.grid.cell_size, mesh.grid.dim_x);
    const std::uint32_t max_y = coord_to_cell(qmax.y, mesh.grid.origin.y, mesh.grid.cell_size, mesh.grid.dim_y);
    const std::uint32_t max_z = coord_to_cell(qmax.z, mesh.grid.origin.z, mesh.grid.cell_size, mesh.grid.dim_z);

    std::vector<std::uint8_t> seen(mesh.triangles.size(), 0u);
    for (std::uint32_t z = min_z; z <= max_z; ++z) {
        for (std::uint32_t y = min_y; y <= max_y; ++y) {
            for (std::uint32_t x = min_x; x <= max_x; ++x) {
                const std::uint32_t idx = cell_index(x, y, z, mesh.grid);
                const std::uint32_t begin = mesh.grid.cell_offsets[idx];
                const std::uint32_t end = mesh.grid.cell_offsets[idx + 1u];
                for (std::uint32_t it = begin; it < end; ++it) {
                    const std::uint32_t tri_idx = mesh.grid.cell_triangle_indices[it];
                    if (tri_idx < seen.size() && seen[tri_idx] == 0u) {
                        seen[tri_idx] = 1u;
                        out_candidates->push_back(tri_idx);
                    }
                }
            }
        }
    }
}

}  // namespace

core::Status f2_build_collision_mesh(
    const ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const ScaffoldUnit* units,
    std::size_t unit_count,
    F2CollisionMesh* out_mesh) {
    if (out_mesh == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if ((vertex_count > 0u && vertices == nullptr) || (unit_count > 0u && units == nullptr)) {
        return core::Status::kInvalidArgument;
    }

    F2CollisionMesh mesh{};
    if (vertex_count > 0u) {
        mesh.vertices.assign(vertices, vertices + vertex_count);
    } else {
        mesh.vertices.clear();
    }
    rebuild_bounds(mesh);

    mesh.triangles.reserve(unit_count);
    for (std::size_t i = 0; i < unit_count; ++i) {
        F2CollisionTriangle tri{};
        if (make_triangle(units[i], mesh.vertices, &tri)) {
            mesh.triangles.push_back(tri);
        }
    }

    if (mesh.triangles.empty()) {
        *out_mesh = std::move(mesh);
        return core::Status::kOutOfRange;
    }

    std::sort(mesh.triangles.begin(), mesh.triangles.end(), [](const F2CollisionTriangle& lhs, const F2CollisionTriangle& rhs) {
        if (lhs.unit_id != rhs.unit_id) {
            return lhs.unit_id < rhs.unit_id;
        }
        if (lhs.v0 != rhs.v0) {
            return lhs.v0 < rhs.v0;
        }
        if (lhs.v1 != rhs.v1) {
            return lhs.v1 < rhs.v1;
        }
        return lhs.v2 < rhs.v2;
    });

    const core::Status status = rebuild_grid(&mesh);
    *out_mesh = std::move(mesh);
    return status;
}

core::Status f2_apply_collision_delta(
    const ScaffoldVertex* vertices,
    std::size_t vertex_count,
    const F2CollisionDelta& delta,
    F2CollisionMesh* inout_mesh) {
    if (inout_mesh == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (vertex_count > 0u && vertices == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (delta.upsert_count > 0u && delta.upsert_units == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (delta.remove_count > 0u && delta.remove_unit_ids == nullptr) {
        return core::Status::kInvalidArgument;
    }

    if (vertex_count > 0u) {
        inout_mesh->vertices.assign(vertices, vertices + vertex_count);
    } else {
        inout_mesh->vertices.clear();
    }
    rebuild_bounds(*inout_mesh);

    std::vector<std::uint64_t> removed(delta.remove_unit_ids, delta.remove_unit_ids + delta.remove_count);
    std::sort(removed.begin(), removed.end());
    removed.erase(std::unique(removed.begin(), removed.end()), removed.end());

    std::vector<std::uint64_t> upsert_ids;
    upsert_ids.reserve(delta.upsert_count);
    for (std::size_t i = 0; i < delta.upsert_count; ++i) {
        upsert_ids.push_back(delta.upsert_units[i].unit_id);
    }
    std::sort(upsert_ids.begin(), upsert_ids.end());
    upsert_ids.erase(std::unique(upsert_ids.begin(), upsert_ids.end()), upsert_ids.end());

    std::vector<F2CollisionTriangle> next_triangles;
    next_triangles.reserve(inout_mesh->triangles.size() + delta.upsert_count);
    for (const auto& tri : inout_mesh->triangles) {
        const bool is_removed = std::binary_search(removed.begin(), removed.end(), tri.unit_id);
        const bool will_replace = std::binary_search(upsert_ids.begin(), upsert_ids.end(), tri.unit_id);
        if (!is_removed && !will_replace) {
            next_triangles.push_back(tri);
        }
    }

    for (std::size_t i = 0; i < delta.upsert_count; ++i) {
        F2CollisionTriangle tri{};
        if (make_triangle(delta.upsert_units[i], inout_mesh->vertices, &tri)) {
            next_triangles.push_back(tri);
        }
    }

    std::sort(next_triangles.begin(), next_triangles.end(), [](const F2CollisionTriangle& lhs, const F2CollisionTriangle& rhs) {
        if (lhs.unit_id != rhs.unit_id) {
            return lhs.unit_id < rhs.unit_id;
        }
        if (lhs.v0 != rhs.v0) {
            return lhs.v0 < rhs.v0;
        }
        if (lhs.v1 != rhs.v1) {
            return lhs.v1 < rhs.v1;
        }
        return lhs.v2 < rhs.v2;
    });

    inout_mesh->triangles = std::move(next_triangles);
    if (inout_mesh->triangles.empty()) {
        inout_mesh->grid = F2CollisionGrid{};
        return core::Status::kOutOfRange;
    }
    return rebuild_grid(inout_mesh);
}

core::Status f2_intersect_ray(
    const F2CollisionMesh& mesh,
    const Float3& origin,
    const Float3& direction,
    float max_distance,
    F2CollisionHit* out_hit) {
    if (out_hit == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!(max_distance > 0.0f)) {
        return core::Status::kInvalidArgument;
    }
    if (mesh.triangles.empty()) {
        return core::Status::kOutOfRange;
    }

    const Float3 dir = normalize(direction);
    if (length_sq(dir) <= kEpsilon) {
        return core::Status::kInvalidArgument;
    }

    const Float3 end = add(origin, mul(dir, max_distance));
    const Float3 qmin = min3(origin, end, origin);
    const Float3 qmax = max3(origin, end, origin);

    std::vector<std::uint32_t> candidates;
    collect_candidates_in_aabb(mesh, qmin, qmax, &candidates);
    if (candidates.empty()) {
        return core::Status::kOutOfRange;
    }

    float best_t = std::numeric_limits<float>::max();
    F2CollisionHit best{};
    for (std::uint32_t tri_idx : candidates) {
        const auto& tri = mesh.triangles[tri_idx];
        if (tri.v0 >= mesh.vertices.size() || tri.v1 >= mesh.vertices.size() || tri.v2 >= mesh.vertices.size()) {
            continue;
        }
        const Float3 p0 = mesh.vertices[tri.v0].position;
        const Float3 p1 = mesh.vertices[tri.v1].position;
        const Float3 p2 = mesh.vertices[tri.v2].position;

        float t = 0.0f;
        if (!intersect_triangle_ray(origin, dir, p0, p1, p2, &t)) {
            continue;
        }
        if (t <= max_distance && t < best_t) {
            best_t = t;
            best.hit = true;
            best.distance = t;
            best.position = add(origin, mul(dir, t));
            best.normal = tri.normal;
            best.unit_id = tri.unit_id;
            best.triangle_index = tri_idx;
        }
    }

    if (!best.hit) {
        return core::Status::kOutOfRange;
    }
    *out_hit = best;
    return core::Status::kOk;
}

core::Status f2_query_point_distance(
    const F2CollisionMesh& mesh,
    const Float3& point,
    float max_distance,
    F2PointDistanceResult* out_result) {
    if (out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!(max_distance >= 0.0f)) {
        return core::Status::kInvalidArgument;
    }
    if (mesh.triangles.empty()) {
        return core::Status::kOutOfRange;
    }

    const Float3 delta = make_float3(max_distance, max_distance, max_distance);
    const Float3 qmin = sub(point, delta);
    const Float3 qmax = add(point, delta);

    std::vector<std::uint32_t> candidates;
    collect_candidates_in_aabb(mesh, qmin, qmax, &candidates);
    if (candidates.empty()) {
        return core::Status::kOutOfRange;
    }

    float best_sq = std::numeric_limits<float>::max();
    F2PointDistanceResult best{};
    for (std::uint32_t tri_idx : candidates) {
        const auto& tri = mesh.triangles[tri_idx];
        if (tri.v0 >= mesh.vertices.size() || tri.v1 >= mesh.vertices.size() || tri.v2 >= mesh.vertices.size()) {
            continue;
        }
        const Float3 p0 = mesh.vertices[tri.v0].position;
        const Float3 p1 = mesh.vertices[tri.v1].position;
        const Float3 p2 = mesh.vertices[tri.v2].position;

        Float3 closest{};
        const float dist_sq = point_triangle_sq_distance(point, p0, p1, p2, &closest);
        if (dist_sq < best_sq) {
            best_sq = dist_sq;
            best.valid = true;
            best.distance = std::sqrt(dist_sq);
            best.closest_point = closest;
            best.normal = tri.normal;
            best.unit_id = tri.unit_id;
            best.triangle_index = tri_idx;
        }
    }

    if (!best.valid || best.distance > max_distance + 1e-5f) {
        return core::Status::kOutOfRange;
    }
    *out_result = best;
    return core::Status::kOk;
}

}  // namespace innovation
}  // namespace aether
