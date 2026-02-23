// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_TEMPORAL_CLUSTER_H
#define AETHER_GEO_TEMPORAL_CLUSTER_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct STPoint {
    double lat, lon, alt_m, timestamp_s;
    uint64_t id;
};

struct STCluster {
    double center_lat, center_lon, center_alt;
    uint32_t point_count;
    double heat;
    uint64_t cluster_id;
};

struct TemporalCluster;

/// Create a temporal cluster engine with ST-DBSCAN parameters.
TemporalCluster* temporal_cluster_create(double spatial_eps_m,
                                         double temporal_eps_s,
                                         double altitude_eps_m,
                                         uint32_t min_points);

/// Destroy a temporal cluster engine.
void temporal_cluster_destroy(TemporalCluster* tc);

/// Add a spatio-temporal point.
core::Status temporal_cluster_add(TemporalCluster* tc, const STPoint& point);

/// Run clustering and write results.
core::Status temporal_cluster_run(TemporalCluster* tc,
                                  STCluster* out, size_t max,
                                  size_t* out_count);

/// Apply exponential heat decay to all clusters.
core::Status temporal_cluster_heat_decay(TemporalCluster* tc,
                                         double current_time_s);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_TEMPORAL_CLUSTER_H
