// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_RTREE_H
#define AETHER_GEO_RTREE_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

/// Minimum bounding rectangle (lat/lon degrees).
struct MBR {
    double lat_min{0};
    double lat_max{0};
    double lon_min{0};
    double lon_max{0};

    double area() const {
        return (lat_max - lat_min) * (lon_max - lon_min);
    }
    bool contains(double lat, double lon) const {
        return lat >= lat_min && lat <= lat_max &&
               lon >= lon_min && lon <= lon_max;
    }
    bool intersects(const MBR& o) const {
        return !(o.lat_max < lat_min || o.lat_min > lat_max ||
                 o.lon_max < lon_min || o.lon_min > lon_max);
    }
};

/// Merge two MBRs.
MBR mbr_union(const MBR& a, const MBR& b);

/// Point entry stored in the R*-tree.
struct RTreeEntry {
    double lat{0};
    double lon{0};
    std::uint64_t id{0};      // User-defined identifier
    float score{1.0f};         // Evidence-weighted score
};

/// k-NN result.
struct KNNResult {
    std::uint64_t id{0};
    double distance_m{0};
};

/// Opaque R*-tree handle.
struct RTree;

/// Create / destroy
RTree* rtree_create();
void rtree_destroy(RTree* tree);

/// Insert a point entry.
core::Status rtree_insert(RTree* tree, const RTreeEntry& entry);

/// Remove an entry by id.  Returns kOk if found, kOutOfRange if not found.
core::Status rtree_remove(RTree* tree, std::uint64_t id);

/// Range query: find all entries within the given MBR.
/// Results are written to out_entries, up to max_results.
/// *out_count receives the actual number found.
core::Status rtree_query_range(const RTree* tree, const MBR& range,
                               RTreeEntry* out_entries, std::size_t max_results,
                               std::size_t* out_count);

/// k-Nearest Neighbors query.
/// Returns up to k results sorted by distance (haversine).
core::Status rtree_query_knn(const RTree* tree,
                             double query_lat, double query_lon,
                             std::size_t k,
                             KNNResult* out_results, std::size_t* out_count);

/// Bulk-load using STR (Sort-Tile-Recursive) with Hilbert ordering.
/// The tree must be empty. Entries are copied internally.
core::Status rtree_bulk_load(RTree* tree,
                             const RTreeEntry* entries, std::size_t count);

/// Return the number of entries in the tree.
std::size_t rtree_size(const RTree* tree);

/// Return the current depth of the tree.
std::uint32_t rtree_depth(const RTree* tree);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_RTREE_H
