// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/soft_eviction.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace aether {
namespace tsdf {

void apply_soft_eviction(
    VoxelBlock* blocks,
    BlockMeshState* states,
    std::size_t count,
    double current_time_s,
    std::uint64_t,
    const SoftEvictionConfig& config) {
    if (blocks == nullptr || states == nullptr || count == 0u) {
        return;
    }
    if (!(config.stale_age_s >= 0.0) || config.weight_decay_per_frame < 0.0f || config.fade_out_frames <= 0) {
        return;
    }

    const float decay = std::max(0.0f, std::min(1.0f, config.weight_decay_per_frame));
    const float keep = 1.0f - decay;
    const std::uint16_t keep_fixed = static_cast<std::uint16_t>(std::lround(std::max(0.0f, std::min(1.0f, keep)) * 256.0f));

    for (std::size_t i = 0u; i < count; ++i) {
        VoxelBlock& block = blocks[i];
        BlockMeshState& state = states[i];
        const double age = current_time_s - block.last_observed_timestamp;
        if (age <= config.stale_age_s) {
            continue;
        }

        std::uint8_t max_weight = 0u;
        for (int v = 0; v < VoxelBlock::kVoxelCount; ++v) {
            const std::uint16_t w = block.voxels[v].weight;
            const std::uint8_t decayed = static_cast<std::uint8_t>((w * keep_fixed) >> 8u);
            block.voxels[v].weight = decayed;
            max_weight = std::max(max_weight, decayed);
        }

        if (max_weight < config.min_weight_before_fade) {
            const float step = 1.0f / static_cast<float>(config.fade_out_frames);
            state.fade_out_progress = std::max(0.0f, state.fade_out_progress - step);
            state.opacity_progress = std::min(state.opacity_progress, state.fade_out_progress);
            if (state.fade_out_progress <= 0.0f) {
                // Preserve ghost state: capture high-water marks before clearing.
                // These survive eviction so the display layer can resume from
                // the previously achieved visual level when re-observed, instead
                // of regressing to black.
                const float saved_display_hw = state.display_high_water;
                const float saved_evidence_hw = state.evidence_high_water;
                const std::uint32_t saved_peak_obs = state.peak_observation_count;

                block.clear(block.voxel_size);

                state = BlockMeshState{};
                state.display_high_water = saved_display_hw;
                state.evidence_high_water = saved_evidence_hw;
                state.peak_observation_count = saved_peak_obs;
                state.has_ghost = (saved_display_hw > 0.0f);
            }
        }
    }
}

}  // namespace tsdf
}  // namespace aether
