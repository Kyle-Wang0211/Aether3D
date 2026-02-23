// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_SOFT_EVICTION_H
#define AETHER_TSDF_SOFT_EVICTION_H

#include "aether/tsdf/tsdf_constants.h"
#include "aether/tsdf/voxel_block.h"
#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

struct SoftEvictionConfig {
    double stale_age_s{STALE_BLOCK_EVICTION_AGE_S};
    float weight_decay_per_frame{0.03f};
    std::uint8_t min_weight_before_fade{2u};
    int fade_out_frames{MESH_FADE_IN_FRAMES};
};

void apply_soft_eviction(
    VoxelBlock* blocks,
    BlockMeshState* states,
    std::size_t count,
    double current_time_s,
    std::uint64_t current_frame,
    const SoftEvictionConfig& config = SoftEvictionConfig{});

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_SOFT_EVICTION_H
