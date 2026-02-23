// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_VOXEL_BLOCK_POOL_H
#define AETHER_TSDF_VOXEL_BLOCK_POOL_H

#include "aether/tsdf/managed_voxel_storage.h"
#include "aether/tsdf/tsdf_constants.h"
#include <cstddef>
#include <new>

namespace aether {
namespace tsdf {

class VoxelBlockPool {
public:
    VoxelBlockPool() = default;
    explicit VoxelBlockPool(int capacity) { init(capacity); }

    ~VoxelBlockPool() { reset(); }
    VoxelBlockPool(const VoxelBlockPool&) = delete;
    VoxelBlockPool& operator=(const VoxelBlockPool&) = delete;

    void init(int capacity = MAX_TOTAL_VOXEL_BLOCKS) {
        reset();
        if (capacity <= 0) return;
        storage_.init(capacity);
        free_stack_ = new (std::nothrow) int[static_cast<size_t>(capacity)];
        if (!free_stack_) {
            storage_.reset();
            return;
        }
        capacity_ = capacity;
        free_top_ = capacity_;
        allocated_count_ = 0;
        for (int i = 0; i < capacity_; ++i) {
            free_stack_[static_cast<size_t>(i)] = capacity_ - 1 - i;
        }
    }

    void reset() {
        delete[] free_stack_;
        free_stack_ = nullptr;
        free_top_ = 0;
        capacity_ = 0;
        allocated_count_ = 0;
        storage_.reset();
    }

    int allocate(float voxel_size) {
        if (!free_stack_ || free_top_ <= 0) return -1;
        const int idx = free_stack_[static_cast<size_t>(--free_top_)];
        storage_.at(idx).clear(voxel_size);
        ++allocated_count_;
        return idx;
    }

    void deallocate(int index) {
        if (!free_stack_ || index < 0 || index >= capacity_) return;
        // M5 FIX: Guard against double-free. Scan the free stack to check if
        // this index is already present. A double-free would corrupt the stack
        // with duplicate entries, causing the same block to be allocated twice.
        for (int i = 0; i < free_top_; ++i) {
            if (free_stack_[static_cast<size_t>(i)] == index) {
                return;  // Already free — skip double-free
            }
        }
        storage_.at(index).clear();
        free_stack_[static_cast<size_t>(free_top_++)] = index;
        if (allocated_count_ > 0) --allocated_count_;
    }

    int capacity() const { return capacity_; }
    int allocated_count() const { return allocated_count_; }
    bool empty() const { return allocated_count_ == 0; }

    ManagedVoxelStorage& storage() { return storage_; }
    const ManagedVoxelStorage& storage() const { return storage_; }

private:
    ManagedVoxelStorage storage_{};
    int* free_stack_{nullptr};
    int free_top_{0};
    int capacity_{0};
    int allocated_count_{0};
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_VOXEL_BLOCK_POOL_H
