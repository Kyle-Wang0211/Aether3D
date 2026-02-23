// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_MAP_GLOBE_PROJECTION_H
#define AETHER_GEO_MAP_GLOBE_PROJECTION_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

struct ECEFCoord {
    double x, y, z;
};

struct GeodeticCoord {
    double lat_deg, lon_deg, alt_m;
};

/// Convert geodetic (lat/lon/alt) to ECEF using WGS84 ellipsoid.
core::Status geodetic_to_ecef(const GeodeticCoord& geo, ECEFCoord* out);

/// Convert ECEF to geodetic using Bowring's iterative method.
core::Status ecef_to_geodetic(const ECEFCoord& ecef, GeodeticCoord* out);

/// Horizon culling: returns true if point is behind the horizon from camera.
bool horizon_cull(const ECEFCoord& camera, const ECEFCoord& point,
                  double earth_radius);

/// Relative-to-Eye split for GPU double-precision emulation (Knuth two-sum).
void rte_split(double value, float* out_high, float* out_low);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_MAP_GLOBE_PROJECTION_H
