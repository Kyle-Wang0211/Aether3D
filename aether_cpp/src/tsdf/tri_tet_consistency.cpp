// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/tri_tet_consistency.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_map>

namespace aether {
namespace tsdf {
namespace {

using VertexMap = std::unordered_map<std::int32_t, const TriTetVertex*>;

inline math::Vec3 tri_centroid(const TriTetTriangle& tri) {
    return math::Vec3(
        (tri.a.x + tri.b.x + tri.c.x) / 3.0f,
        (tri.a.y + tri.b.y + tri.c.y) / 3.0f,
        (tri.a.z + tri.b.z + tri.c.z) / 3.0f);
}

inline math::Vec3 tet_centroid(
    const TriTetVertex& v0,
    const TriTetVertex& v1,
    const TriTetVertex& v2,
    const TriTetVertex& v3) {
    return math::Vec3(
        (v0.position.x + v1.position.x + v2.position.x + v3.position.x) * 0.25f,
        (v0.position.y + v1.position.y + v2.position.y + v3.position.y) * 0.25f,
        (v0.position.z + v1.position.z + v2.position.z + v3.position.z) * 0.25f);
}

inline float distance3(const math::Vec3& a, const math::Vec3& b) {
    const float dx = a.x - b.x;
    const float dy = a.y - b.y;
    const float dz = a.z - b.z;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

inline float class_score(TriTetConsistencyClass cls) {
    switch (cls) {
        case TriTetConsistencyClass::kMeasured:
            return 1.0f;
        case TriTetConsistencyClass::kEstimated:
            return 0.6f;
        case TriTetConsistencyClass::kUnknown:
            return 0.1f;
    }
    return 0.1f;
}

}  // namespace

core::Status kuhn5_table(int parity, int out_vertices[20]) {
    if (out_vertices == nullptr) {
        return core::Status::kInvalidArgument;
    }
    static constexpr int kParity0[20] = {
        0, 1, 3, 7,
        0, 3, 2, 7,
        0, 2, 6, 7,
        0, 6, 4, 7,
        0, 4, 5, 7};
    static constexpr int kParity1[20] = {
        1, 0, 2, 6,
        1, 2, 3, 6,
        1, 3, 7, 6,
        1, 7, 5, 6,
        1, 5, 4, 6};

    const int* src = ((parity & 1) == 0) ? kParity0 : kParity1;
    for (int i = 0; i < 20; ++i) {
        out_vertices[i] = src[i];
    }
    return core::Status::kOk;
}

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
    TriTetReport* out_report) {
    if (out_report == nullptr) {
        return core::Status::kInvalidArgument;
    }
    *out_report = TriTetReport{};
    if ((triangle_count > 0u && triangles == nullptr) ||
        (vertex_count > 0u && vertices == nullptr) ||
        (tetrahedron_count > 0u && tetrahedra == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (triangle_count > binding_capacity || (triangle_count > 0u && out_bindings == nullptr)) {
        return core::Status::kOutOfRange;
    }
    if (triangle_count == 0u || vertex_count == 0u || tetrahedron_count == 0u) {
        return core::Status::kOk;
    }
    if (config.measured_min_view_count < 0 ||
        config.estimated_min_view_count < 0 ||
        !std::isfinite(config.max_triangle_to_tet_distance) ||
        config.max_triangle_to_tet_distance < 0.0f) {
        return core::Status::kInvalidArgument;
    }

    VertexMap vertex_lookup;
    vertex_lookup.reserve(vertex_count);
    for (std::size_t i = 0u; i < vertex_count; ++i) {
        vertex_lookup[vertices[i].index] = &vertices[i];
    }

    float score_sum = 0.0f;
    std::int32_t measured = 0;
    std::int32_t estimated = 0;
    std::int32_t unknown = 0;

    for (std::size_t i = 0u; i < triangle_count; ++i) {
        TriTetBinding binding{};
        binding.triangle_index = static_cast<std::int32_t>(i);
        binding.tetrahedron_id = -1;
        binding.classification = TriTetConsistencyClass::kUnknown;
        binding.tri_to_tet_distance = std::numeric_limits<float>::infinity();
        binding.min_tet_view_count = 0;

        const math::Vec3 tri_center = tri_centroid(triangles[i]);
        bool has_candidate = false;
        float best_distance = std::numeric_limits<float>::infinity();
        std::int32_t best_tet_id = std::numeric_limits<std::int32_t>::max();
        std::int32_t best_min_views = 0;

        for (std::size_t t = 0u; t < tetrahedron_count; ++t) {
            const TriTetTetrahedron& tet = tetrahedra[t];
            const auto it0 = vertex_lookup.find(tet.v0);
            const auto it1 = vertex_lookup.find(tet.v1);
            const auto it2 = vertex_lookup.find(tet.v2);
            const auto it3 = vertex_lookup.find(tet.v3);
            if (it0 == vertex_lookup.end() || it1 == vertex_lookup.end() ||
                it2 == vertex_lookup.end() || it3 == vertex_lookup.end()) {
                continue;
            }

            const TriTetVertex& v0 = *it0->second;
            const TriTetVertex& v1 = *it1->second;
            const TriTetVertex& v2 = *it2->second;
            const TriTetVertex& v3 = *it3->second;
            const math::Vec3 tet_center = tet_centroid(v0, v1, v2, v3);
            const float dist = distance3(tri_center, tet_center);
            const std::int32_t min_views = std::min(
                std::min(v0.view_count, v1.view_count),
                std::min(v2.view_count, v3.view_count));

            const bool better = (!has_candidate || dist < best_distance ||
                (std::fabs(dist - best_distance) < 1e-7f && tet.id < best_tet_id));
            if (better) {
                has_candidate = true;
                best_distance = dist;
                best_tet_id = tet.id;
                best_min_views = min_views;
            }
        }

        if (!has_candidate) {
            ++unknown;
            score_sum += class_score(TriTetConsistencyClass::kUnknown);
            out_bindings[i] = binding;
            continue;
        }

        binding.tetrahedron_id = best_tet_id;
        binding.tri_to_tet_distance = best_distance;
        binding.min_tet_view_count = best_min_views;
        if (best_min_views >= config.measured_min_view_count &&
            best_distance <= config.max_triangle_to_tet_distance) {
            binding.classification = TriTetConsistencyClass::kMeasured;
            ++measured;
        } else if (best_min_views >= config.estimated_min_view_count) {
            binding.classification = TriTetConsistencyClass::kEstimated;
            ++estimated;
        } else {
            binding.classification = TriTetConsistencyClass::kUnknown;
            ++unknown;
        }

        score_sum += class_score(binding.classification);
        out_bindings[i] = binding;
    }

    out_report->measured_count = measured;
    out_report->estimated_count = estimated;
    out_report->unknown_count = unknown;
    out_report->combined_score = triangle_count > 0u
        ? score_sum / static_cast<float>(triangle_count)
        : 0.0f;
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
