// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_GEO_INDEXER_H
#define AETHER_GEO_GEO_INDEXER_H

#include "aether/core/status.h"
#include "aether/geo/rtree.h"
#include "aether/geo/asc_cell.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

/// Geo entry with evidence weight and timestamp for the dual-layer indexer.
struct GeoRecord {
    double lat{0};
    double lon{0};
    std::uint64_t id{0};
    float evidence_weight{1.0f};
    double timestamp_s{0};
    std::uint64_t asc_cell{0};   // Precomputed ASC cell ID (filled by indexer)
};

/// 4-layer admission gate result.
enum class AdmissionResult : std::int32_t {
    kAccepted = 0,
    kRejectedBounds = 1,
    kRejectedDuplicate = 2,
    kRejectedLowEvidence = 3,
    kRejectedCapacity = 4,
};

/// Opaque dual-layer geo indexer handle.
struct GeoIndexer;

// ── Legacy C-style free functions (preserved for backward compatibility) ──

/// Create / destroy.
GeoIndexer* geo_indexer_create(std::size_t capacity);
void geo_indexer_destroy(GeoIndexer* indexer);

/// Insert a record through the admission gate.
/// Returns kOk on acceptance, kInvalidArgument on null pointer.
/// *out_admission receives the gate result.
core::Status geo_indexer_insert(GeoIndexer* indexer,
                                const GeoRecord& record,
                                AdmissionResult* out_admission);

/// Query by MBR using dual-layer (ASC coarse + R*-tree fine).
core::Status geo_indexer_query_range(const GeoIndexer* indexer,
                                     const MBR& range,
                                     GeoRecord* out_records,
                                     std::size_t max_results,
                                     std::size_t* out_count);

/// Evidence-weighted scoring query: returns records sorted by score desc.
core::Status geo_indexer_query_scored(const GeoIndexer* indexer,
                                      double lat, double lon,
                                      double radius_m,
                                      GeoRecord* out_records,
                                      std::size_t max_results,
                                      std::size_t* out_count);

/// Return total number of indexed records.
std::size_t geo_indexer_size(const GeoIndexer* indexer);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_GEO_INDEXER_H
