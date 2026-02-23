// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/frustum_culler.h"

#include "aether/core/numeric_guard.h"
#include "aether/tsdf/tsdf_constants.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace aether {
namespace render {
namespace {

struct BlockCandidate {
    tsdf::BlockIndex block{};
    float near_depth{0.0f};
    float far_depth{0.0f};
    int min_x{0};
    int min_y{0};
    int max_x{0};
    int max_y{0};
};

inline float clampf(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

inline void row_of(const float* m, int row, float out[4]) {
    out[0] = m[row + 0];
    out[1] = m[row + 4];
    out[2] = m[row + 8];
    out[3] = m[row + 12];
}

inline void normalize_plane(FrustumPlane* p) {
    const float n = std::sqrt(p->a * p->a + p->b * p->b + p->c * p->c);
    if (n <= 1e-8f) {
        return;
    }
    p->a /= n;
    p->b /= n;
    p->c /= n;
    p->d /= n;
    // C01 NumericGuard: guard plane coefficients after division
    aether::core::guard_finite_scalar(&p->a);
    aether::core::guard_finite_scalar(&p->b);
    aether::core::guard_finite_scalar(&p->c);
    aether::core::guard_finite_scalar(&p->d);
}

inline void mat_mul_4x4(const float* a, const float* b, float out[16]) {
    // Column-major multiply out = a * b.
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

inline void transform_point4(const float* m, float x, float y, float z, float out[4]) {
    out[0] = m[0] * x + m[4] * y + m[8] * z + m[12];
    out[1] = m[1] * x + m[5] * y + m[9] * z + m[13];
    out[2] = m[2] * x + m[6] * y + m[10] * z + m[14];
    out[3] = m[3] * x + m[7] * y + m[11] * z + m[15];
}

void rebuild_hiz_mips(
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
                const std::uint32_t cx0 = std::min<std::uint32_t>(prev_res - 1u, x * 2u);
                const std::uint32_t cx1 = std::min<std::uint32_t>(prev_res - 1u, x * 2u + 1u);
                const std::uint32_t cy0 = std::min<std::uint32_t>(prev_res - 1u, y * 2u);
                const std::uint32_t cy1 = std::min<std::uint32_t>(prev_res - 1u, y * 2u + 1u);
                const float z00 = prev[static_cast<std::size_t>(cy0) * prev_res + cx0];
                const float z01 = prev[static_cast<std::size_t>(cy0) * prev_res + cx1];
                const float z10 = prev[static_cast<std::size_t>(cy1) * prev_res + cx0];
                const float z11 = prev[static_cast<std::size_t>(cy1) * prev_res + cx1];
                curr[static_cast<std::size_t>(y) * curr_res + x] =
                    std::max(std::max(z00, z01), std::max(z10, z11));
            }
        }
    }
}

std::size_t select_hiz_level(const BlockCandidate& candidate, std::size_t max_level) {
    const int width = candidate.max_x - candidate.min_x + 1;
    const int height = candidate.max_y - candidate.min_y + 1;
    const int span = std::max(width, height);
    if (span > 16 && max_level >= 2u) {
        return 2u;
    }
    if (span > 8 && max_level >= 1u) {
        return 1u;
    }
    return 0u;
}

}  // namespace

void extract_frustum_planes(const float* view_projection_matrix, FrustumPlane planes[6]) {
    if (view_projection_matrix == nullptr || planes == nullptr) {
        return;
    }
    float r0[4]{};
    float r1[4]{};
    float r2[4]{};
    float r3[4]{};
    row_of(view_projection_matrix, 0, r0);
    row_of(view_projection_matrix, 1, r1);
    row_of(view_projection_matrix, 2, r2);
    row_of(view_projection_matrix, 3, r3);

    auto make_plane = [&](int idx, const float* add, float sign) {
        FrustumPlane p{};
        p.a = r3[0] + sign * add[0];
        p.b = r3[1] + sign * add[1];
        p.c = r3[2] + sign * add[2];
        p.d = r3[3] + sign * add[3];
        normalize_plane(&p);
        planes[idx] = p;
    };

    make_plane(0, r0, +1.0f);  // Left
    make_plane(1, r0, -1.0f);  // Right
    make_plane(2, r1, +1.0f);  // Bottom
    make_plane(3, r1, -1.0f);  // Top
    make_plane(4, r2, +1.0f);  // Near
    make_plane(5, r2, -1.0f);  // Far
}

bool aabb_outside_frustum(
    const FrustumPlane planes[6],
    float min_x,
    float min_y,
    float min_z,
    float max_x,
    float max_y,
    float max_z) {
    for (int i = 0; i < 6; ++i) {
        const FrustumPlane& p = planes[i];
        const float px = (p.a >= 0.0f) ? max_x : min_x;
        const float py = (p.b >= 0.0f) ? max_y : min_y;
        const float pz = (p.c >= 0.0f) ? max_z : min_z;
        const float dist = p.a * px + p.b * py + p.c * pz + p.d;
        if (dist < 0.0f) {
            return true;
        }
    }
    return false;
}

core::Status cull_blocks(
    const tsdf::BlockIndex* blocks,
    std::size_t block_count,
    const float* block_voxel_sizes,
    const float* view_matrix,
    const float* projection_matrix,
    const FrustumCullConfig& config,
    FrustumCullResult* out_result) {
    if (out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_result->visible_blocks.clear();
    out_result->total_blocks = block_count;
    out_result->visible_count = 0u;
    out_result->occluded_count = 0u;
    out_result->outside_count = 0u;

    if ((block_count > 0u && blocks == nullptr) || view_matrix == nullptr || projection_matrix == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (block_count == 0u) {
        return core::Status::kOk;
    }

    float vp[16]{};
    mat_mul_4x4(projection_matrix, view_matrix, vp);
    // C01 NumericGuard: guard VP matrix after multiply
    core::guard_finite_vector(vp, 16u);
    FrustumPlane planes[6]{};
    extract_frustum_planes(vp, planes);

    std::vector<BlockCandidate> candidates;
    candidates.reserve(block_count);

    for (std::size_t i = 0u; i < block_count; ++i) {
        const float voxel_size = (block_voxel_sizes != nullptr)
            ? block_voxel_sizes[i]
            : tsdf::VOXEL_SIZE_MID;
        const float block_world = voxel_size * static_cast<float>(tsdf::BLOCK_SIZE);

        const float min_x = static_cast<float>(blocks[i].x) * block_world - config.block_padding;
        const float min_y = static_cast<float>(blocks[i].y) * block_world - config.block_padding;
        const float min_z = static_cast<float>(blocks[i].z) * block_world - config.block_padding;
        const float max_x = min_x + block_world + 2.0f * config.block_padding;
        const float max_y = min_y + block_world + 2.0f * config.block_padding;
        const float max_z = min_z + block_world + 2.0f * config.block_padding;

        if (aabb_outside_frustum(planes, min_x, min_y, min_z, max_x, max_y, max_z)) {
            out_result->outside_count += 1u;
            continue;
        }

        const float corners[8][3] = {
            {min_x, min_y, min_z}, {max_x, min_y, min_z}, {max_x, max_y, min_z}, {min_x, max_y, min_z},
            {min_x, min_y, max_z}, {max_x, min_y, max_z}, {max_x, max_y, max_z}, {min_x, max_y, max_z},
        };

        float near_depth = std::numeric_limits<float>::max();
        float far_depth = 0.0f;
        float min_u = static_cast<float>(config.hi_z_resolution);
        float min_v = static_cast<float>(config.hi_z_resolution);
        float max_u = 0.0f;
        float max_v = 0.0f;

        for (int c = 0; c < 8; ++c) {
            float view_p[4]{};
            transform_point4(view_matrix, corners[c][0], corners[c][1], corners[c][2], view_p);
            const float depth = std::fabs(view_p[2]);
            near_depth = std::min(near_depth, depth);
            far_depth = std::max(far_depth, depth);

            float clip[4]{};
            transform_point4(vp, corners[c][0], corners[c][1], corners[c][2], clip);
            if (std::fabs(clip[3]) <= 1e-6f) {
                continue;
            }
            const float ndc_x = clip[0] / clip[3];
            const float ndc_y = clip[1] / clip[3];
            const float sx = (ndc_x * 0.5f + 0.5f) * static_cast<float>(config.hi_z_resolution - 1u);
            const float sy = (ndc_y * 0.5f + 0.5f) * static_cast<float>(config.hi_z_resolution - 1u);
            min_u = std::min(min_u, sx);
            min_v = std::min(min_v, sy);
            max_u = std::max(max_u, sx);
            max_v = std::max(max_v, sy);
        }

        BlockCandidate candidate{};
        candidate.block = blocks[i];
        candidate.near_depth = near_depth;
        candidate.far_depth = far_depth;
        candidate.min_x = static_cast<int>(std::floor(clampf(min_u, 0.0f, static_cast<float>(config.hi_z_resolution - 1u))));
        candidate.min_y = static_cast<int>(std::floor(clampf(min_v, 0.0f, static_cast<float>(config.hi_z_resolution - 1u))));
        candidate.max_x = static_cast<int>(std::ceil(clampf(max_u, 0.0f, static_cast<float>(config.hi_z_resolution - 1u))));
        candidate.max_y = static_cast<int>(std::ceil(clampf(max_v, 0.0f, static_cast<float>(config.hi_z_resolution - 1u))));
        candidates.push_back(candidate);
    }

    std::stable_sort(candidates.begin(), candidates.end(), [](const BlockCandidate& lhs, const BlockCandidate& rhs) {
        return lhs.near_depth < rhs.near_depth;
    });

    const std::uint32_t hiz_res = std::max(1u, config.hi_z_resolution);
    std::vector<std::uint32_t> mip_resolutions;
    mip_resolutions.push_back(hiz_res);
    while (mip_resolutions.size() < 3u && mip_resolutions.back() > 1u) {
        mip_resolutions.push_back(std::max<std::uint32_t>(1u, mip_resolutions.back() / 2u));
    }
    std::vector<std::vector<float>> mips;
    mips.resize(mip_resolutions.size());
    mips[0].assign(static_cast<std::size_t>(hiz_res) * static_cast<std::size_t>(hiz_res), -1.0f);
    for (std::size_t i = 1u; i < mips.size(); ++i) {
        const std::uint32_t r = mip_resolutions[i];
        mips[i].assign(static_cast<std::size_t>(r) * static_cast<std::size_t>(r), -1.0f);
    }
    rebuild_hiz_mips(mip_resolutions, &mips);

    for (const BlockCandidate& candidate : candidates) {
        bool occluded = false;
        if (config.enable_occlusion_test) {
            const std::size_t level = select_hiz_level(candidate, mips.empty() ? 0u : (mips.size() - 1u));
            const std::uint32_t level_res = mip_resolutions[level];
            const int div = 1 << static_cast<int>(level);
            const int min_lx = std::max(0, candidate.min_x / div);
            const int min_ly = std::max(0, candidate.min_y / div);
            const int max_lx = std::min(static_cast<int>(level_res) - 1, candidate.max_x / div);
            const int max_ly = std::min(static_cast<int>(level_res) - 1, candidate.max_y / div);
            bool all_covered = true;
            for (int y = min_ly; y <= max_ly; ++y) {
                for (int x = min_lx; x <= max_lx; ++x) {
                    const std::size_t idx = static_cast<std::size_t>(y) * level_res + static_cast<std::size_t>(x);
                    const float z = mips[level][idx];
                    if (z < 0.0f || candidate.near_depth <= z) {
                        all_covered = false;
                        break;
                    }
                }
                if (!all_covered) {
                    break;
                }
            }
            occluded = all_covered;
        }

        if (occluded) {
            out_result->occluded_count += 1u;
            continue;
        }

        out_result->visible_blocks.push_back(candidate.block);
        out_result->visible_count += 1u;
        for (int y = candidate.min_y; y <= candidate.max_y; ++y) {
            for (int x = candidate.min_x; x <= candidate.max_x; ++x) {
                const std::size_t idx = static_cast<std::size_t>(y) * hiz_res + static_cast<std::size_t>(x);
                mips[0][idx] = std::max(mips[0][idx], candidate.far_depth);
            }
        }
        rebuild_hiz_mips(mip_resolutions, &mips);
    }

    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
