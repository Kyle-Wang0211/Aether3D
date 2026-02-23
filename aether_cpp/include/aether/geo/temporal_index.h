// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_TEMPORAL_INDEX_H
#define AETHER_GEO_TEMPORAL_INDEX_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct TemporalEntry {
    uint64_t spatial_cell;
    uint32_t temporal_bucket;
    uint64_t record_id;
    float value;
    double timestamp_s;
};

struct TemporalIndex;

/// Create a temporal index with given WAL capacity.
TemporalIndex* temporal_index_create(size_t wal_capacity);

/// Destroy a temporal index.
void temporal_index_destroy(TemporalIndex* index);

/// Insert an entry into the WAL.
core::Status temporal_index_insert(TemporalIndex* index,
                                   const TemporalEntry& entry);

/// Range query by spatial cell and temporal bucket range [bucket_start, bucket_end].
core::Status temporal_index_query(const TemporalIndex* index,
                                  uint64_t spatial_cell,
                                  uint32_t bucket_start, uint32_t bucket_end,
                                  TemporalEntry* out, size_t max,
                                  size_t* out_count);

/// Compact WAL into sorted store.
core::Status temporal_index_compact(TemporalIndex* index);

/// Total number of entries (WAL + sorted store).
size_t temporal_index_size(const TemporalIndex* index);

/// Number of entries currently in the WAL.
size_t temporal_index_wal_size(const TemporalIndex* index);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_TEMPORAL_INDEX_H
