// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MATH_MAT4_H
#define AETHER_MATH_MAT4_H

namespace aether {
namespace math {

struct Mat4 {
    float m[16];  // column-major
    Mat4() { for (int i = 0; i < 16; ++i) m[i] = (i % 5 == 0) ? 1.0f : 0.0f; }
};

}  // namespace math
}  // namespace aether

#endif  // AETHER_MATH_MAT4_H
