// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_VOXEL_BLOCK_H
#define AETHER_TSDF_VOXEL_BLOCK_H

#include "aether/tsdf/sdf_storage.h"
#include "aether/tsdf/tsdf_constants.h"
#include <cstdint>

namespace aether {
namespace tsdf {

struct Voxel {
    SDFStorage sdf{};
    uint8_t weight{0};
    uint8_t confidence{0};

    static Voxel empty() { return Voxel{}; }
};

static_assert(sizeof(Voxel) == 4, "Voxel layout must remain compact");

struct VoxelBlock {
    static constexpr int kSize = BLOCK_SIZE;
    static constexpr int kVoxelCount = kSize * kSize * kSize;

    Voxel voxels[kVoxelCount]{};
    uint32_t integration_generation{0};
    uint32_t mesh_generation{0};
    double last_observed_timestamp{0.0};
    float voxel_size{VOXEL_SIZE_MID};
    uint16_t training_obs_count{0};       // How many selected training frames cover this block

    // ── Angular Diversity Tracking (24θ × 12φ directional bitmask) ──
    // Each bit = one directional bucket that has been observed.
    // Used to compute angular diversity quality score per block.
    // theta: 24 buckets (15° each, horizontal, 0-360°). Bit i = seen from θ∈[i*15°, (i+1)*15°).
    // phi:   12 buckets (15° each, vertical, -90°→+90°). Bit j = seen from φ∈[-90+j*15°, -90+(j+1)*15°).
    // Total: 6 bytes. O(1) insert (bit-OR), O(1) diversity query (popcount + span).
    std::uint32_t view_theta_bits{0};    // 24 horizontal direction buckets (bits 0-23)
    std::uint16_t view_phi_bits{0};      // 12 vertical direction buckets (bits 0-11)

    void clear(float voxel_size_in = VOXEL_SIZE_MID) {
        for (int i = 0; i < kVoxelCount; ++i) {
            voxels[i] = Voxel::empty();
        }
        integration_generation = 0;
        mesh_generation = 0;
        last_observed_timestamp = 0.0;
        voxel_size = voxel_size_in;
        training_obs_count = 0;
        view_theta_bits = 0;
        view_phi_bits = 0;
    }
};

struct BlockMeshState {
    float opacity_progress{0.0f};
    std::uint32_t first_mesh_frame{0};
    bool is_stable{false};
    float fade_out_progress{1.0f};

    // Ghost state: survives soft eviction to prevent visual regression.
    // Once a block achieves a display level, it never visually regresses
    // below this floor even after memory eviction and re-observation.
    float display_high_water{0.0f};       // max(display) ever achieved
    float evidence_high_water{0.0f};      // max(evidence) ever achieved
    std::uint32_t peak_observation_count{0};  // max observations ever seen
    bool has_ghost{false};                // true after first eviction with state
};

inline VoxelBlock make_empty_block(float voxel_size = VOXEL_SIZE_MID) {
    VoxelBlock block;
    block.clear(voxel_size);
    return block;
}

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_VOXEL_BLOCK_H
