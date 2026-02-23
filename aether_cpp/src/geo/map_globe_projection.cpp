// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_globe_projection.h"
#include "aether/geo/geo_constants.h"

#include <cmath>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// geodetic_to_ecef: WGS84 geodetic to Earth-Centered Earth-Fixed
// ---------------------------------------------------------------------------
core::Status geodetic_to_ecef(const GeodeticCoord& geo, ECEFCoord* out) {
    if (!out) return core::Status::kInvalidArgument;
    if (geo.lat_deg < -90.0 || geo.lat_deg > 90.0) return core::Status::kOutOfRange;
    if (geo.lon_deg < -180.0 || geo.lon_deg > 180.0) return core::Status::kOutOfRange;

    double lat_rad = geo.lat_deg * DEG_TO_RAD;
    double lon_rad = geo.lon_deg * DEG_TO_RAD;

    double sin_lat = std::sin(lat_rad);
    double cos_lat = std::cos(lat_rad);
    double sin_lon = std::sin(lon_rad);
    double cos_lon = std::cos(lon_rad);

    // Radius of curvature in the prime vertical
    double N = WGS84_A / std::sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat);

    out->x = (N + geo.alt_m) * cos_lat * cos_lon;
    out->y = (N + geo.alt_m) * cos_lat * sin_lon;
    out->z = (N * (1.0 - WGS84_E2) + geo.alt_m) * sin_lat;

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// ecef_to_geodetic: Bowring's iterative method
// ---------------------------------------------------------------------------
core::Status ecef_to_geodetic(const ECEFCoord& ecef, GeodeticCoord* out) {
    if (!out) return core::Status::kInvalidArgument;

    double x = ecef.x;
    double y = ecef.y;
    double z = ecef.z;

    double p = std::sqrt(x * x + y * y);
    double lon_rad = std::atan2(y, x);

    // Iterative latitude from ECEF (Bowring/Vermeille-style)
    // Iterate directly on latitude for maximum precision
    double lat_rad = std::atan2(z, p * (1.0 - WGS84_E2));  // initial estimate

    for (int iter = 0; iter < 20; ++iter) {
        double sin_lat = std::sin(lat_rad);
        double N = WGS84_A / std::sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat);

        // Improved latitude from the ECEF equations
        double new_lat = std::atan2(z + WGS84_E2 * N * sin_lat, p);

        if (std::fabs(new_lat - lat_rad) < 1e-15) break;
        lat_rad = new_lat;
    }

    double sin_lat = std::sin(lat_rad);
    double N = WGS84_A / std::sqrt(1.0 - WGS84_E2 * sin_lat * sin_lat);
    double cos_lat = std::cos(lat_rad);

    double alt;
    if (std::fabs(cos_lat) > 1e-10) {
        alt = p / cos_lat - N;
    } else {
        alt = std::fabs(z) / std::fabs(sin_lat) - N * (1.0 - WGS84_E2);
    }

    out->lat_deg = lat_rad * RAD_TO_DEG;
    out->lon_deg = lon_rad * RAD_TO_DEG;
    out->alt_m = alt;

    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// horizon_cull: dot product test
// Returns true if point is behind the horizon from camera's perspective.
// ---------------------------------------------------------------------------
bool horizon_cull(const ECEFCoord& camera, const ECEFCoord& point,
                  double earth_radius) {
    // Vector from earth center to camera
    double cam_dist = std::sqrt(camera.x * camera.x + camera.y * camera.y + camera.z * camera.z);
    if (cam_dist < earth_radius) return false;  // Camera inside earth

    // Vector from camera to point
    double dx = point.x - camera.x;
    double dy = point.y - camera.y;
    double dz = point.z - camera.z;

    // Dot product of camera-to-point with camera direction (normalized camera position)
    double dot = (camera.x * dx + camera.y * dy + camera.z * dz);

    // If the dot product is positive, the point is generally in front of the camera.
    // For horizon culling, check if the point is below the tangent plane.
    // The tangent plane at the camera's closest point on the earth sphere:
    //   dot(camera_unit, point - camera) > -(cam_dist - R^2/cam_dist)
    // Simplified: point is behind horizon if the angle between camera_to_point
    // and camera_from_center exceeds the horizon angle.

    double horizon_threshold = cam_dist - (earth_radius * earth_radius) / cam_dist;

    // Project camera-to-point onto camera direction
    double proj = dot / cam_dist;

    // If the projection is more negative than the horizon threshold, point is behind
    return proj < -horizon_threshold;
}

// ---------------------------------------------------------------------------
// rte_split: Knuth two-sum for GPU double-precision emulation
// Splits a double into high + low float pair where value ~= high + low
// ---------------------------------------------------------------------------
void rte_split(double value, float* out_high, float* out_low) {
    if (!out_high || !out_low) return;

    float high = static_cast<float>(value);
    double low = value - static_cast<double>(high);

    *out_high = high;
    *out_low = static_cast<float>(low);
}

}  // namespace geo
}  // namespace aether
