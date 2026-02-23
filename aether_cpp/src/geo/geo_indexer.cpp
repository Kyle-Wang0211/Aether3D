// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/geo_indexer.h"
#include "aether/geo/geo_constants.h"
#include "aether/geo/haversine.h"

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace aether {
namespace geo {

struct GeoIndexer {
    RTree* rtree{nullptr};
    std::size_t capacity{0};
    std::size_t count{0};
    std::vector<GeoRecord> records;
    std::unordered_set<std::uint64_t> id_set;
    // ASC coarse index: cell → record indices
    std::unordered_map<std::uint64_t, std::vector<std::size_t>> asc_index;
};

GeoIndexer* geo_indexer_create(std::size_t capacity) {
    auto* idx = new GeoIndexer();
    idx->rtree = rtree_create();
    idx->capacity = capacity;
    idx->records.reserve(capacity < 100000 ? capacity : 100000);
    return idx;
}

void geo_indexer_destroy(GeoIndexer* indexer) {
    if (indexer) {
        rtree_destroy(indexer->rtree);
        delete indexer;
    }
}

core::Status geo_indexer_insert(GeoIndexer* indexer,
                                const GeoRecord& record,
                                AdmissionResult* out_admission) {
    if (!indexer || !out_admission) return core::Status::kInvalidArgument;

    // Layer 1: Bounds check
    if (record.lat < LAT_MIN || record.lat > LAT_MAX ||
        record.lon < LON_MIN || record.lon > LON_MAX) {
        *out_admission = AdmissionResult::kRejectedBounds;
        return core::Status::kOk;
    }

    // Layer 2: Duplicate check
    if (indexer->id_set.count(record.id)) {
        *out_admission = AdmissionResult::kRejectedDuplicate;
        return core::Status::kOk;
    }

    // Layer 3: Evidence threshold
    if (record.evidence_weight < 0.01f) {
        *out_admission = AdmissionResult::kRejectedLowEvidence;
        return core::Status::kOk;
    }

    // Layer 4: Capacity
    if (indexer->count >= indexer->capacity) {
        *out_admission = AdmissionResult::kRejectedCapacity;
        return core::Status::kOk;
    }

    // Compute ASC cell
    GeoRecord rec = record;
    latlon_to_cell(rec.lat, rec.lon, ASC_CELL_MAX_LEVEL, &rec.asc_cell);

    // Insert into R*-tree
    RTreeEntry re{};
    re.lat = rec.lat;
    re.lon = rec.lon;
    re.id = rec.id;
    re.score = rec.evidence_weight;
    rtree_insert(indexer->rtree, re);

    // Insert into records and indices
    std::size_t idx = indexer->records.size();
    indexer->records.push_back(rec);
    indexer->id_set.insert(rec.id);
    indexer->asc_index[rec.asc_cell].push_back(idx);
    indexer->count++;

    *out_admission = AdmissionResult::kAccepted;
    return core::Status::kOk;
}

core::Status geo_indexer_query_range(const GeoIndexer* indexer,
                                     const MBR& range,
                                     GeoRecord* out_records,
                                     std::size_t max_results,
                                     std::size_t* out_count) {
    if (!indexer || !out_count) return core::Status::kInvalidArgument;

    // Use R*-tree for fine query
    std::vector<RTreeEntry> rtree_results(max_results > 0 ? max_results : 1);
    std::size_t rtree_count = 0;
    rtree_query_range(indexer->rtree, range,
                      rtree_results.data(), max_results, &rtree_count);

    *out_count = (rtree_count < max_results) ? rtree_count : max_results;
    if (out_records) {
        for (std::size_t i = 0; i < *out_count; ++i) {
            // Find matching record
            for (const auto& r : indexer->records) {
                if (r.id == rtree_results[i].id) {
                    out_records[i] = r;
                    break;
                }
            }
        }
    }
    return core::Status::kOk;
}

core::Status geo_indexer_query_scored(const GeoIndexer* indexer,
                                      double lat, double lon,
                                      double radius_m,
                                      GeoRecord* out_records,
                                      std::size_t max_results,
                                      std::size_t* out_count) {
    if (!indexer || !out_count) return core::Status::kInvalidArgument;
    *out_count = 0;

    // Compute MBR from radius
    double dlat = radius_m / 111320.0;
    double cos_lat = std::cos(lat * DEG_TO_RAD);
    // Guard against division by near-zero at poles — cap cos to minimum 0.01 (~89.4°)
    if (cos_lat < 0.01) cos_lat = 0.01;
    double dlon = radius_m / (111320.0 * cos_lat);

    MBR range{lat - dlat, lat + dlat, lon - dlon, lon + dlon};

    // Get range results
    std::vector<RTreeEntry> rtree_results(GEO_MAX_RESULTS_PER_QUERY);
    std::size_t rtree_count = 0;
    rtree_query_range(indexer->rtree, range,
                      rtree_results.data(), GEO_MAX_RESULTS_PER_QUERY, &rtree_count);

    // Score and filter by actual radius
    struct ScoredRecord {
        GeoRecord record;
        float score;
    };
    std::vector<ScoredRecord> scored;

    for (std::size_t i = 0; i < rtree_count; ++i) {
        double d = distance_haversine(lat, lon, rtree_results[i].lat, rtree_results[i].lon);
        if (d > radius_m) continue;

        // Find full record
        for (const auto& r : indexer->records) {
            if (r.id == rtree_results[i].id) {
                float dist_score = static_cast<float>(1.0 - d / radius_m);
                scored.push_back({r, r.evidence_weight * dist_score});
                break;
            }
        }
    }

    // Sort by score descending
    std::sort(scored.begin(), scored.end(),
        [](const ScoredRecord& a, const ScoredRecord& b) { return a.score > b.score; });

    *out_count = (scored.size() < max_results) ? scored.size() : max_results;
    if (out_records) {
        for (std::size_t i = 0; i < *out_count; ++i) {
            out_records[i] = scored[i].record;
        }
    }
    return core::Status::kOk;
}

std::size_t geo_indexer_size(const GeoIndexer* indexer) {
    return indexer ? indexer->count : 0;
}

}  // namespace geo
}  // namespace aether
