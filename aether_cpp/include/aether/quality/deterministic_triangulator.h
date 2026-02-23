// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_DETERMINISTIC_TRIANGULATOR_H
#define AETHER_QUALITY_DETERMINISTIC_TRIANGULATOR_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <tuple>
#include <vector>

namespace aether {
namespace quality {

struct Point2d {
    double x{0.0};
    double y{0.0};

    bool operator==(const Point2d& rhs) const {
        return x == rhs.x && y == rhs.y;
    }
};

struct Triangle2d {
    Point2d a;
    Point2d b;
    Point2d c;
};

aether::core::Status triangulate_quad(
    const Point2d quad_vertices[4],
    double epsilon,
    Triangle2d out_triangles[2]);

aether::core::Status sort_triangles(
    const Triangle2d* triangles,
    std::size_t triangle_count,
    double epsilon,
    std::vector<Triangle2d>* out_sorted);

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_DETERMINISTIC_TRIANGULATOR_H
