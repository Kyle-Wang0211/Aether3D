// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_GEO_CLUSTER_H
#define AETHER_GEO_GEO_CLUSTER_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

/// A cluster of geo points at a given zoom level.
struct GeoCluster {
    double center_lat{0};
    double center_lon{0};
    std::uint32_t point_count{0};
    float total_weight{0};
    std::uint64_t representative_id{0};   // ID of the highest-weight point
};

/// Input point for clustering.
struct ClusterPoint {
    double lat{0};
    double lon{0};
    std::uint64_t id{0};
    float weight{1.0f};
};

/// Cluster points at the given zoom level using ASC grid-based clustering.
/// zoom_level: [0, 20].  radius_px: cluster radius in screen pixels.
/// out_clusters: output array.  max_clusters: capacity.
/// *out_count: number of clusters produced.
core::Status geo_cluster_points(const ClusterPoint* points, std::size_t point_count,
                                std::uint32_t zoom_level,
                                std::uint32_t radius_px,
                                GeoCluster* out_clusters, std::size_t max_clusters,
                                std::size_t* out_count);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_GEO_CLUSTER_H
