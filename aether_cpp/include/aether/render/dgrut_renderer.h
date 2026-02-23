// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_RENDER_DGRUT_RENDERER_H
#define AETHER_CPP_RENDER_DGRUT_RENDERER_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>
#include <type_traits>

#include "aether/core/status.h"

namespace aether {
namespace render {

struct DGRUTSplat {
    std::uint32_t id;
    float depth;
    float opacity;
    float radius;
    float tri_tet_confidence;
    float view_cosine{1.0f};
    float screen_coverage{0.0f};
    std::uint32_t frames_since_birth{0u};
};

// KHR_gaussian_splatting forward-compatible transport payload.
// Field names intentionally match canonical KHR naming.
struct KHRGaussianSplat {
    float position[3];
    float rotation[4];
    float scale[3];
    float opacity;
    float color[3];
};

static_assert(std::is_standard_layout<KHRGaussianSplat>::value, "KHRGaussianSplat must be standard layout");

struct DGRUTBudget {
    std::size_t max_splats;
    std::size_t max_bytes;
};

struct DGRUTSelectionResult {
    std::size_t selected_count;
    float mean_opacity;
};

struct DGRUTScoringConfig {
    float weight_confidence{0.50f};
    float weight_opacity{0.20f};
    float weight_radius{0.10f};
    float weight_view_angle{0.10f};
    float weight_screen_coverage{0.08f};
    float newborn_boost{0.15f};
    std::uint32_t newborn_frames{30u};
    float depth_penalty_scale{8e-4f};
};

struct DGRUTSelectionConfig {
    DGRUTScoringConfig scoring{};
    std::size_t partial_select_min_input{1024u};
    float partial_select_keep_ratio_threshold{0.25f};
};

core::Status select_dgrut_splats(
    const DGRUTSplat* input,
    std::size_t input_count,
    const DGRUTBudget& budget,
    DGRUTSplat* output,
    std::size_t output_capacity,
    DGRUTSelectionResult* result);

core::Status select_dgrut_splats_with_config(
    const DGRUTSplat* input,
    std::size_t input_count,
    const DGRUTBudget& budget,
    const DGRUTSelectionConfig& config,
    DGRUTSplat* output,
    std::size_t output_capacity,
    DGRUTSelectionResult* result);

core::Status dgrut_to_khr_gaussian_splats(
    const DGRUTSplat* input,
    std::size_t input_count,
    KHRGaussianSplat* output,
    std::size_t output_capacity);

core::Status khr_to_dgrut_splats(
    const KHRGaussianSplat* input,
    const std::uint32_t* ids,
    std::size_t input_count,
    DGRUTSplat* output,
    std::size_t output_capacity);

core::Status select_dgrut_splats_khr(
    const KHRGaussianSplat* input,
    const std::uint32_t* ids,
    std::size_t input_count,
    const DGRUTBudget& budget,
    const DGRUTSelectionConfig& config,
    KHRGaussianSplat* output,
    std::uint32_t* out_ids,
    std::size_t output_capacity,
    DGRUTSelectionResult* result);

}  // namespace render
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_RENDER_DGRUT_RENDERER_H
