// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_HAVERSINE_H
#define AETHER_GEO_HAVERSINE_H

#include "aether/core/status.h"

#include <cstddef>

namespace aether {
namespace geo {

/// Equirectangular approximation — fastest, ~0.5% error at mid-latitudes.
/// Returns distance in meters.  Suitable for coarse filtering.
double distance_equirectangular(double lat1_deg, double lon1_deg,
                                double lat2_deg, double lon2_deg);

/// Haversine formula — good for any distance, ~0.3% max error.
/// Returns distance in meters on the WGS-84 mean sphere.
double distance_haversine(double lat1_deg, double lon1_deg,
                          double lat2_deg, double lon2_deg);

/// Vincenty inverse formula on WGS-84 ellipsoid — sub-millimeter accuracy.
/// Returns core::Status::kOk on success, kOutOfRange on antipodal non-convergence.
/// On failure *out_distance_m is set to NaN.
core::Status distance_vincenty(double lat1_deg, double lon1_deg,
                               double lat2_deg, double lon2_deg,
                               double* out_distance_m);

/// Batch haversine: compute N distances from one origin to N targets.
/// out_distances must have capacity >= count.
/// Returns core::Status::kOk, or kInvalidArgument if pointers are null.
core::Status distance_haversine_batch(double origin_lat_deg, double origin_lon_deg,
                                      const double* target_lats_deg,
                                      const double* target_lons_deg,
                                      double* out_distances_m,
                                      std::size_t count);

/// Initial bearing from point 1 to point 2 in degrees [0, 360).
double initial_bearing_deg(double lat1_deg, double lon1_deg,
                           double lat2_deg, double lon2_deg);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_HAVERSINE_H
