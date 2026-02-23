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

    void clear(float voxel_size_in = VOXEL_SIZE_MID) {
        for (int i = 0; i < kVoxelCount; ++i) {
            voxels[i] = Voxel::empty();
        }
        integration_generation = 0;
        mesh_generation = 0;
        last_observed_timestamp = 0.0;
        voxel_size = voxel_size_in;
    }
};

struct BlockMeshState {
    float opacity_progress{0.0f};
    std::uint32_t first_mesh_frame{0};
    bool is_stable{false};
    float fade_out_progress{1.0f};
};

inline VoxelBlock make_empty_block(float voxel_size = VOXEL_SIZE_MID) {
    VoxelBlock block;
    block.clear(voxel_size);
    return block;
}

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_VOXEL_BLOCK_H
