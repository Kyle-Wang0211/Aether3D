// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_RENDER_MATH_UTILS_H
#define AETHER_CPP_RENDER_RENDER_MATH_UTILS_H

#ifdef __cplusplus

// Shared render-module math utilities.
// Extracted from frustum_culler.cpp / two_pass_culler.cpp to eliminate
// duplicated clampf, mat_mul_4x4, transform_point4, rebuild_hiz_mips.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace render {
namespace render_math {

/// Clamp a float to [lo, hi].
inline float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

/// Column-major 4×4 matrix multiply: out = a * b.
inline void mat_mul_4x4(const float* a, const float* b, float out[16]) {
    for (int c = 0; c < 4; ++c) {
        for (int r = 0; r < 4; ++r) {
            out[c * 4 + r] =
                a[0 * 4 + r] * b[c * 4 + 0] +
                a[1 * 4 + r] * b[c * 4 + 1] +
                a[2 * 4 + r] * b[c * 4 + 2] +
                a[3 * 4 + r] * b[c * 4 + 3];
        }
    }
}

/// Transform a 3D point by a column-major 4×4 matrix, producing homogeneous [x,y,z,w].
inline void transform_point4(const float* m, float x, float y, float z, float out[4]) {
    out[0] = m[0] * x + m[4] * y + m[8] * z + m[12];
    out[1] = m[1] * x + m[5] * y + m[9] * z + m[13];
    out[2] = m[2] * x + m[6] * y + m[10] * z + m[14];
    out[3] = m[3] * x + m[7] * y + m[11] * z + m[15];
}

/// Rebuild Hi-Z mip chain from level 0 (base) upward.
/// Each higher level texel takes the max of the 2×2 block below it.
inline void rebuild_hiz_mips(
    const std::vector<std::uint32_t>& mip_resolutions,
    std::vector<std::vector<float>>* out_mips) {
    if (out_mips == nullptr || out_mips->empty()) {
        return;
    }
    for (std::size_t level = 1u; level < out_mips->size(); ++level) {
        const std::uint32_t prev_res = mip_resolutions[level - 1u];
        const std::uint32_t curr_res = mip_resolutions[level];
        const std::vector<float>& prev = (*out_mips)[level - 1u];
        std::vector<float>& curr = (*out_mips)[level];
        curr.assign(static_cast<std::size_t>(curr_res) * static_cast<std::size_t>(curr_res), -1.0f);
        for (std::uint32_t y = 0u; y < curr_res; ++y) {
            for (std::uint32_t x = 0u; x < curr_res; ++x) {
                const std::uint32_t sx0 = std::min<std::uint32_t>(prev_res - 1u, x * 2u);
                const std::uint32_t sx1 = std::min<std::uint32_t>(prev_res - 1u, x * 2u + 1u);
                const std::uint32_t sy0 = std::min<std::uint32_t>(prev_res - 1u, y * 2u);
                const std::uint32_t sy1 = std::min<std::uint32_t>(prev_res - 1u, y * 2u + 1u);
                const float z00 = prev[static_cast<std::size_t>(sy0) * prev_res + sx0];
                const float z01 = prev[static_cast<std::size_t>(sy0) * prev_res + sx1];
                const float z10 = prev[static_cast<std::size_t>(sy1) * prev_res + sx0];
                const float z11 = prev[static_cast<std::size_t>(sy1) * prev_res + sx1];
                curr[static_cast<std::size_t>(y) * curr_res + x] =
                    std::max(std::max(z00, z01), std::max(z10, z11));
            }
        }
    }
}

/// Incremental Hi-Z mip update: propagate a dirty rectangle from level 0 upward.
/// Only recomputes the mip texels that overlap the changed region.
/// dirty_min_x/y, dirty_max_x/y are pixel coordinates in level 0.
inline void rebuild_hiz_mips_incremental(
    const std::vector<std::uint32_t>& mip_resolutions,
    std::vector<std::vector<float>>* out_mips,
    int dirty_min_x,
    int dirty_min_y,
    int dirty_max_x,
    int dirty_max_y) {
    if (out_mips == nullptr || out_mips->empty()) {
        return;
    }
    // Track the dirty region as it propagates through mip levels.
    int d_min_x = dirty_min_x;
    int d_min_y = dirty_min_y;
    int d_max_x = dirty_max_x;
    int d_max_y = dirty_max_y;

    for (std::size_t level = 1u; level < out_mips->size(); ++level) {
        const std::uint32_t prev_res = mip_resolutions[level - 1u];
        const std::uint32_t curr_res = mip_resolutions[level];
        const std::vector<float>& prev = (*out_mips)[level - 1u];
        std::vector<float>& curr = (*out_mips)[level];

        // Map dirty rect from previous level to current level.
        const int lo_x = std::max(0, d_min_x / 2);
        const int lo_y = std::max(0, d_min_y / 2);
        const int hi_x = std::min(static_cast<int>(curr_res) - 1, d_max_x / 2);
        const int hi_y = std::min(static_cast<int>(curr_res) - 1, d_max_y / 2);

        for (int y = lo_y; y <= hi_y; ++y) {
            for (int x = lo_x; x <= hi_x; ++x) {
                const std::uint32_t sx0 = std::min<std::uint32_t>(prev_res - 1u, static_cast<std::uint32_t>(x) * 2u);
                const std::uint32_t sx1 = std::min<std::uint32_t>(prev_res - 1u, static_cast<std::uint32_t>(x) * 2u + 1u);
                const std::uint32_t sy0 = std::min<std::uint32_t>(prev_res - 1u, static_cast<std::uint32_t>(y) * 2u);
                const std::uint32_t sy1 = std::min<std::uint32_t>(prev_res - 1u, static_cast<std::uint32_t>(y) * 2u + 1u);
                const float z00 = prev[static_cast<std::size_t>(sy0) * prev_res + sx0];
                const float z01 = prev[static_cast<std::size_t>(sy0) * prev_res + sx1];
                const float z10 = prev[static_cast<std::size_t>(sy1) * prev_res + sx0];
                const float z11 = prev[static_cast<std::size_t>(sy1) * prev_res + sx1];
                curr[static_cast<std::size_t>(y) * curr_res + static_cast<std::size_t>(x)] =
                    std::max(std::max(z00, z01), std::max(z10, z11));
            }
        }
        // Shrink dirty rect for next level.
        d_min_x = lo_x;
        d_min_y = lo_y;
        d_max_x = hi_x;
        d_max_y = hi_y;
    }
}

}  // namespace render_math
}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_RENDER_MATH_UTILS_H
