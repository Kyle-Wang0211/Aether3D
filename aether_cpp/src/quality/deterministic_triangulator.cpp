// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/deterministic_triangulator.h"

#include <array>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <tuple>
#include <vector>

namespace aether {
namespace quality {
namespace {

inline bool finite(double v) {
    return std::isfinite(v);
}

inline double distance(const Point2d& p1, const Point2d& p2) {
    const double dx = p2.x - p1.x;
    const double dy = p2.y - p1.y;
    return std::sqrt(dx * dx + dy * dy);
}

inline std::int64_t to_q24_40(double value) {
    static constexpr double kScale = static_cast<double>(1ULL << 40);
    const double scaled = std::nearbyint(value * kScale);
    if (scaled > static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
        return std::numeric_limits<std::int64_t>::max();
    }
    if (scaled < static_cast<double>(std::numeric_limits<std::int64_t>::min())) {
        return std::numeric_limits<std::int64_t>::min();
    }
    return static_cast<std::int64_t>(scaled);
}

inline __int128 fixed_sq_distance_q24_40(const Point2d& p1, const Point2d& p2) {
    const std::int64_t dx = to_q24_40(p2.x) - to_q24_40(p1.x);
    const std::int64_t dy = to_q24_40(p2.y) - to_q24_40(p1.y);
    return static_cast<__int128>(dx) * static_cast<__int128>(dx) +
           static_cast<__int128>(dy) * static_cast<__int128>(dy);
}

inline __int128 orient2d_q24_40(const Point2d& a, const Point2d& b, const Point2d& c) {
    const std::int64_t ax = to_q24_40(a.x);
    const std::int64_t ay = to_q24_40(a.y);
    const std::int64_t bx = to_q24_40(b.x);
    const std::int64_t by = to_q24_40(b.y);
    const std::int64_t cx = to_q24_40(c.x);
    const std::int64_t cy = to_q24_40(c.y);
    return (static_cast<__int128>(bx - ax) * static_cast<__int128>(cy - ay)) -
           (static_cast<__int128>(by - ay) * static_cast<__int128>(cx - ax));
}

inline Point2d centroid(const Triangle2d& t) {
    return Point2d{(t.a.x + t.b.x + t.c.x) / 3.0, (t.a.y + t.b.y + t.c.y) / 3.0};
}

inline std::int64_t canonical_vertex_key(const Point2d& p, double epsilon) {
    const double safe_eps = std::max(epsilon, 1e-12);
    const double scale = 1.0 / safe_eps;
    const auto qx = static_cast<std::int64_t>(std::nearbyint(p.x * scale));
    const auto qy = static_cast<std::int64_t>(std::nearbyint(p.y * scale));
    const std::uint64_t ux = static_cast<std::uint64_t>(qx);
    const std::uint64_t uy = static_cast<std::uint64_t>(qy);
    const std::uint64_t mixed = (ux * 0x9E3779B185EBCA87ull) ^ (uy * 0xC2B2AE3D27D4EB4Full);
    return static_cast<std::int64_t>(mixed);
}

inline std::tuple<std::int64_t, std::int64_t, std::int64_t> min_vertex_indices(const Triangle2d& t, double epsilon) {
    std::vector<std::int64_t> keys;
    keys.reserve(3);
    keys.push_back(canonical_vertex_key(t.a, epsilon));
    keys.push_back(canonical_vertex_key(t.b, epsilon));
    keys.push_back(canonical_vertex_key(t.c, epsilon));
    std::sort(keys.begin(), keys.end());
    return {keys[0], keys[1], keys[2]};
}

}  // namespace

aether::core::Status triangulate_quad(
    const Point2d quad_vertices[4],
    double epsilon,
    Triangle2d out_triangles[2]) {
    if (quad_vertices == nullptr || out_triangles == nullptr || !finite(epsilon) || epsilon <= 0.0) {
        return aether::core::Status::kInvalidArgument;
    }

    for (int i = 0; i < 4; ++i) {
        if (!finite(quad_vertices[i].x) || !finite(quad_vertices[i].y)) {
            return aether::core::Status::kInvalidArgument;
        }
    }

    std::vector<Point2d> vertices = {
        quad_vertices[0], quad_vertices[1], quad_vertices[2], quad_vertices[3]};

    const auto min_it = std::min_element(
        vertices.begin(),
        vertices.end(),
        [](const Point2d& lhs, const Point2d& rhs) {
            if (lhs.x != rhs.x) {
                return lhs.x < rhs.x;
            }
            return lhs.y < rhs.y;
        });

    const std::size_t min_index = static_cast<std::size_t>(std::distance(vertices.begin(), min_it));
    std::array<Point2d, 4> normalized{};
    for (std::size_t i = 0u; i < 4u; ++i) {
        normalized[i] = vertices[(min_index + i) % 4u];
    }

    const double diag1 = distance(normalized[0], normalized[2]);
    const double diag2 = distance(normalized[1], normalized[3]);

    bool diag1_shorter = diag1 < diag2;
    if (std::fabs(diag1 - diag2) < epsilon) {
        // Deterministic tie-break path using Q24.40 fixed-point arithmetic.
        const __int128 fixed1 = fixed_sq_distance_q24_40(normalized[0], normalized[2]);
        const __int128 fixed2 = fixed_sq_distance_q24_40(normalized[1], normalized[3]);
        if (fixed1 != fixed2) {
            diag1_shorter = fixed1 < fixed2;
        } else {
            // Final tie-break keeps winding deterministic for degenerate quads.
            const __int128 area = orient2d_q24_40(normalized[0], normalized[1], normalized[2]);
            diag1_shorter = area >= 0;
        }
    }

    if (diag1_shorter) {
        out_triangles[0] = Triangle2d{normalized[0], normalized[1], normalized[2]};
        out_triangles[1] = Triangle2d{normalized[0], normalized[2], normalized[3]};
    } else {
        out_triangles[0] = Triangle2d{normalized[0], normalized[1], normalized[3]};
        out_triangles[1] = Triangle2d{normalized[1], normalized[2], normalized[3]};
    }

    return aether::core::Status::kOk;
}

aether::core::Status sort_triangles(
    const Triangle2d* triangles,
    std::size_t triangle_count,
    double epsilon,
    std::vector<Triangle2d>* out_sorted) {
    if (out_sorted == nullptr || !finite(epsilon) || epsilon <= 0.0) {
        return aether::core::Status::kInvalidArgument;
    }
    if (triangle_count > 0u && triangles == nullptr) {
        return aether::core::Status::kInvalidArgument;
    }

    out_sorted->assign(triangles, triangles + triangle_count);
    std::stable_sort(
        out_sorted->begin(),
        out_sorted->end(),
        [epsilon](const Triangle2d& lhs, const Triangle2d& rhs) {
            const auto lhs_idx = min_vertex_indices(lhs, epsilon);
            const auto rhs_idx = min_vertex_indices(rhs, epsilon);
            if (lhs_idx != rhs_idx) {
                return lhs_idx < rhs_idx;
            }

            const Point2d cl = centroid(lhs);
            const Point2d cr = centroid(rhs);
            if (std::fabs(cl.x - cr.x) > epsilon) {
                return cl.x < cr.x;
            }
            return cl.y < cr.y;
        });

    return aether::core::Status::kOk;
}

}  // namespace quality
}  // namespace aether
