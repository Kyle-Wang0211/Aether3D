// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MANAGED_VOXEL_STORAGE_H
#define AETHER_TSDF_MANAGED_VOXEL_STORAGE_H

#include "aether/tsdf/voxel_block.h"
#include <cstddef>
#include <new>

namespace aether {
namespace tsdf {

class ManagedVoxelStorage {
public:
    ManagedVoxelStorage() = default;
    explicit ManagedVoxelStorage(int capacity) { init(capacity); }

    ~ManagedVoxelStorage() { reset(); }
    ManagedVoxelStorage(const ManagedVoxelStorage&) = delete;
    ManagedVoxelStorage& operator=(const ManagedVoxelStorage&) = delete;

    void init(int capacity) {
        reset();
        if (capacity <= 0) return;
        capacity_ = capacity;
        blocks_ = new (std::nothrow) VoxelBlock[static_cast<size_t>(capacity_)];
        if (!blocks_) {
            capacity_ = 0;
            return;
        }
        for (int i = 0; i < capacity_; ++i) {
            blocks_[static_cast<size_t>(i)].clear();
        }
    }

    void reset() {
        delete[] blocks_;
        blocks_ = nullptr;
        capacity_ = 0;
    }

    int capacity() const { return capacity_; }

    // L10 FIX: Bounds-checked access prevents undefined behavior from
    // negative indices or indices >= capacity (which wrap to huge size_t values).
    VoxelBlock& at(int index) {
        if (index >= 0 && index < capacity_ && blocks_) {
            return blocks_[static_cast<size_t>(index)];
        }
        static VoxelBlock sentinel{};
        sentinel.clear();
        return sentinel;
    }
    const VoxelBlock& at(int index) const {
        if (index >= 0 && index < capacity_ && blocks_) {
            return blocks_[static_cast<size_t>(index)];
        }
        static const VoxelBlock sentinel{};
        return sentinel;
    }

    VoxelBlock* data() { return blocks_; }
    const VoxelBlock* data() const { return blocks_; }

private:
    VoxelBlock* blocks_{nullptr};
    int capacity_{0};
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MANAGED_VOXEL_STORAGE_H
