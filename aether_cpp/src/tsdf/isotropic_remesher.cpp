// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/isotropic_remesher.h"
#include "aether/tsdf/tsdf_constants.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <vector>

namespace aether {
namespace tsdf {
namespace {

constexpr float kEpsilon = 1e-8f;
constexpr float kPi = 3.14159265358979323846f;

inline math::Vec3 add3(const math::Vec3& a, const math::Vec3& b) {
    return math::Vec3(a.x + b.x, a.y + b.y, a.z + b.z);
}

inline math::Vec3 sub3(const math::Vec3& a, const math::Vec3& b) {
    return math::Vec3(a.x - b.x, a.y - b.y, a.z - b.z);
}

inline math::Vec3 mul3(const math::Vec3& a, float s) {
    return math::Vec3(a.x * s, a.y * s, a.z * s);
}

inline float dot3(const math::Vec3& a, const math::Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline math::Vec3 cross3(const math::Vec3& a, const math::Vec3& b) {
    return math::Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

inline float len3(const math::Vec3& v) {
    return std::sqrt(dot3(v, v));
}

inline math::Vec3 normalized_or_zero(const math::Vec3& v) {
    const float l = len3(v);
    if (l <= kEpsilon) {
        return math::Vec3(0.0f, 0.0f, 0.0f);
    }
    return mul3(v, 1.0f / l);
}

inline float edge_length(const MeshVertex* vertices, std::uint32_t i0, std::uint32_t i1) {
    return len3(sub3(vertices[i0].position, vertices[i1].position));
}

inline bool tri_valid(const MeshTriangle& tri, std::size_t vertex_count) {
    return tri.i0 < vertex_count && tri.i1 < vertex_count && tri.i2 < vertex_count &&
        tri.i0 != tri.i1 && tri.i1 != tri.i2 && tri.i0 != tri.i2;
}

inline math::Vec3 triangle_normal(
    const MeshVertex* vertices,
    const MeshTriangle& tri,
    std::uint32_t override_id = std::numeric_limits<std::uint32_t>::max(),
    const math::Vec3& override_pos = math::Vec3()) {
    const math::Vec3 a = (tri.i0 == override_id) ? override_pos : vertices[tri.i0].position;
    const math::Vec3 b = (tri.i1 == override_id) ? override_pos : vertices[tri.i1].position;
    const math::Vec3 c = (tri.i2 == override_id) ? override_pos : vertices[tri.i2].position;
    return normalized_or_zero(cross3(sub3(b, a), sub3(c, a)));
}

inline float area_of(
    const MeshVertex* vertices,
    const MeshTriangle& tri,
    std::uint32_t override_id = std::numeric_limits<std::uint32_t>::max(),
    const math::Vec3& override_pos = math::Vec3()) {
    const math::Vec3 a = (tri.i0 == override_id) ? override_pos : vertices[tri.i0].position;
    const math::Vec3 b = (tri.i1 == override_id) ? override_pos : vertices[tri.i1].position;
    const math::Vec3 c = (tri.i2 == override_id) ? override_pos : vertices[tri.i2].position;
    return 0.5f * len3(cross3(sub3(b, a), sub3(c, a)));
}

inline float safe_cosine(const math::Vec3& a, const math::Vec3& b) {
    const float la = len3(a);
    const float lb = len3(b);
    if (la <= kEpsilon || lb <= kEpsilon) {
        return 1.0f;
    }
    const float c = dot3(a, b) / (la * lb);
    return std::max(-1.0f, std::min(1.0f, c));
}

inline float max_triangle_cosine(const MeshVertex* vertices, const MeshTriangle& tri) {
    const math::Vec3 a = vertices[tri.i0].position;
    const math::Vec3 b = vertices[tri.i1].position;
    const math::Vec3 c = vertices[tri.i2].position;
    const float ca = safe_cosine(sub3(b, a), sub3(c, a));
    const float cb = safe_cosine(sub3(a, b), sub3(c, b));
    const float cc = safe_cosine(sub3(a, c), sub3(b, c));
    return std::max(ca, std::max(cb, cc));
}

inline bool triangle_has_edge(const MeshTriangle& tri, std::uint32_t u, std::uint32_t v) {
    const bool has_u = (tri.i0 == u || tri.i1 == u || tri.i2 == u);
    const bool has_v = (tri.i0 == v || tri.i1 == v || tri.i2 == v);
    return has_u && has_v;
}

inline void replace_vertex_index(MeshTriangle* tri, std::uint32_t from, std::uint32_t to) {
    if (tri->i0 == from) {
        tri->i0 = to;
    }
    if (tri->i1 == from) {
        tri->i1 = to;
    }
    if (tri->i2 == from) {
        tri->i2 = to;
    }
}

inline std::uint64_t edge_key(std::uint32_t a, std::uint32_t b) {
    const std::uint32_t lo = std::min(a, b);
    const std::uint32_t hi = std::max(a, b);
    return (static_cast<std::uint64_t>(lo) << 32u) | static_cast<std::uint64_t>(hi);
}

void compact_vertices(
    MeshVertex* vertices,
    std::size_t* vertex_count,
    MeshTriangle* triangles,
    std::size_t triangle_count) {
    if (vertices == nullptr || vertex_count == nullptr || triangles == nullptr) {
        return;
    }
    std::vector<std::uint8_t> used(*vertex_count, 0u);
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        const MeshTriangle tri = triangles[i];
        if (!tri_valid(tri, *vertex_count)) {
            continue;
        }
        used[tri.i0] = 1u;
        used[tri.i1] = 1u;
        used[tri.i2] = 1u;
    }

    std::vector<std::uint32_t> remap(*vertex_count, std::numeric_limits<std::uint32_t>::max());
    std::size_t write = 0u;
    for (std::size_t i = 0u; i < *vertex_count; ++i) {
        if (used[i] == 0u) {
            continue;
        }
        remap[i] = static_cast<std::uint32_t>(write);
        if (write != i) {
            vertices[write] = vertices[i];
        }
        ++write;
    }

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        MeshTriangle tri = triangles[i];
        if (!tri_valid(tri, *vertex_count)) {
            continue;
        }
        tri.i0 = remap[tri.i0];
        tri.i1 = remap[tri.i1];
        tri.i2 = remap[tri.i2];
        triangles[i] = tri;
    }
    *vertex_count = write;
}

void build_vertex_triangle_adjacency(
    const MeshTriangle* triangles,
    std::size_t triangle_count,
    std::size_t vertex_count,
    std::vector<std::vector<std::size_t>>* out_vertex_tris) {
    if (out_vertex_tris == nullptr) {
        return;
    }
    out_vertex_tris->assign(vertex_count, std::vector<std::size_t>());
    for (std::size_t i = 0u; i < triangle_count; ++i) {
        const MeshTriangle tri = triangles[i];
        if (!tri_valid(tri, vertex_count)) {
            continue;
        }
        (*out_vertex_tris)[tri.i0].push_back(i);
        (*out_vertex_tris)[tri.i1].push_back(i);
        (*out_vertex_tris)[tri.i2].push_back(i);
    }
}

void gather_affected_triangles(
    const std::vector<std::vector<std::size_t>>& vertex_tris,
    std::uint32_t keep,
    std::uint32_t remove,
    std::vector<std::uint32_t>* seen,
    std::uint32_t* stamp,
    std::vector<std::size_t>* out_indices) {
    if (seen == nullptr || stamp == nullptr || out_indices == nullptr) {
        return;
    }
    if (*stamp == std::numeric_limits<std::uint32_t>::max()) {
        std::fill(seen->begin(), seen->end(), 0u);
        *stamp = 1u;
    } else {
        *stamp += 1u;
    }
    out_indices->clear();
    const std::uint32_t local_stamp = *stamp;
    auto add_from = [&](std::uint32_t vertex_id) {
        if (vertex_id >= vertex_tris.size()) {
            return;
        }
        for (std::size_t tri_idx : vertex_tris[vertex_id]) {
            if (tri_idx >= seen->size()) {
                continue;
            }
            if ((*seen)[tri_idx] == local_stamp) {
                continue;
            }
            (*seen)[tri_idx] = local_stamp;
            out_indices->push_back(tri_idx);
        }
    };
    add_from(keep);
    add_from(remove);
}

void collect_one_ring(
    std::uint32_t vertex_id,
    const MeshTriangle* triangles,
    std::size_t vertex_count,
    const std::vector<std::vector<std::size_t>>& vertex_tris,
    std::vector<std::uint32_t>* out_ring) {
    if (out_ring == nullptr) {
        return;
    }
    out_ring->clear();
    if (vertex_id >= vertex_tris.size()) {
        return;
    }
    for (std::size_t tri_idx : vertex_tris[vertex_id]) {
        const MeshTriangle tri = triangles[tri_idx];
        if (!tri_valid(tri, vertex_count)) {
            continue;
        }
        if (tri.i0 != vertex_id) {
            out_ring->push_back(tri.i0);
        }
        if (tri.i1 != vertex_id) {
            out_ring->push_back(tri.i1);
        }
        if (tri.i2 != vertex_id) {
            out_ring->push_back(tri.i2);
        }
    }
    std::sort(out_ring->begin(), out_ring->end());
    out_ring->erase(std::unique(out_ring->begin(), out_ring->end()), out_ring->end());
}

bool link_condition_valid(
    std::uint32_t keep,
    std::uint32_t remove,
    const MeshTriangle* triangles,
    std::size_t,
    std::size_t vertex_count,
    const std::vector<std::vector<std::size_t>>& vertex_tris) {
    if (keep >= vertex_count || remove >= vertex_count) {
        return false;
    }
    std::vector<std::uint32_t> ring_keep;
    std::vector<std::uint32_t> ring_remove;
    collect_one_ring(keep, triangles, vertex_count, vertex_tris, &ring_keep);
    collect_one_ring(remove, triangles, vertex_count, vertex_tris, &ring_remove);

    std::size_t intersection_count = 0u;
    std::size_t i = 0u;
    std::size_t j = 0u;
    while (i < ring_keep.size() && j < ring_remove.size()) {
        if (ring_keep[i] == ring_remove[j]) {
            ++intersection_count;
            ++i;
            ++j;
        } else if (ring_keep[i] < ring_remove[j]) {
            ++i;
        } else {
            ++j;
        }
    }

    std::size_t edge_incidence = 0u;
    if (keep < vertex_tris.size()) {
        for (std::size_t tri_idx : vertex_tris[keep]) {
            const MeshTriangle tri = triangles[tri_idx];
            if (!tri_valid(tri, vertex_count)) {
                continue;
            }
            if (triangle_has_edge(tri, keep, remove)) {
                ++edge_incidence;
            }
        }
    }
    if (edge_incidence == 0u || edge_incidence > 2u) {
        return false;
    }
    const std::size_t expected = (edge_incidence == 1u) ? 1u : 2u;
    return intersection_count == expected;
}

inline bool share_vertex(const MeshTriangle& a, const MeshTriangle& b) {
    return a.i0 == b.i0 || a.i0 == b.i1 || a.i0 == b.i2 ||
        a.i1 == b.i0 || a.i1 == b.i1 || a.i1 == b.i2 ||
        a.i2 == b.i0 || a.i2 == b.i1 || a.i2 == b.i2;
}

inline math::Vec3 tri_position(
    const MeshVertex* vertices,
    std::uint32_t id,
    std::uint32_t override_id = std::numeric_limits<std::uint32_t>::max(),
    const math::Vec3& override_pos = math::Vec3()) {
    return (id == override_id) ? override_pos : vertices[id].position;
}

bool segment_intersects_triangle_strict(
    const math::Vec3& p0,
    const math::Vec3& p1,
    const math::Vec3& a,
    const math::Vec3& b,
    const math::Vec3& c) {
    const math::Vec3 dir = sub3(p1, p0);
    const math::Vec3 e1 = sub3(b, a);
    const math::Vec3 e2 = sub3(c, a);
    const math::Vec3 h = cross3(dir, e2);
    const float det = dot3(e1, h);
    if (std::fabs(det) <= 1e-10f) {
        return false;
    }
    const float inv_det = 1.0f / det;
    const math::Vec3 s = sub3(p0, a);
    const float u = dot3(s, h) * inv_det;
    if (u <= 1e-5f || u >= 1.0f - 1e-5f) {
        return false;
    }
    const math::Vec3 q = cross3(s, e1);
    const float v = dot3(dir, q) * inv_det;
    if (v <= 1e-5f || (u + v) >= 1.0f - 1e-5f) {
        return false;
    }
    const float t = dot3(e2, q) * inv_det;
    return t > 1e-5f && t < 1.0f - 1e-5f;
}

bool triangles_intersect_strict(
    const MeshVertex* vertices,
    const MeshTriangle& ta,
    const MeshTriangle& tb,
    std::uint32_t override_id = std::numeric_limits<std::uint32_t>::max(),
    const math::Vec3& override_pos = math::Vec3()) {
    const math::Vec3 a0 = tri_position(vertices, ta.i0, override_id, override_pos);
    const math::Vec3 a1 = tri_position(vertices, ta.i1, override_id, override_pos);
    const math::Vec3 a2 = tri_position(vertices, ta.i2, override_id, override_pos);
    const math::Vec3 b0 = tri_position(vertices, tb.i0, override_id, override_pos);
    const math::Vec3 b1 = tri_position(vertices, tb.i1, override_id, override_pos);
    const math::Vec3 b2 = tri_position(vertices, tb.i2, override_id, override_pos);

    if (segment_intersects_triangle_strict(a0, a1, b0, b1, b2)) return true;
    if (segment_intersects_triangle_strict(a1, a2, b0, b1, b2)) return true;
    if (segment_intersects_triangle_strict(a2, a0, b0, b1, b2)) return true;
    if (segment_intersects_triangle_strict(b0, b1, a0, a1, a2)) return true;
    if (segment_intersects_triangle_strict(b1, b2, a0, a1, a2)) return true;
    if (segment_intersects_triangle_strict(b2, b0, a0, a1, a2)) return true;
    return false;
}

bool collapse_creates_local_intersection(
    const MeshVertex* vertices,
    const MeshTriangle* triangles,
    const std::vector<std::size_t>& affected_triangles,
    std::uint32_t keep,
    std::uint32_t remove,
    const math::Vec3& new_keep_position,
    std::size_t vertex_count) {
    std::vector<MeshTriangle> local;
    local.reserve(affected_triangles.size());
    for (std::size_t tri_idx : affected_triangles) {
        MeshTriangle tri = triangles[tri_idx];
        replace_vertex_index(&tri, remove, keep);
        if (!tri_valid(tri, vertex_count)) {
            continue;
        }
        if (area_of(vertices, tri, keep, new_keep_position) < MIN_TRIANGLE_AREA) {
            continue;
        }
        local.push_back(tri);
    }

    for (std::size_t i = 0u; i < local.size(); ++i) {
        for (std::size_t j = i + 1u; j < local.size(); ++j) {
            if (share_vertex(local[i], local[j])) {
                continue;
            }
            if (triangles_intersect_strict(vertices, local[i], local[j], keep, new_keep_position)) {
                return true;
            }
        }
    }
    return false;
}

void mark_boundary_vertices(
    const MeshTriangle* triangles,
    std::size_t triangle_count,
    std::size_t vertex_count,
    std::vector<std::uint8_t>* out_boundary) {
    if (out_boundary == nullptr) {
        return;
    }
    out_boundary->assign(vertex_count, 0u);
    std::unordered_map<std::uint64_t, std::uint32_t> edge_counts;
    edge_counts.reserve(triangle_count * 3u);

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        const MeshTriangle tri = triangles[i];
        if (!tri_valid(tri, vertex_count)) {
            continue;
        }
        ++edge_counts[edge_key(tri.i0, tri.i1)];
        ++edge_counts[edge_key(tri.i1, tri.i2)];
        ++edge_counts[edge_key(tri.i2, tri.i0)];
    }

    for (const auto& kv : edge_counts) {
        if (kv.second != 1u) {
            continue;
        }
        const std::uint32_t a = static_cast<std::uint32_t>(kv.first >> 32u);
        const std::uint32_t b = static_cast<std::uint32_t>(kv.first & 0xFFFFFFFFull);
        if (a < out_boundary->size()) {
            (*out_boundary)[a] = 1u;
        }
        if (b < out_boundary->size()) {
            (*out_boundary)[b] = 1u;
        }
    }
}

struct EdgeAdjacency {
    std::uint32_t lo{0u};
    std::uint32_t hi{0u};
    std::uint32_t opposite{0u};
    std::size_t triangle_index{0u};
};

inline void push_edge(
    std::vector<EdgeAdjacency>* out,
    std::uint32_t a,
    std::uint32_t b,
    std::uint32_t opposite,
    std::size_t tri_idx) {
    if (out == nullptr) {
        return;
    }
    EdgeAdjacency rec{};
    rec.lo = std::min(a, b);
    rec.hi = std::max(a, b);
    rec.opposite = opposite;
    rec.triangle_index = tri_idx;
    out->push_back(rec);
}

}  // namespace

float adaptive_target_length(float curvature, float base_length, float curvature_scale) {
    const float k = std::max(0.0f, curvature);
    const float denom = 1.0f + k * std::max(0.0f, curvature_scale);
    const float ratio = std::max(0.3f, std::min(1.0f, 1.0f / std::max(1e-6f, denom)));
    return std::max(1e-6f, base_length * ratio);
}

core::Status isotropic_remesh(
    MeshVertex* vertices,
    std::size_t* vertex_count,
    MeshTriangle* triangles,
    std::size_t* triangle_count,
    std::size_t vertex_capacity,
    std::size_t triangle_capacity,
    const RemeshConfig& config,
    RemeshResult* out_result) {
    if (vertices == nullptr || vertex_count == nullptr || triangles == nullptr || triangle_count == nullptr || out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (*vertex_count > vertex_capacity || *triangle_count > triangle_capacity ||
        config.target_edge_length <= 0.0f || config.max_iterations <= 0 ||
        config.split_threshold_ratio <= 1.0f || config.collapse_threshold_ratio <= 0.0f ||
        config.smoothing_lambda < 0.0f || config.smoothing_lambda > 1.0f ||
        config.max_normal_deviation_deg <= 0.0f || config.max_normal_deviation_deg >= 180.0f) {
        return core::Status::kInvalidArgument;
    }

    RemeshResult result{};
    std::size_t vcount = *vertex_count;
    std::size_t tcount = *triangle_count;
    const float min_normal_dot = std::cos(config.max_normal_deviation_deg * (kPi / 180.0f));

    for (int it = 0; it < config.max_iterations; ++it) {
        const float split_threshold = config.target_edge_length * config.split_threshold_ratio;
        const float collapse_threshold = config.target_edge_length * config.collapse_threshold_ratio;
        std::size_t iteration_ops = 0u;

        // Step 1: Edge split (longest edge in each triangle).
        std::size_t t = 0u;
        while (t < tcount) {
            MeshTriangle tri = triangles[t];
            if (!tri_valid(tri, vcount)) {
                ++t;
                continue;
            }
            const float l01 = edge_length(vertices, tri.i0, tri.i1);
            const float l12 = edge_length(vertices, tri.i1, tri.i2);
            const float l20 = edge_length(vertices, tri.i2, tri.i0);
            float max_len = l01;
            int edge = 0;
            if (l12 > max_len) {
                max_len = l12;
                edge = 1;
            }
            if (l20 > max_len) {
                max_len = l20;
                edge = 2;
            }
            if (max_len <= split_threshold || vcount + 1u > vertex_capacity || tcount + 1u > triangle_capacity) {
                ++t;
                continue;
            }

            std::uint32_t a = tri.i0;
            std::uint32_t b = tri.i1;
            std::uint32_t c = tri.i2;
            if (edge == 1) {
                a = tri.i1;
                b = tri.i2;
                c = tri.i0;
            } else if (edge == 2) {
                a = tri.i2;
                b = tri.i0;
                c = tri.i1;
            }

            MeshVertex mid{};
            mid.position = mul3(add3(vertices[a].position, vertices[b].position), 0.5f);
            mid.normal = normalized_or_zero(add3(vertices[a].normal, vertices[b].normal));
            mid.alpha = 0.5f * (vertices[a].alpha + vertices[b].alpha);
            mid.quality = 0.5f * (vertices[a].quality + vertices[b].quality);
            const std::uint32_t m = static_cast<std::uint32_t>(vcount++);
            vertices[m] = mid;

            triangles[t] = MeshTriangle{a, m, c};
            triangles[tcount++] = MeshTriangle{m, b, c};
            result.splits_performed += 1u;
            ++iteration_ops;
            ++t;
        }

        // Step 2: Edge collapse with vertex-local triangle updates.
        std::vector<std::vector<std::size_t>> vertex_tris;
        build_vertex_triangle_adjacency(triangles, tcount, vcount, &vertex_tris);
        std::vector<std::uint8_t> collapsed(vcount, 0u);
        std::vector<std::uint32_t> seen_tri(tcount, 0u);
        std::uint32_t seen_stamp = 0u;
        std::vector<std::size_t> affected;
        for (std::size_t i = 0u; i < tcount; ++i) {
            const MeshTriangle tri = triangles[i];
            if (!tri_valid(tri, vcount)) {
                continue;
            }
            const float l01 = edge_length(vertices, tri.i0, tri.i1);
            const float l12 = edge_length(vertices, tri.i1, tri.i2);
            const float l20 = edge_length(vertices, tri.i2, tri.i0);

            std::uint32_t a = tri.i0;
            std::uint32_t b = tri.i1;
            float min_len = l01;
            if (l12 < min_len) {
                min_len = l12;
                a = tri.i1;
                b = tri.i2;
            }
            if (l20 < min_len) {
                min_len = l20;
                a = tri.i2;
                b = tri.i0;
            }
            if (min_len >= collapse_threshold) {
                continue;
            }
            if (collapsed[a] != 0u || collapsed[b] != 0u) {
                continue;
            }
            const std::uint32_t keep = std::min(a, b);
            const std::uint32_t remove = std::max(a, b);
            gather_affected_triangles(vertex_tris, keep, remove, &seen_tri, &seen_stamp, &affected);
            if (affected.empty()) {
                continue;
            }
            if (config.enforce_manifold &&
                !link_condition_valid(keep, remove, triangles, tcount, vcount, vertex_tris)) {
                result.collapse_reject_nonmanifold += 1u;
                continue;
            }

            const math::Vec3 keep_pos = mul3(add3(vertices[keep].position, vertices[remove].position), 0.5f);
            bool normal_valid = true;
            for (std::size_t tri_idx : affected) {
                MeshTriangle updated = triangles[tri_idx];
                replace_vertex_index(&updated, remove, keep);
                if (!tri_valid(updated, vcount)) {
                    continue;
                }
                if (area_of(vertices, updated, keep, keep_pos) < MIN_TRIANGLE_AREA) {
                    continue;
                }
                const math::Vec3 n_before = triangle_normal(vertices, triangles[tri_idx]);
                const math::Vec3 n_after = triangle_normal(vertices, updated, keep, keep_pos);
                const float n_dot = dot3(n_before, n_after);
                if (std::fabs(n_dot) < min_normal_dot) {
                    normal_valid = false;
                    break;
                }
            }
            if (!normal_valid) {
                result.collapse_reject_normal_flip += 1u;
                continue;
            }
            if (config.reject_local_self_intersection &&
                collapse_creates_local_intersection(vertices, triangles, affected, keep, remove, keep_pos, vcount)) {
                result.collapse_reject_self_intersection += 1u;
                continue;
            }

            vertices[keep].position = keep_pos;
            vertices[keep].normal = normalized_or_zero(add3(vertices[keep].normal, vertices[remove].normal));
            vertices[keep].alpha = 0.5f * (vertices[keep].alpha + vertices[remove].alpha);
            vertices[keep].quality = 0.5f * (vertices[keep].quality + vertices[remove].quality);
            for (std::size_t tri_idx : affected) {
                MeshTriangle updated = triangles[tri_idx];
                replace_vertex_index(&updated, remove, keep);
                if (!tri_valid(updated, vcount) || area_of(vertices, updated) < MIN_TRIANGLE_AREA) {
                    triangles[tri_idx] = MeshTriangle{0u, 0u, 0u};
                } else {
                    triangles[tri_idx] = updated;
                }
            }
            collapsed[keep] = 1u;
            collapsed[remove] = 1u;
            result.collapses_performed += 1u;
            ++iteration_ops;
        }

        // Remove invalid triangles after collapse and compact vertices.
        std::size_t write_tri = 0u;
        for (std::size_t i = 0u; i < tcount; ++i) {
            const MeshTriangle tri = triangles[i];
            if (!tri_valid(tri, vcount)) {
                continue;
            }
            if (area_of(vertices, tri) < MIN_TRIANGLE_AREA) {
                continue;
            }
            triangles[write_tri++] = tri;
        }
        tcount = write_tri;
        compact_vertices(vertices, &vcount, triangles, tcount);

        // Step 3: Edge flips using max-cosine quality (no acos).
        std::vector<EdgeAdjacency> edges;
        edges.reserve(tcount * 3u);
        for (std::size_t i = 0u; i < tcount; ++i) {
            const MeshTriangle tri = triangles[i];
            if (!tri_valid(tri, vcount)) {
                continue;
            }
            push_edge(&edges, tri.i0, tri.i1, tri.i2, i);
            push_edge(&edges, tri.i1, tri.i2, tri.i0, i);
            push_edge(&edges, tri.i2, tri.i0, tri.i1, i);
        }
        std::sort(edges.begin(), edges.end(), [](const EdgeAdjacency& lhs, const EdgeAdjacency& rhs) {
            if (lhs.lo != rhs.lo) {
                return lhs.lo < rhs.lo;
            }
            if (lhs.hi != rhs.hi) {
                return lhs.hi < rhs.hi;
            }
            return lhs.triangle_index < rhs.triangle_index;
        });

        std::unordered_map<std::uint64_t, std::uint32_t> edge_occurrence;
        edge_occurrence.reserve(tcount * 3u);
        for (std::size_t i = 0u; i < tcount; ++i) {
            const MeshTriangle tri = triangles[i];
            if (!tri_valid(tri, vcount)) {
                continue;
            }
            ++edge_occurrence[edge_key(tri.i0, tri.i1)];
            ++edge_occurrence[edge_key(tri.i1, tri.i2)];
            ++edge_occurrence[edge_key(tri.i2, tri.i0)];
        }

        std::vector<std::vector<std::size_t>> flip_vertex_tris;
        build_vertex_triangle_adjacency(triangles, tcount, vcount, &flip_vertex_tris);
        std::vector<std::uint8_t> tri_locked(tcount, 0u);
        std::size_t e = 0u;
        while (e < edges.size()) {
            std::size_t n = e + 1u;
            while (n < edges.size() && edges[n].lo == edges[e].lo && edges[n].hi == edges[e].hi) {
                ++n;
            }
            if (n - e == 2u) {
                const EdgeAdjacency a0 = edges[e];
                const EdgeAdjacency a1 = edges[e + 1u];
                if (a0.triangle_index < tcount && a1.triangle_index < tcount &&
                    tri_locked[a0.triangle_index] == 0u && tri_locked[a1.triangle_index] == 0u) {
                    const std::uint32_t c = a0.opposite;
                    const std::uint32_t d = a1.opposite;
                    if (c != d && c != a0.lo && c != a0.hi && d != a0.lo && d != a0.hi) {
                        const MeshTriangle before0 = triangles[a0.triangle_index];
                        const MeshTriangle before1 = triangles[a1.triangle_index];
                        const MeshTriangle after0{c, d, a0.lo};
                        const MeshTriangle after1{d, c, a0.hi};

                        bool reject_nonmanifold = false;
                        if (config.enforce_manifold) {
                            const auto it_occ = edge_occurrence.find(edge_key(c, d));
                            const std::uint32_t occ = (it_occ == edge_occurrence.end()) ? 0u : it_occ->second;
                            if (occ > 0u) {
                                reject_nonmanifold = true;
                            }
                        }
                        if (reject_nonmanifold) {
                            result.flip_reject_nonmanifold += 1u;
                            e = n;
                            continue;
                        }

                        if (tri_valid(after0, vcount) && tri_valid(after1, vcount) &&
                            area_of(vertices, after0) >= MIN_TRIANGLE_AREA &&
                            area_of(vertices, after1) >= MIN_TRIANGLE_AREA) {
                            const float before_quality = std::max(
                                max_triangle_cosine(vertices, before0),
                                max_triangle_cosine(vertices, before1));
                            const float after_quality = std::max(
                                max_triangle_cosine(vertices, after0),
                                max_triangle_cosine(vertices, after1));
                            if (after_quality + 1e-6f < before_quality) {
                                const math::Vec3 n_before0 = triangle_normal(vertices, before0);
                                const math::Vec3 n_before1 = triangle_normal(vertices, before1);
                                const math::Vec3 n_after0 = triangle_normal(vertices, after0);
                                const math::Vec3 n_after1 = triangle_normal(vertices, after1);
                                const bool normal_ok =
                                    std::fabs(dot3(n_before0, n_after0)) >= min_normal_dot &&
                                    std::fabs(dot3(n_before1, n_after1)) >= min_normal_dot;
                                if (!normal_ok) {
                                    result.collapse_reject_normal_flip += 1u;
                                } else {
                                    bool has_local_intersection = false;
                                    if (config.reject_local_self_intersection) {
                                        std::vector<std::size_t> neighborhood;
                                        neighborhood.reserve(32u);
                                        auto add_neighborhood = [&](std::uint32_t vid) {
                                            if (vid >= flip_vertex_tris.size()) {
                                                return;
                                            }
                                            for (std::size_t tri_idx : flip_vertex_tris[vid]) {
                                                if (tri_idx == a0.triangle_index || tri_idx == a1.triangle_index) {
                                                    continue;
                                                }
                                                neighborhood.push_back(tri_idx);
                                            }
                                        };
                                        add_neighborhood(a0.lo);
                                        add_neighborhood(a0.hi);
                                        add_neighborhood(c);
                                        add_neighborhood(d);
                                        std::sort(neighborhood.begin(), neighborhood.end());
                                        neighborhood.erase(std::unique(neighborhood.begin(), neighborhood.end()), neighborhood.end());
                                        for (std::size_t tri_idx : neighborhood) {
                                            const MeshTriangle other = triangles[tri_idx];
                                            if (!tri_valid(other, vcount)) {
                                                continue;
                                            }
                                            if (!share_vertex(after0, other) &&
                                                triangles_intersect_strict(vertices, after0, other)) {
                                                has_local_intersection = true;
                                                break;
                                            }
                                            if (!share_vertex(after1, other) &&
                                                triangles_intersect_strict(vertices, after1, other)) {
                                                has_local_intersection = true;
                                                break;
                                            }
                                        }
                                    }
                                    if (has_local_intersection) {
                                        result.flip_reject_self_intersection += 1u;
                                    } else {
                                        triangles[a0.triangle_index] = after0;
                                        triangles[a1.triangle_index] = after1;
                                        tri_locked[a0.triangle_index] = 1u;
                                        tri_locked[a1.triangle_index] = 1u;
                                        edge_occurrence[edge_key(a0.lo, a0.hi)] -= 2u;
                                        edge_occurrence[edge_key(c, d)] += 2u;
                                        result.flips_performed += 1u;
                                        ++iteration_ops;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            e = n;
        }

        // Step 4: Laplacian smoothing with optional boundary protection.
        std::vector<std::uint8_t> boundary_vertices;
        if (config.preserve_boundary_vertices) {
            mark_boundary_vertices(triangles, tcount, vcount, &boundary_vertices);
        }

        std::vector<math::Vec3> accum(vcount, math::Vec3(0.0f, 0.0f, 0.0f));
        std::vector<std::uint32_t> degree(vcount, 0u);
        for (std::size_t i = 0u; i < tcount; ++i) {
            const MeshTriangle tri = triangles[i];
            if (!tri_valid(tri, vcount)) {
                continue;
            }
            const std::uint32_t ids[3] = {tri.i0, tri.i1, tri.i2};
            for (int k = 0; k < 3; ++k) {
                const std::uint32_t v0 = ids[k];
                const std::uint32_t v1 = ids[(k + 1) % 3];
                accum[v0] = add3(accum[v0], vertices[v1].position);
                degree[v0] += 1u;
            }
        }
        for (std::size_t i = 0u; i < vcount; ++i) {
            if (degree[i] == 0u) {
                continue;
            }
            if (config.preserve_boundary_vertices &&
                i < boundary_vertices.size() &&
                boundary_vertices[i] != 0u) {
                continue;
            }
            const float inv = 1.0f / static_cast<float>(degree[i]);
            const math::Vec3 target = mul3(accum[i], inv);
            vertices[i].position = add3(
                mul3(vertices[i].position, 1.0f - config.smoothing_lambda),
                mul3(target, config.smoothing_lambda));
        }

        result.iterations_used = it + 1;
        if (iteration_ops == 0u) {
            break;
        }
    }

    *vertex_count = vcount;
    *triangle_count = tcount;
    result.output_vertex_count = vcount;
    result.output_triangle_count = tcount;
    *out_result = result;
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
