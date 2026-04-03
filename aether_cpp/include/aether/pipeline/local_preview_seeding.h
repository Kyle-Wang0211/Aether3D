// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_LOCAL_PREVIEW_SEEDING_H
#define AETHER_PIPELINE_LOCAL_PREVIEW_SEEDING_H

#include <cstdint>
#include <unordered_set>
#include <vector>

#include "aether/splat/packed_splats.h"

namespace aether {
namespace pipeline {

struct FrameInput;

namespace local_preview_seeding {

struct PreviewSeedStats {
    std::uint32_t candidates{0};
    std::uint32_t accepted{0};
    std::uint32_t rejected{0};
    std::uint64_t accepted_quality_milli_sum{0};
    float median_depth{1.0f};
    std::uint32_t downsample_factor{0};
    bool init_pass{false};
};

std::uint32_t synthesize_preview_feature_points_from_depth(
    FrameInput& input,
    const float* depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    bool init_pass) noexcept;

PreviewSeedStats build_preview_sampled_seeds_from_depth(
    const unsigned char* bgra,
    int img_w,
    int img_h,
    const float* depth,
    int depth_w,
    int depth_h,
    float fx,
    float fy,
    float cx,
    float cy,
    const float* cam2world,
    bool init_pass,
    std::unordered_set<std::int64_t>& seeded_cells,
    std::vector<splat::GaussianParams>& out_new_gaussians) noexcept;

}  // namespace local_preview_seeding

// Active local product semantics are subject-first. Keep the older
// local_preview_seeding namespace as the compatibility implementation while
// exposing clearer native wrappers for new code.
namespace local_subject_first_seeding {

using SubjectFirstSeedStats = local_preview_seeding::PreviewSeedStats;

inline std::uint32_t synthesize_subject_first_feature_points_from_depth(
    FrameInput& input,
    const float* depth,
    std::uint32_t depth_w,
    std::uint32_t depth_h,
    bool init_pass) noexcept
{
    return local_preview_seeding::synthesize_preview_feature_points_from_depth(
        input,
        depth,
        depth_w,
        depth_h,
        init_pass);
}

inline SubjectFirstSeedStats build_subject_first_sampled_seeds_from_depth(
    const unsigned char* bgra,
    int img_w,
    int img_h,
    const float* depth,
    int depth_w,
    int depth_h,
    float fx,
    float fy,
    float cx,
    float cy,
    const float* cam2world,
    bool init_pass,
    std::unordered_set<std::int64_t>& seeded_cells,
    std::vector<splat::GaussianParams>& out_new_gaussians) noexcept
{
    return local_preview_seeding::build_preview_sampled_seeds_from_depth(
        bgra,
        img_w,
        img_h,
        depth,
        depth_w,
        depth_h,
        fx,
        fy,
        cx,
        cy,
        cam2world,
        init_pass,
        seeded_cells,
        out_new_gaussians);
}

}  // namespace local_subject_first_seeding
}  // namespace pipeline
}  // namespace aether

#endif  // AETHER_PIPELINE_LOCAL_PREVIEW_SEEDING_H
