// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_INTEGRATION_BACKEND_H
#define AETHER_TSDF_INTEGRATION_BACKEND_H

#include "aether/tsdf/block_index.h"
#include "aether/tsdf/tsdf_types.h"
#include "aether/tsdf/voxel_block.h"

namespace aether {
namespace tsdf {

class VoxelBlockAccessor {
public:
    virtual ~VoxelBlockAccessor() = default;
    virtual VoxelBlock read_block(int pool_index) const = 0;
    virtual void write_block(int pool_index, const VoxelBlock& block) = 0;
    virtual int capacity() const = 0;
};

class DepthDataProvider {
public:
    virtual ~DepthDataProvider() = default;
    virtual int width() const = 0;
    virtual int height() const = 0;
    virtual float depth_at(int x, int y) const = 0;
    virtual uint8_t confidence_at(int x, int y) const = 0;
};

class IntegrationBackend {
public:
    virtual ~IntegrationBackend() = default;
    virtual IntegrationStats process_frame(
        const IntegrationInput& input,
        const DepthDataProvider& depth_data,
        VoxelBlockAccessor& volume,
        const BlockIndex* active_blocks,
        const int* pool_indices,
        int block_count) = 0;
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_INTEGRATION_BACKEND_H
