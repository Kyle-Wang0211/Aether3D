// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/core/canonicalize.h"

#include <array>
#include <cstdint>
#include <cstdio>

int main() {
    int failed = 0;

    struct Vec3i {
        int32_t x;
        int32_t y;
        int32_t z;
    };
    const std::array<Vec3i, 8u> vectors{{
        {0, 0, 0},
        {1, 2, 3},
        {-1, -2, -3},
        {1024, -2048, 4096},
        {2147483647, 0, -2147483647},
        {-2147483647, 2147483647, 1},
        {123456789, -987654321, 42},
        {-42, 987654321, -123456789},
    }};

    for (const Vec3i& v : vectors) {
        int32_t ox = 0;
        int32_t oy = 0;
        int32_t oz = 0;
        aether::core::canonicalize_block(v.x, v.y, v.z, ox, oy, oz);
        if (ox != v.x || oy != v.y || oz != v.z) {
            std::fprintf(stderr, "canonicalize mismatch (%d,%d,%d)\n", v.x, v.y, v.z);
            failed++;
            continue;
        }

        int32_t iox = 0;
        int32_t ioy = 0;
        int32_t ioz = 0;
        aether::core::canonicalize_block(ox, oy, oz, iox, ioy, ioz);
        if (iox != ox || ioy != oy || ioz != oz) {
            std::fprintf(stderr, "canonicalize idempotency mismatch (%d,%d,%d)\n", v.x, v.y, v.z);
            failed++;
        }
    }
    return failed;
}
