// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_MATH_HALF_H
#define AETHER_MATH_HALF_H

#include <cstdint>
#include <cstring>

namespace aether {
namespace math {

inline float half_to_float(uint16_t h) {
    uint32_t sign = (h >> 15) & 1;
    uint32_t exp = (h >> 10) & 0x1f;
    uint32_t mant = h & 0x3ff;
    uint32_t u = (sign << 31) | ((exp + 112) << 23) | (mant << 13);
    float f;
    std::memcpy(&f, &u, sizeof(float));
    return f;
}

inline uint16_t float_to_half(float f) {
    uint32_t u;
    std::memcpy(&u, &f, sizeof(uint32_t));
    uint32_t sign = (u >> 31) & 1;
    int32_t exp = ((u >> 23) & 0xff) - 127;
    uint32_t mant = u & 0x7fffff;
    if (exp <= -14) exp = -15;
    if (exp >= 15) exp = 15;
    return static_cast<uint16_t>((sign << 15) | (((exp + 15) & 0x1f) << 10) | (mant >> 13));
}

}  // namespace math
}  // namespace aether

#endif  // AETHER_MATH_HALF_H
