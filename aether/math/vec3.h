// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MATH_VEC3_H
#define AETHER_MATH_VEC3_H

#include <cmath>

namespace aether {
namespace math {

struct Vec3 {
    float x{0}, y{0}, z{0};
    Vec3() = default;
    Vec3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
    float length() const { return std::sqrt(x*x + y*y + z*z); }
};

}  // namespace math
}  // namespace aether

#endif  // AETHER_MATH_VEC3_H
