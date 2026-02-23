// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_SPATIAL_HASH_TABLE_H
#define AETHER_TSDF_SPATIAL_HASH_TABLE_H

#include "aether/tsdf/block_index.h"
#include "aether/tsdf/tsdf_constants.h"
#include <cstdint>

namespace aether {
namespace tsdf {

class SpatialHashTable {
public:
    SpatialHashTable() = default;
    ~SpatialHashTable() { reset(); }
    SpatialHashTable(const SpatialHashTable&) = delete;
    SpatialHashTable& operator=(const SpatialHashTable&) = delete;

    void init(
        int table_size = HASH_TABLE_INITIAL_SIZE,
        int stable_key_capacity = MAX_TOTAL_VOXEL_BLOCKS);

    int find(const BlockIndex& bi) const;
    int insert(const BlockIndex& bi);
    int lookup(const BlockIndex& bi) const;
    int insert_or_get(const BlockIndex& bi, int value);
    bool remove(const BlockIndex& bi);
    void rehash_if_needed();
    void reset();

    int capacity() const { return capacity_; }
    int size() const { return size_; }
    float load_factor() const;

    int stable_key_count() const { return stable_key_count_; }
    const BlockIndex* stable_keys() const { return stable_keys_; }

private:
    struct Entry {
        BlockIndex key{};
        int value{-1};
    };

    Entry* entries_{nullptr};
    uint8_t* occupied_{nullptr};
    BlockIndex* stable_keys_{nullptr};
    int stable_key_count_{0};
    int stable_key_capacity_{0};
    int capacity_{0};
    int size_{0};

    int find_slot(const BlockIndex& bi) const;
    int find_insert_slot(const BlockIndex& bi) const;
    void append_stable_key(const BlockIndex& bi);
    void erase_stable_key(const BlockIndex& bi);
    void rehash_to(int new_capacity);
};

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_SPATIAL_HASH_TABLE_H
