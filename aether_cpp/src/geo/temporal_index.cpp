// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/temporal_index.h"
#include "aether/geo/geo_constants.h"

#include <cstdlib>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Internal structures
// ---------------------------------------------------------------------------

struct TemporalIndex {
    // WAL (Write-Ahead Log): unsorted recent entries
    TemporalEntry* wal;
    size_t wal_count;
    size_t wal_capacity;

    // Sorted store: compacted entries sorted by (spatial_cell, temporal_bucket)
    TemporalEntry* store;
    size_t store_count;
    size_t store_capacity;
};

namespace {

// Comparison function for sorting entries
bool entry_less(const TemporalEntry& a, const TemporalEntry& b) {
    if (a.spatial_cell != b.spatial_cell) return a.spatial_cell < b.spatial_cell;
    if (a.temporal_bucket != b.temporal_bucket) return a.temporal_bucket < b.temporal_bucket;
    return a.timestamp_s < b.timestamp_s;
}

// Insertion sort for small arrays, merge sort concept for compaction
void sort_entries(TemporalEntry* arr, size_t count) {
    // Simple insertion sort (sufficient for WAL sizes up to ~4096)
    for (size_t i = 1; i < count; ++i) {
        TemporalEntry key = arr[i];
        size_t j = i;
        while (j > 0 && entry_less(key, arr[j - 1])) {
            arr[j] = arr[j - 1];
            --j;
        }
        arr[j] = key;
    }
}

// Merge two sorted arrays into dst
void merge_sorted(const TemporalEntry* a, size_t na,
                  const TemporalEntry* b, size_t nb,
                  TemporalEntry* dst) {
    size_t ia = 0, ib = 0, id = 0;
    while (ia < na && ib < nb) {
        if (entry_less(a[ia], b[ib])) {
            dst[id++] = a[ia++];
        } else {
            dst[id++] = b[ib++];
        }
    }
    while (ia < na) dst[id++] = a[ia++];
    while (ib < nb) dst[id++] = b[ib++];
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// Create / Destroy
// ---------------------------------------------------------------------------

TemporalIndex* temporal_index_create(size_t wal_capacity) {
    if (wal_capacity == 0) wal_capacity = TEMPORAL_WAL_CAPACITY;

    auto* idx = static_cast<TemporalIndex*>(std::calloc(1, sizeof(TemporalIndex)));
    if (!idx) return nullptr;

    idx->wal = static_cast<TemporalEntry*>(std::calloc(wal_capacity, sizeof(TemporalEntry)));
    if (!idx->wal) {
        std::free(idx);
        return nullptr;
    }
    idx->wal_count = 0;
    idx->wal_capacity = wal_capacity;

    idx->store = nullptr;
    idx->store_count = 0;
    idx->store_capacity = 0;

    return idx;
}

void temporal_index_destroy(TemporalIndex* index) {
    if (!index) return;
    std::free(index->wal);
    std::free(index->store);
    std::free(index);
}

// ---------------------------------------------------------------------------
// Insert into WAL
// ---------------------------------------------------------------------------

core::Status temporal_index_insert(TemporalIndex* index,
                                   const TemporalEntry& entry) {
    if (!index) return core::Status::kInvalidArgument;

    // Auto-compact if WAL is full
    if (index->wal_count >= index->wal_capacity) {
        core::Status cs = temporal_index_compact(index);
        if (cs != core::Status::kOk) return cs;
    }

    if (index->wal_count >= index->wal_capacity) {
        return core::Status::kResourceExhausted;
    }

    index->wal[index->wal_count++] = entry;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Range query: search both WAL and sorted store
// ---------------------------------------------------------------------------

core::Status temporal_index_query(const TemporalIndex* index,
                                  uint64_t spatial_cell,
                                  uint32_t bucket_start, uint32_t bucket_end,
                                  TemporalEntry* out, size_t max,
                                  size_t* out_count) {
    if (!index || !out_count) return core::Status::kInvalidArgument;
    *out_count = 0;
    if (!out && max > 0) return core::Status::kInvalidArgument;

    size_t count = 0;

    // Search sorted store using binary search for start position
    if (index->store && index->store_count > 0) {
        // Find first entry with matching spatial_cell
        // Binary search for spatial_cell
        size_t lo = 0, hi = index->store_count;
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (index->store[mid].spatial_cell < spatial_cell) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        // Scan forward through matching spatial_cell entries
        for (size_t i = lo; i < index->store_count && count < max; ++i) {
            const TemporalEntry& e = index->store[i];
            if (e.spatial_cell != spatial_cell) break;
            if (e.temporal_bucket >= bucket_start && e.temporal_bucket <= bucket_end) {
                out[count++] = e;
            }
        }
    }

    // Linear scan WAL (unsorted, typically small)
    for (size_t i = 0; i < index->wal_count && count < max; ++i) {
        const TemporalEntry& e = index->wal[i];
        if (e.spatial_cell == spatial_cell &&
            e.temporal_bucket >= bucket_start &&
            e.temporal_bucket <= bucket_end) {
            out[count++] = e;
        }
    }

    *out_count = count;
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Compact: sort WAL, merge into sorted store
// ---------------------------------------------------------------------------

core::Status temporal_index_compact(TemporalIndex* index) {
    if (!index) return core::Status::kInvalidArgument;
    if (index->wal_count == 0) return core::Status::kOk;

    // Sort WAL
    sort_entries(index->wal, index->wal_count);

    // Allocate merged buffer
    size_t new_count = index->store_count + index->wal_count;
    auto* merged = static_cast<TemporalEntry*>(
        std::calloc(new_count, sizeof(TemporalEntry)));
    if (!merged) return core::Status::kResourceExhausted;

    // Merge sorted store + sorted WAL
    if (index->store && index->store_count > 0) {
        merge_sorted(index->store, index->store_count,
                     index->wal, index->wal_count,
                     merged);
    } else {
        std::memcpy(merged, index->wal, index->wal_count * sizeof(TemporalEntry));
    }

    // Replace store
    std::free(index->store);
    index->store = merged;
    index->store_count = new_count;
    index->store_capacity = new_count;

    // Clear WAL
    index->wal_count = 0;

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Size queries
// ---------------------------------------------------------------------------

size_t temporal_index_size(const TemporalIndex* index) {
    if (!index) return 0;
    return index->store_count + index->wal_count;
}

size_t temporal_index_wal_size(const TemporalIndex* index) {
    if (!index) return 0;
    return index->wal_count;
}

}  // namespace geo
}  // namespace aether
