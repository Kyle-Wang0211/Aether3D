// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MANAGED_STORAGE_H
#define AETHER_TSDF_MANAGED_STORAGE_H

#include "aether/tsdf/managed_voxel_storage.h"

namespace aether {
namespace tsdf {

class ManagedStorage {
public:
    void init(int max_blocks) {
        storage_.init(max_blocks);
        next_index_ = 0;
    }

    VoxelBlock* get_or_create(const BlockIndex&) {
        if (next_index_ >= storage_.capacity()) return nullptr;
        return &storage_.at(next_index_++);
    }

    void reset() {
        storage_.reset();
        next_index_ = 0;
    }

    ManagedVoxelStorage& storage() { return storage_; }
    const ManagedVoxelStorage& storage() const { return storage_; }

private:
    ManagedVoxelStorage storage_{};
    int next_index_{0};
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MANAGED_STORAGE_H
