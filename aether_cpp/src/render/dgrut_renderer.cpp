// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/render/dgrut_renderer.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>
#include <vector>

namespace {

inline float score_splat(
    const aether::render::DGRUTSplat& splat,
    const aether::render::DGRUTScoringConfig& scoring_cfg) {
    const float confidence = splat.tri_tet_confidence < 0.0f ? 0.0f : splat.tri_tet_confidence;
    const float opacity = splat.opacity < 0.0f ? 0.0f : splat.opacity;
    const float radius = splat.radius < 0.0f ? 0.0f : splat.radius;
    const float view_factor = splat.view_cosine > 0.0f ? splat.view_cosine : 0.0f;
    const float screen_coverage = splat.screen_coverage < 0.0f ? 0.0f : splat.screen_coverage;
    float newborn = 0.0f;
    if (scoring_cfg.newborn_frames > 0u && splat.frames_since_birth < scoring_cfg.newborn_frames) {
        const float t = static_cast<float>(splat.frames_since_birth) /
            static_cast<float>(scoring_cfg.newborn_frames);
        newborn = scoring_cfg.newborn_boost * (1.0f - t);
    }
    const float depth_penalty = splat.depth > 0.0f ? splat.depth * scoring_cfg.depth_penalty_scale : 0.0f;
    return confidence * scoring_cfg.weight_confidence +
        opacity * scoring_cfg.weight_opacity +
        radius * scoring_cfg.weight_radius -
        depth_penalty +
        view_factor * scoring_cfg.weight_view_angle +
        screen_coverage * scoring_cfg.weight_screen_coverage +
        newborn;
}

inline float clamp01(float v) {
    return std::max(0.0f, std::min(1.0f, v));
}

inline float luminance(const float color[3]) {
    return 0.2126f * color[0] + 0.7152f * color[1] + 0.0722f * color[2];
}

struct ScoredSplatIndex {
    float score{0.0f};
    std::uint32_t index{0u};
    std::uint32_t splat_id{0u};
};

inline bool better_score_then_id(const ScoredSplatIndex& lhs, const ScoredSplatIndex& rhs) {
    if (lhs.score == rhs.score) {
        return lhs.splat_id < rhs.splat_id;
    }
    return lhs.score > rhs.score;
}

aether::core::Status validate_selection_config(const aether::render::DGRUTSelectionConfig& config) {
    if (config.partial_select_keep_ratio_threshold <= 0.0f ||
        config.partial_select_keep_ratio_threshold >= 1.0f) {
        return aether::core::Status::kInvalidArgument;
    }
    if (config.scoring.weight_confidence < 0.0f ||
        config.scoring.weight_opacity < 0.0f ||
        config.scoring.weight_radius < 0.0f ||
        config.scoring.weight_view_angle < 0.0f ||
        config.scoring.weight_screen_coverage < 0.0f ||
        config.scoring.newborn_boost < 0.0f ||
        config.scoring.depth_penalty_scale < 0.0f) {
        return aether::core::Status::kInvalidArgument;
    }
    if ((config.scoring.weight_confidence +
         config.scoring.weight_opacity +
         config.scoring.weight_radius +
         config.scoring.weight_view_angle +
         config.scoring.weight_screen_coverage) <= 0.0f) {
        return aether::core::Status::kInvalidArgument;
    }
    return aether::core::Status::kOk;
}

}  // namespace

namespace aether {
namespace render {

core::Status select_dgrut_splats(
    const DGRUTSplat* input,
    std::size_t input_count,
    const DGRUTBudget& budget,
    DGRUTSplat* output,
    std::size_t output_capacity,
    DGRUTSelectionResult* result) {
    DGRUTSelectionConfig config{};
    return select_dgrut_splats_with_config(
        input,
        input_count,
        budget,
        config,
        output,
        output_capacity,
        result);
}

core::Status select_dgrut_splats_with_config(
    const DGRUTSplat* input,
    std::size_t input_count,
    const DGRUTBudget& budget,
    const DGRUTSelectionConfig& config,
    DGRUTSplat* output,
    std::size_t output_capacity,
    DGRUTSelectionResult* result) {
    if (input_count > 0 && input == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (output_capacity > 0 && output == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    const core::Status cfg_status = validate_selection_config(config);
    if (cfg_status != core::Status::kOk) {
        return cfg_status;
    }

    const std::size_t by_splats = budget.max_splats < output_capacity ? budget.max_splats : output_capacity;
    const std::size_t by_bytes = budget.max_bytes / sizeof(DGRUTSplat);
    std::size_t keep_count = input_count;
    keep_count = keep_count < by_splats ? keep_count : by_splats;
    keep_count = keep_count < by_bytes ? keep_count : by_bytes;

    result->selected_count = 0;
    result->mean_opacity = 0.0f;
    if (keep_count == 0) {
        return core::Status::kOutOfRange;
    }

    double opacity_sum = 0.0;
    std::vector<ScoredSplatIndex> scored;
    scored.reserve(input_count);
    for (std::size_t i = 0u; i < input_count; ++i) {
        ScoredSplatIndex entry{};
        entry.score = score_splat(input[i], config.scoring);
        entry.index = static_cast<std::uint32_t>(i);
        entry.splat_id = input[i].id;
        scored.push_back(entry);
    }

    // Large-N path: nth_element keeps exact top-k with lower sorting cost.
    const bool use_partial_select =
        input_count >= config.partial_select_min_input &&
        static_cast<float>(keep_count) < static_cast<float>(input_count) * config.partial_select_keep_ratio_threshold;
    if (use_partial_select) {
        auto kth = scored.begin() + static_cast<std::ptrdiff_t>(keep_count);
        std::nth_element(scored.begin(), kth, scored.end(), better_score_then_id);
        scored.resize(keep_count);
        std::sort(scored.begin(), scored.end(), better_score_then_id);
    } else {
        std::stable_sort(scored.begin(), scored.end(), better_score_then_id);
        scored.resize(keep_count);
    }

    for (std::size_t i = 0; i < keep_count; ++i) {
        const DGRUTSplat& selected = input[scored[i].index];
        output[i] = selected;
        opacity_sum += static_cast<double>(selected.opacity);
    }

    result->selected_count = keep_count;
    result->mean_opacity = static_cast<float>(opacity_sum / static_cast<double>(keep_count));
    if (result->mean_opacity < 0.0f) {
        result->mean_opacity = 0.0f;
    } else if (result->mean_opacity > 1.0f) {
        result->mean_opacity = 1.0f;
    }
    return core::Status::kOk;
}

core::Status dgrut_to_khr_gaussian_splats(
    const DGRUTSplat* input,
    std::size_t input_count,
    KHRGaussianSplat* output,
    std::size_t output_capacity) {
    if ((input_count > 0u && input == nullptr) || (output_capacity > 0u && output == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (output_capacity < input_count) {
        return core::Status::kOutOfRange;
    }

    for (std::size_t i = 0u; i < input_count; ++i) {
        const DGRUTSplat& src = input[i];
        KHRGaussianSplat dst{};
        dst.position[0] = 0.0f;
        dst.position[1] = 0.0f;
        dst.position[2] = src.depth > 0.0f ? src.depth : 0.0f;

        dst.rotation[0] = 0.0f;
        dst.rotation[1] = 0.0f;
        dst.rotation[2] = 0.0f;
        dst.rotation[3] = 1.0f;

        const float radius = src.radius > 0.0f ? src.radius : 0.0f;
        dst.scale[0] = radius;
        dst.scale[1] = radius;
        dst.scale[2] = radius;

        dst.opacity = clamp01(src.opacity);
        const float confidence = clamp01(src.tri_tet_confidence);
        const float view_factor = clamp01(src.view_cosine);
        const float coverage = clamp01(src.screen_coverage);
        dst.color[0] = confidence;
        dst.color[1] = clamp01(0.7f * confidence + 0.3f * view_factor);
        dst.color[2] = clamp01(0.7f * confidence + 0.3f * coverage);
        output[i] = dst;
    }

    return core::Status::kOk;
}

core::Status khr_to_dgrut_splats(
    const KHRGaussianSplat* input,
    const std::uint32_t* ids,
    std::size_t input_count,
    DGRUTSplat* output,
    std::size_t output_capacity) {
    if ((input_count > 0u && input == nullptr) || (output_capacity > 0u && output == nullptr)) {
        return core::Status::kInvalidArgument;
    }
    if (output_capacity < input_count) {
        return core::Status::kOutOfRange;
    }

    for (std::size_t i = 0u; i < input_count; ++i) {
        const KHRGaussianSplat& src = input[i];
        DGRUTSplat dst{};
        dst.id = (ids != nullptr) ? ids[i] : static_cast<std::uint32_t>(i);
        dst.depth = src.position[2] > 0.0f ? src.position[2] : 0.0f;
        const float sx = std::fabs(src.scale[0]);
        const float sy = std::fabs(src.scale[1]);
        const float sz = std::fabs(src.scale[2]);
        dst.radius = (sx + sy + sz) / 3.0f;
        dst.opacity = clamp01(src.opacity);
        dst.tri_tet_confidence = clamp01(luminance(src.color));
        dst.view_cosine = 1.0f;
        dst.screen_coverage = 0.0f;
        dst.frames_since_birth = 0u;
        output[i] = dst;
    }

    return core::Status::kOk;
}

core::Status select_dgrut_splats_khr(
    const KHRGaussianSplat* input,
    const std::uint32_t* ids,
    std::size_t input_count,
    const DGRUTBudget& budget,
    const DGRUTSelectionConfig& config,
    KHRGaussianSplat* output,
    std::uint32_t* out_ids,
    std::size_t output_capacity,
    DGRUTSelectionResult* result) {
    if (result == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if ((input_count > 0u && input == nullptr) ||
        (output_capacity > 0u && output == nullptr) ||
        (output_capacity > 0u && out_ids == nullptr)) {
        return core::Status::kInvalidArgument;
    }

    std::vector<DGRUTSplat> dgrut_in(input_count);
    core::Status status = khr_to_dgrut_splats(
        input,
        ids,
        input_count,
        dgrut_in.data(),
        dgrut_in.size());
    if (status != core::Status::kOk) {
        return status;
    }

    std::vector<DGRUTSplat> dgrut_out(output_capacity);
    DGRUTSelectionResult local_result{};
    status = select_dgrut_splats_with_config(
        dgrut_in.data(),
        dgrut_in.size(),
        budget,
        config,
        dgrut_out.data(),
        dgrut_out.size(),
        &local_result);
    if (status != core::Status::kOk) {
        *result = local_result;
        return status;
    }

    status = dgrut_to_khr_gaussian_splats(
        dgrut_out.data(),
        local_result.selected_count,
        output,
        output_capacity);
    if (status != core::Status::kOk) {
        *result = local_result;
        return status;
    }

    for (std::size_t i = 0u; i < local_result.selected_count; ++i) {
        out_ids[i] = dgrut_out[i].id;
    }
    *result = local_result;
    return core::Status::kOk;
}

}  // namespace render
}  // namespace aether
