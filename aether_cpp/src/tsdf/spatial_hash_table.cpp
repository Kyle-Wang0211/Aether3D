// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/spatial_hash_table.h"
#include <cstdlib>
#include <cstring>

namespace aether {
namespace tsdf {

namespace {

inline int round_up_pow2(int value) {
    int v = (value <= 1) ? 1 : value;
    --v;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    ++v;
    return v;
}

inline int probe_index(int start, int probe, int capacity) {
    return (start + probe) & (capacity - 1);
}

}  // namespace

void SpatialHashTable::init(int table_size, int stable_key_capacity) {
    reset();
    capacity_ = round_up_pow2(table_size > 0 ? table_size : HASH_TABLE_INITIAL_SIZE);
    entries_ = static_cast<Entry*>(std::malloc(static_cast<size_t>(capacity_) * sizeof(Entry)));
    occupied_ = static_cast<uint8_t*>(std::calloc(static_cast<size_t>(capacity_), sizeof(uint8_t)));
    stable_key_capacity_ = stable_key_capacity > 0 ? stable_key_capacity : MAX_TOTAL_VOXEL_BLOCKS;
    stable_keys_ = static_cast<BlockIndex*>(std::malloc(static_cast<size_t>(stable_key_capacity_) * sizeof(BlockIndex)));
    if (!entries_ || !occupied_ || !stable_keys_) {
        std::free(entries_);
        std::free(occupied_);
        std::free(stable_keys_);
        entries_ = nullptr;
        occupied_ = nullptr;
        stable_keys_ = nullptr;
        capacity_ = 0;
        stable_key_capacity_ = 0;
        stable_key_count_ = 0;
        size_ = 0;
        return;
    }
    stable_key_count_ = 0;
    size_ = 0;
    for (int i = 0; i < capacity_; ++i) {
        entries_[static_cast<size_t>(i)] = Entry{};
    }
}

int SpatialHashTable::find_slot(const BlockIndex& bi) const {
    if (!entries_ || !occupied_ || capacity_ <= 0) return -1;
    const int start = bi.niessner_hash(capacity_);
    const int max_probe = capacity_ < HASH_MAX_PROBE_LENGTH ? capacity_ : HASH_MAX_PROBE_LENGTH;
    for (int probe = 0; probe < max_probe; ++probe) {
        const int idx = probe_index(start, probe, capacity_);
        if (!occupied_[static_cast<size_t>(idx)]) return -1;
        if (entries_[static_cast<size_t>(idx)].key == bi) return idx;
    }
    return -1;
}

int SpatialHashTable::find_insert_slot(const BlockIndex& bi) const {
    if (!entries_ || !occupied_ || capacity_ <= 0) return -1;
    const int start = bi.niessner_hash(capacity_);
    const int max_probe = capacity_ < HASH_MAX_PROBE_LENGTH ? capacity_ : HASH_MAX_PROBE_LENGTH;
    for (int probe = 0; probe < max_probe; ++probe) {
        const int idx = probe_index(start, probe, capacity_);
        if (!occupied_[static_cast<size_t>(idx)] ||
            entries_[static_cast<size_t>(idx)].key == bi) {
            return idx;
        }
    }
    return -1;
}

int SpatialHashTable::find(const BlockIndex& bi) const {
    return find_slot(bi);
}

void SpatialHashTable::append_stable_key(const BlockIndex& bi) {
    if (stable_key_count_ < stable_key_capacity_) {
        stable_keys_[static_cast<size_t>(stable_key_count_++)] = bi;
        return;
    }
    const int new_capacity = stable_key_capacity_ > 0 ? stable_key_capacity_ * 2 : 64;
    BlockIndex* grown = static_cast<BlockIndex*>(
        std::realloc(stable_keys_, static_cast<size_t>(new_capacity) * sizeof(BlockIndex)));
    if (!grown) return;
    stable_keys_ = grown;
    stable_key_capacity_ = new_capacity;
    stable_keys_[static_cast<size_t>(stable_key_count_++)] = bi;
}

void SpatialHashTable::erase_stable_key(const BlockIndex& bi) {
    for (int i = 0; i < stable_key_count_; ++i) {
        if (stable_keys_[static_cast<size_t>(i)] == bi) {
            stable_keys_[static_cast<size_t>(i)] = stable_keys_[static_cast<size_t>(stable_key_count_ - 1)];
            --stable_key_count_;
            return;
        }
    }
}

float SpatialHashTable::load_factor() const {
    if (capacity_ <= 0) return 0.0f;
    return static_cast<float>(size_) / static_cast<float>(capacity_);
}

void SpatialHashTable::rehash_to(int new_capacity) {
    new_capacity = round_up_pow2(new_capacity);
    if (new_capacity <= capacity_ || size_ == 0) return;
    Entry* new_entries = static_cast<Entry*>(std::malloc(static_cast<size_t>(new_capacity) * sizeof(Entry)));
    uint8_t* new_occupied = static_cast<uint8_t*>(std::calloc(static_cast<size_t>(new_capacity), sizeof(uint8_t)));
    if (!new_entries || !new_occupied) {
        std::free(new_entries);
        std::free(new_occupied);
        return;
    }
    for (int i = 0; i < new_capacity; ++i) {
        new_entries[static_cast<size_t>(i)] = Entry{};
    }
    for (int i = 0; i < capacity_; ++i) {
        if (!occupied_[static_cast<size_t>(i)]) continue;
        const Entry entry = entries_[static_cast<size_t>(i)];
        const int start = entry.key.niessner_hash(new_capacity);
        const int max_probe = new_capacity < HASH_MAX_PROBE_LENGTH ? new_capacity : HASH_MAX_PROBE_LENGTH;
        for (int probe = 0; probe < max_probe; ++probe) {
            const int idx = probe_index(start, probe, new_capacity);
            if (!new_occupied[static_cast<size_t>(idx)]) {
                new_entries[static_cast<size_t>(idx)] = entry;
                new_occupied[static_cast<size_t>(idx)] = 1;
                break;
            }
        }
    }
    std::free(entries_);
    std::free(occupied_);
    entries_ = new_entries;
    occupied_ = new_occupied;
    capacity_ = new_capacity;
}

void SpatialHashTable::rehash_if_needed() {
    if (capacity_ <= 0) return;
    if (load_factor() >= HASH_TABLE_MAX_LOAD_FACTOR) {
        rehash_to(capacity_ * 2);
    }
}

int SpatialHashTable::insert_or_get(const BlockIndex& bi, int value) {
    if (!entries_ || !occupied_ || capacity_ <= 0) return -1;
    rehash_if_needed();
    const int start = bi.niessner_hash(capacity_);
    const int max_probe = capacity_ < HASH_MAX_PROBE_LENGTH ? capacity_ : HASH_MAX_PROBE_LENGTH;
    for (int probe = 0; probe < max_probe; ++probe) {
        const int idx = probe_index(start, probe, capacity_);
        if (!occupied_[static_cast<size_t>(idx)]) {
            entries_[static_cast<size_t>(idx)].key = bi;
            entries_[static_cast<size_t>(idx)].value = value;
            occupied_[static_cast<size_t>(idx)] = 1;
            ++size_;
            append_stable_key(bi);
            return value;
        }
        if (entries_[static_cast<size_t>(idx)].key == bi) {
            return entries_[static_cast<size_t>(idx)].value;
        }
    }
    return -1;
}

int SpatialHashTable::lookup(const BlockIndex& bi) const {
    const int slot = find_slot(bi);
    if (slot < 0) return -1;
    return entries_[static_cast<size_t>(slot)].value;
}

int SpatialHashTable::insert(const BlockIndex& bi) {
    if (!entries_ || !occupied_ || capacity_ <= 0) return -1;
    rehash_if_needed();
    const int start = bi.niessner_hash(capacity_);
    const int max_probe = capacity_ < HASH_MAX_PROBE_LENGTH ? capacity_ : HASH_MAX_PROBE_LENGTH;
    for (int probe = 0; probe < max_probe; ++probe) {
        const int idx = probe_index(start, probe, capacity_);
        if (!occupied_[static_cast<size_t>(idx)]) {
            entries_[static_cast<size_t>(idx)].key = bi;
            entries_[static_cast<size_t>(idx)].value = idx;
            occupied_[static_cast<size_t>(idx)] = 1;
            ++size_;
            append_stable_key(bi);
            return idx;
        }
        if (entries_[static_cast<size_t>(idx)].key == bi) {
            return idx;
        }
    }
    return -1;
}

bool SpatialHashTable::remove(const BlockIndex& bi) {
    if (!entries_ || !occupied_ || capacity_ <= 0) return false;
    int empty = find_slot(bi);
    if (empty < 0) return false;

    erase_stable_key(bi);

    int cursor = probe_index(empty, 1, capacity_);
    while (occupied_[static_cast<size_t>(cursor)]) {
        const int ideal = entries_[static_cast<size_t>(cursor)].key.niessner_hash(capacity_);
        const bool move =
            (cursor > empty)
                ? (ideal <= empty || ideal > cursor)
                : (ideal <= empty && ideal > cursor);
        if (move) {
            entries_[static_cast<size_t>(empty)] = entries_[static_cast<size_t>(cursor)];
            occupied_[static_cast<size_t>(empty)] = 1;
            empty = cursor;
        }
        cursor = probe_index(cursor, 1, capacity_);
    }

    entries_[static_cast<size_t>(empty)] = Entry{};
    occupied_[static_cast<size_t>(empty)] = 0;
    --size_;
    return true;
}

void SpatialHashTable::reset() {
    std::free(entries_);
    std::free(occupied_);
    std::free(stable_keys_);
    entries_ = nullptr;
    occupied_ = nullptr;
    stable_keys_ = nullptr;
    stable_key_capacity_ = 0;
    stable_key_count_ = 0;
    capacity_ = 0;
    size_ = 0;
}

}  // namespace tsdf
}  // namespace aether
