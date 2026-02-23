// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_INNOVATION_F1_PROGRESSIVE_COMPRESSION_H
#define AETHER_INNOVATION_F1_PROGRESSIVE_COMPRESSION_H

#ifdef __cplusplus

#include "aether/core/status.h"
#include "aether/innovation/core_types.h"
#include "aether/innovation/scaffold_patch_map.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace innovation {

struct ProgressiveCompressionConfig {
    std::uint32_t level_count{3};
    float area_gamma{1.0f};
    bool capture_order_priority{true};
    std::uint32_t quant_bits_position{16};
    std::uint32_t quant_bits_scale{16};
    std::uint32_t quant_bits_opacity{8};
    std::uint32_t quant_bits_uncertainty{12};
    std::uint32_t quant_bits_sh{8};
    std::uint32_t sh_coeff_count{8};
};

struct LODLevel {
    std::uint32_t level_index{0};
    float min_unit_area{0.0f};
    float max_unit_area{0.0f};
    std::vector<std::uint32_t> gaussian_indices{};
    std::size_t estimated_bytes{0};
};

struct ProgressiveHierarchy {
    std::vector<LODLevel> levels{};
    Aabb scene_bounds{};
    std::size_t estimated_bytes_per_gaussian{0};
};

struct ProgressiveEncodedLevel {
    std::uint32_t level_index{0};
    std::uint32_t gaussian_count{0};
    std::uint32_t sh_coeff_count{0};
    std::vector<std::uint8_t> bytes{};
};

struct F1RenderQueueEntry {
    std::uint32_t gaussian_index{0};
    GaussianId gaussian_id{0};
    ScaffoldUnitId host_unit_id{0};
    std::string patch_id{};
    std::uint32_t capture_sequence{0};
    std::uint16_t patch_priority{0};
    std::uint64_t first_observed_frame_id{0};
    std::int64_t first_observed_ms{0};
    std::uint32_t lod_level{0};
};

core::Status f1_build_progressive_hierarchy(
    const ScaffoldUnit* units,
    std::size_t unit_count,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const ScaffoldPatchMap* patch_map,
    const ProgressiveCompressionConfig& config,
    ProgressiveHierarchy* out_hierarchy);

core::Status f1_select_level_for_budget(
    const ProgressiveHierarchy& hierarchy,
    std::size_t byte_budget,
    std::uint32_t* out_level_index);

core::Status f1_encode_level(
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    const ProgressiveHierarchy& hierarchy,
    std::uint32_t level_index,
    const ProgressiveCompressionConfig& config,
    ProgressiveEncodedLevel* out_encoded);

core::Status f1_decode_level(
    const ProgressiveEncodedLevel& encoded,
    std::vector<GaussianPrimitive>* out_gaussians);

core::Status f1_build_capture_order_queue(
    const ProgressiveHierarchy& hierarchy,
    const GaussianPrimitive* gaussians,
    std::size_t gaussian_count,
    std::uint32_t level_index,
    std::vector<F1RenderQueueEntry>* out_queue,
    const ScaffoldPatchMap* patch_map = nullptr);

}  // namespace innovation
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_INNOVATION_F1_PROGRESSIVE_COMPRESSION_H
