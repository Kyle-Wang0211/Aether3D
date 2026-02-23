// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/two_pass_culler.h"

#include "aether/render/frustum_culler.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>
#include <vector>

namespace aether {
namespace render {
namespace {

inline bool supports_mesh_shader_backend(GraphicsBackend backend) {
    return backend == GraphicsBackend::kMetal || backend == GraphicsBackend::kVulkan;
}

struct MeshletCandidate {
    std::uint32_t meshlet_index{0u};
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

inline void transform_point4(const float* m, float x, float y, float z, float out[4]) {
    out[0] = m[0] * x + m[4] * y + m[8] * z + m[12];
    out[1] = m[1] * x + m[5] * y + m[9] * z + m[13];
    out[2] = m[2] * x + m[6] * y + m[10] * z + m[14];
    out[3] = m[3] * x + m[7] * y + m[11] * z + m[15];
}

void rebuild_hiz_mips(
    const std::vector<std::uint32_t>& mip_resolutions,
    std::vector<std::vector<float>>* inout_mips) {
    if (inout_mips == nullptr || inout_mips->empty()) {
        return;
    }
    for (std::size_t level = 1u; level < inout_mips->size(); ++level) {
        const std::uint32_t prev_res = mip_resolutions[level - 1u];
        const std::uint32_t curr_res = mip_resolutions[level];
        const std::vector<float>& prev = (*inout_mips)[level - 1u];
        std::vector<float>& curr = (*inout_mips)[level];
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

std::size_t select_hiz_level(const MeshletCandidate& candidate, std::size_t max_level) {
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

bool meshlet_occluded(
    const MeshletCandidate& candidate,
    const std::vector<std::uint32_t>& mip_resolutions,
    const std::vector<std::vector<float>>& mips) {
    if (mip_resolutions.empty() || mips.empty()) {
        return false;
    }
    const std::size_t level = select_hiz_level(candidate, mips.size() - 1u);
    const std::uint32_t level_res = mip_resolutions[level];
    const int div = 1 << static_cast<int>(level);
    const int min_lx = std::max(0, candidate.min_x / div);
    const int min_ly = std::max(0, candidate.min_y / div);
    const int max_lx = std::min(static_cast<int>(level_res) - 1, candidate.max_x / div);
    const int max_ly = std::min(static_cast<int>(level_res) - 1, candidate.max_y / div);

    bool fully_covered = true;
    for (int y = min_ly; y <= max_ly; ++y) {
        for (int x = min_lx; x <= max_lx; ++x) {
            const std::size_t idx = static_cast<std::size_t>(y) * level_res + static_cast<std::size_t>(x);
            const float z = mips[level][idx];
            if (z < 0.0f || candidate.near_depth <= z) {
                fully_covered = false;
                break;
            }
        }
        if (!fully_covered) {
            break;
        }
    }
    return fully_covered;
}

void write_visible_candidate(
    const MeshletCandidate& candidate,
    std::uint32_t base_res,
    std::vector<std::vector<float>>* inout_mips,
    const std::vector<std::uint32_t>& mip_resolutions) {
    if (inout_mips == nullptr || inout_mips->empty()) {
        return;
    }
    for (int y = candidate.min_y; y <= candidate.max_y; ++y) {
        for (int x = candidate.min_x; x <= candidate.max_x; ++x) {
            const std::size_t idx = static_cast<std::size_t>(y) * base_res + static_cast<std::size_t>(x);
            (*inout_mips)[0][idx] = std::max((*inout_mips)[0][idx], candidate.far_depth);
        }
    }
    rebuild_hiz_mips(mip_resolutions, inout_mips);
}

bool project_meshlet(
    const Meshlet& meshlet,
    const float* view_matrix,
    const float* view_projection_matrix,
    std::uint32_t hiz_resolution,
    MeshletCandidate* out_candidate) {
    if (view_matrix == nullptr || view_projection_matrix == nullptr || out_candidate == nullptr || hiz_resolution == 0u) {
        return false;
    }

    const float min_x = meshlet.bounds.min_x;
    const float min_y = meshlet.bounds.min_y;
    const float min_z = meshlet.bounds.min_z;
    const float max_x = meshlet.bounds.max_x;
    const float max_y = meshlet.bounds.max_y;
    const float max_z = meshlet.bounds.max_z;

    const float corners[8][3] = {
        {min_x, min_y, min_z}, {max_x, min_y, min_z}, {max_x, max_y, min_z}, {min_x, max_y, min_z},
        {min_x, min_y, max_z}, {max_x, min_y, max_z}, {max_x, max_y, max_z}, {min_x, max_y, max_z},
    };

    float near_depth = std::numeric_limits<float>::max();
    float far_depth = 0.0f;
    float min_u = static_cast<float>(hiz_resolution);
    float min_v = static_cast<float>(hiz_resolution);
    float max_u = 0.0f;
    float max_v = 0.0f;
    bool any_projected = false;

    for (int c = 0; c < 8; ++c) {
        float view_p[4]{};
        transform_point4(view_matrix, corners[c][0], corners[c][1], corners[c][2], view_p);
        const float depth = std::fabs(view_p[2]);
        near_depth = std::min(near_depth, depth);
        far_depth = std::max(far_depth, depth);

        float clip[4]{};
        transform_point4(view_projection_matrix, corners[c][0], corners[c][1], corners[c][2], clip);
        if (std::fabs(clip[3]) <= 1e-6f) {
            continue;
        }
        const float ndc_x = clip[0] / clip[3];
        const float ndc_y = clip[1] / clip[3];
        const float sx = (ndc_x * 0.5f + 0.5f) * static_cast<float>(hiz_resolution - 1u);
        const float sy = (ndc_y * 0.5f + 0.5f) * static_cast<float>(hiz_resolution - 1u);
        min_u = std::min(min_u, sx);
        min_v = std::min(min_v, sy);
        max_u = std::max(max_u, sx);
        max_v = std::max(max_v, sy);
        any_projected = true;
    }

    if (!any_projected) {
        return false;
    }

    out_candidate->near_depth = near_depth;
    out_candidate->far_depth = far_depth;
    out_candidate->min_x = static_cast<int>(std::floor(clampf(min_u, 0.0f, static_cast<float>(hiz_resolution - 1u))));
    out_candidate->min_y = static_cast<int>(std::floor(clampf(min_v, 0.0f, static_cast<float>(hiz_resolution - 1u))));
    out_candidate->max_x = static_cast<int>(std::ceil(clampf(max_u, 0.0f, static_cast<float>(hiz_resolution - 1u))));
    out_candidate->max_y = static_cast<int>(std::ceil(clampf(max_v, 0.0f, static_cast<float>(hiz_resolution - 1u))));
    if (out_candidate->min_x > out_candidate->max_x) {
        std::swap(out_candidate->min_x, out_candidate->max_x);
    }
    if (out_candidate->min_y > out_candidate->max_y) {
        std::swap(out_candidate->min_y, out_candidate->max_y);
    }
    return true;
}

}  // namespace

TwoPassTier select_two_pass_tier(const TwoPassRuntime& runtime) {
    if (!is_backend_supported_for_platform(runtime.platform, runtime.backend)) {
        return TwoPassTier::kTierC;
    }
    const bool mesh_shader_path = runtime.caps.mesh_shader_supported &&
        supports_mesh_shader_backend(runtime.backend);
    if (mesh_shader_path && runtime.caps.gpu_hzb_supported) {
        return TwoPassTier::kTierA;
    }
    if (runtime.caps.gpu_hzb_supported) {
        return TwoPassTier::kTierB;
    }
    return TwoPassTier::kTierC;
}

bool has_three_end_fallback(const TwoPassRuntime& runtime) {
    return is_backend_supported_for_platform(runtime.platform, runtime.backend);
}

core::Status cull_meshlets_two_pass(
    const Meshlet* meshlets,
    std::size_t meshlet_count,
    const float* view_matrix,
    const float* projection_matrix,
    const HiZFrameInput& previous_frame_hiz,
    const TwoPassRuntime& runtime,
    const TwoPassCullerConfig& config,
    TwoPassCullerResult* out_result) {
    if (out_result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    out_result->visible_meshlets.clear();
    out_result->pass1_rejected_meshlets.clear();
    out_result->stats = TwoPassCullerStats{};

    if ((meshlet_count > 0u && meshlets == nullptr) || view_matrix == nullptr || projection_matrix == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!has_three_end_fallback(runtime)) {
        return core::Status::kInvalidArgument;
    }
    if (meshlet_count == 0u) {
        out_result->stats.tier = select_two_pass_tier(runtime);
        return core::Status::kOk;
    }

    const std::uint32_t hiz_res = (previous_frame_hiz.depth != nullptr && previous_frame_hiz.resolution > 0u)
        ? previous_frame_hiz.resolution
        : std::max(1u, config.hi_z_resolution);
    if (hiz_res == 0u) {
        return core::Status::kInvalidArgument;
    }

    out_result->stats.tier = select_two_pass_tier(runtime);
    out_result->stats.total_meshlets = meshlet_count;

    std::vector<std::uint32_t> mip_resolutions;
    mip_resolutions.push_back(hiz_res);
    while (mip_resolutions.size() < 3u && mip_resolutions.back() > 1u) {
        mip_resolutions.push_back(std::max<std::uint32_t>(1u, mip_resolutions.back() / 2u));
    }

    std::vector<std::vector<float>> mips(mip_resolutions.size());
    mips[0].assign(static_cast<std::size_t>(hiz_res) * static_cast<std::size_t>(hiz_res), -1.0f);
    if (previous_frame_hiz.depth != nullptr && previous_frame_hiz.resolution == hiz_res) {
        const std::size_t depth_count = static_cast<std::size_t>(hiz_res) * static_cast<std::size_t>(hiz_res);
        std::copy(previous_frame_hiz.depth, previous_frame_hiz.depth + depth_count, mips[0].begin());
    }
    for (std::size_t i = 1u; i < mips.size(); ++i) {
        const std::uint32_t r = mip_resolutions[i];
        mips[i].assign(static_cast<std::size_t>(r) * static_cast<std::size_t>(r), -1.0f);
    }
    rebuild_hiz_mips(mip_resolutions, &mips);

    float vp[16]{};
    mat_mul_4x4(projection_matrix, view_matrix, vp);
    FrustumPlane planes[6]{};
    extract_frustum_planes(vp, planes);

    std::vector<MeshletCandidate> candidates;
    candidates.reserve(meshlet_count);

    for (std::size_t i = 0u; i < meshlet_count; ++i) {
        const Meshlet& meshlet = meshlets[i];
        if (aabb_outside_frustum(
                planes,
                meshlet.bounds.min_x,
                meshlet.bounds.min_y,
                meshlet.bounds.min_z,
                meshlet.bounds.max_x,
                meshlet.bounds.max_y,
                meshlet.bounds.max_z)) {
            out_result->stats.frustum_rejected += 1u;
            continue;
        }

        MeshletCandidate candidate{};
        candidate.meshlet_index = static_cast<std::uint32_t>(i);
        if (!project_meshlet(meshlet, view_matrix, vp, hiz_res, &candidate)) {
            out_result->stats.frustum_rejected += 1u;
            continue;
        }
        candidates.push_back(candidate);
    }

    std::stable_sort(candidates.begin(), candidates.end(), [](const MeshletCandidate& lhs, const MeshletCandidate& rhs) {
        return lhs.near_depth < rhs.near_depth;
    });

    std::vector<MeshletCandidate> rejected_candidates;
    rejected_candidates.reserve(candidates.size());
    std::vector<MeshletCandidate> pass1_visible_candidates;
    pass1_visible_candidates.reserve(candidates.size());

    for (const MeshletCandidate& candidate : candidates) {
        if (meshlet_occluded(candidate, mip_resolutions, mips)) {
            out_result->pass1_rejected_meshlets.push_back(candidate.meshlet_index);
            rejected_candidates.push_back(candidate);
            out_result->stats.pass1_rejected += 1u;
            continue;
        }

        out_result->visible_meshlets.push_back(candidate.meshlet_index);
        pass1_visible_candidates.push_back(candidate);
        out_result->stats.pass1_visible += 1u;
    }

    const std::size_t considered = candidates.size();
    out_result->stats.conservative_reject_ratio = (considered == 0u)
        ? 0.0f
        : static_cast<float>(out_result->stats.pass1_rejected) / static_cast<float>(considered);

    const bool pass2_allowed =
        config.enable_two_pass &&
        out_result->stats.tier != TwoPassTier::kTierC &&
        runtime.caps.gpu_hzb_supported;
    if (pass2_allowed &&
        out_result->stats.pass1_rejected > 0u &&
        out_result->stats.conservative_reject_ratio > config.pass2_retry_threshold) {
        std::vector<std::vector<float>> pass2_mips = mips;
        for (const MeshletCandidate& visible_candidate : pass1_visible_candidates) {
            write_visible_candidate(visible_candidate, hiz_res, &pass2_mips, mip_resolutions);
        }

        out_result->stats.pass2_executed = true;
        for (const MeshletCandidate& candidate : rejected_candidates) {
            if (meshlet_occluded(candidate, mip_resolutions, pass2_mips)) {
                continue;
            }
            out_result->visible_meshlets.push_back(candidate.meshlet_index);
            out_result->stats.pass2_recovered += 1u;
            write_visible_candidate(candidate, hiz_res, &pass2_mips, mip_resolutions);
        }
    }

    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
