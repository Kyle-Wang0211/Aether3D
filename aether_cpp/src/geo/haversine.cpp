// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/haversine.h"
#include "aether/geo/geo_constants.h"

#include <cmath>
#include <cstddef>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Equirectangular approximation
// ---------------------------------------------------------------------------
double distance_equirectangular(double lat1_deg, double lon1_deg,
                                double lat2_deg, double lon2_deg) {
    const double lat1 = lat1_deg * DEG_TO_RAD;
    const double lat2 = lat2_deg * DEG_TO_RAD;
    const double dlon = (lon2_deg - lon1_deg) * DEG_TO_RAD;
    const double dlat = lat2 - lat1;

    const double cos_mid = std::cos((lat1 + lat2) * 0.5);
    const double x = dlon * cos_mid;
    return EARTH_MEAN_RADIUS_M * std::sqrt(x * x + dlat * dlat);
}

// ---------------------------------------------------------------------------
// Haversine
// ---------------------------------------------------------------------------
double distance_haversine(double lat1_deg, double lon1_deg,
                          double lat2_deg, double lon2_deg) {
    const double lat1 = lat1_deg * DEG_TO_RAD;
    const double lat2 = lat2_deg * DEG_TO_RAD;
    const double dlat = (lat2_deg - lat1_deg) * DEG_TO_RAD;
    const double dlon = (lon2_deg - lon1_deg) * DEG_TO_RAD;

    const double sin_dlat2 = std::sin(dlat * 0.5);
    const double sin_dlon2 = std::sin(dlon * 0.5);

    const double a = sin_dlat2 * sin_dlat2 +
                     std::cos(lat1) * std::cos(lat2) * sin_dlon2 * sin_dlon2;
    const double c = 2.0 * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
    return EARTH_MEAN_RADIUS_M * c;
}

// ---------------------------------------------------------------------------
// Vincenty inverse on WGS-84 ellipsoid
// ---------------------------------------------------------------------------
core::Status distance_vincenty(double lat1_deg, double lon1_deg,
                               double lat2_deg, double lon2_deg,
                               double* out_distance_m) {
    if (!out_distance_m) return core::Status::kInvalidArgument;

    // Check near-coincident points
    if (std::fabs(lat1_deg - lat2_deg) < COORDINATE_EPSILON &&
        std::fabs(lon1_deg - lon2_deg) < COORDINATE_EPSILON) {
        *out_distance_m = 0.0;
        return core::Status::kOk;
    }

    // Check near-antipodal
    if (std::fabs(lat1_deg + lat2_deg) < COORDINATE_EPSILON &&
        std::fabs(std::fabs(lon1_deg - lon2_deg) - 180.0) < (180.0 - ANTIPODAL_THRESHOLD)) {
        // Fall back to haversine for near-antipodal
        *out_distance_m = distance_haversine(lat1_deg, lon1_deg, lat2_deg, lon2_deg);
        return core::Status::kOk;
    }

    const double U1 = std::atan((1.0 - WGS84_F) * std::tan(lat1_deg * DEG_TO_RAD));
    const double U2 = std::atan((1.0 - WGS84_F) * std::tan(lat2_deg * DEG_TO_RAD));
    const double sin_U1 = std::sin(U1), cos_U1 = std::cos(U1);
    const double sin_U2 = std::sin(U2), cos_U2 = std::cos(U2);

    const double L = (lon2_deg - lon1_deg) * DEG_TO_RAD;
    double lambda = L;
    double prev_lambda = 0.0;

    double sin_sigma = 0.0, cos_sigma = 0.0, sigma = 0.0;
    double sin_alpha = 0.0, cos2_alpha = 0.0, cos_2sigma_m = 0.0;

    static constexpr int kMaxIter = 200;
    int iter = 0;
    for (; iter < kMaxIter; ++iter) {
        const double sin_lambda = std::sin(lambda);
        const double cos_lambda = std::cos(lambda);

        const double t1 = cos_U2 * sin_lambda;
        const double t2 = cos_U1 * sin_U2 - sin_U1 * cos_U2 * cos_lambda;
        sin_sigma = std::sqrt(t1 * t1 + t2 * t2);
        if (sin_sigma < 1e-15) {
            *out_distance_m = 0.0;
            return core::Status::kOk;
        }

        cos_sigma = sin_U1 * sin_U2 + cos_U1 * cos_U2 * cos_lambda;
        sigma = std::atan2(sin_sigma, cos_sigma);
        sin_alpha = cos_U1 * cos_U2 * sin_lambda / sin_sigma;
        cos2_alpha = 1.0 - sin_alpha * sin_alpha;

        cos_2sigma_m = (cos2_alpha > 1e-15)
            ? cos_sigma - 2.0 * sin_U1 * sin_U2 / cos2_alpha
            : 0.0;

        const double C = WGS84_F / 16.0 * cos2_alpha * (4.0 + WGS84_F * (4.0 - 3.0 * cos2_alpha));
        prev_lambda = lambda;
        lambda = L + (1.0 - C) * WGS84_F * sin_alpha *
                 (sigma + C * sin_sigma * (cos_2sigma_m + C * cos_sigma *
                 (-1.0 + 2.0 * cos_2sigma_m * cos_2sigma_m)));

        if (std::fabs(lambda - prev_lambda) < 1e-12) break;
    }

    if (iter >= kMaxIter) {
        // L4 FIX: Return kOutOfRange on Vincenty non-convergence as documented
        // in haversine.h, while still providing a useful fallback value via
        // Haversine (which has ~0.3% error on the ellipsoid but never diverges).
        *out_distance_m = distance_haversine(lat1_deg, lon1_deg, lat2_deg, lon2_deg);
        return core::Status::kOutOfRange;
    }

    const double u2 = cos2_alpha * WGS84_EP2;
    const double A = 1.0 + u2 / 16384.0 * (4096.0 + u2 * (-768.0 + u2 * (320.0 - 175.0 * u2)));
    const double B = u2 / 1024.0 * (256.0 + u2 * (-128.0 + u2 * (74.0 - 47.0 * u2)));
    const double delta_sigma = B * sin_sigma *
        (cos_2sigma_m + B / 4.0 * (cos_sigma * (-1.0 + 2.0 * cos_2sigma_m * cos_2sigma_m)
         - B / 6.0 * cos_2sigma_m * (-3.0 + 4.0 * sin_sigma * sin_sigma)
                                  * (-3.0 + 4.0 * cos_2sigma_m * cos_2sigma_m)));

    *out_distance_m = WGS84_B * A * (sigma - delta_sigma);
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Batch haversine
// ---------------------------------------------------------------------------
core::Status distance_haversine_batch(double origin_lat_deg, double origin_lon_deg,
                                      const double* target_lats_deg,
                                      const double* target_lons_deg,
                                      double* out_distances_m,
                                      std::size_t count) {
    if (count > 0 && (!target_lats_deg || !target_lons_deg || !out_distances_m)) {
        return core::Status::kInvalidArgument;
    }
    for (std::size_t i = 0; i < count; ++i) {
        out_distances_m[i] = distance_haversine(origin_lat_deg, origin_lon_deg,
                                                target_lats_deg[i], target_lons_deg[i]);
    }
    return core::Status::kOk;
}

// ---------------------------------------------------------------------------
// Initial bearing
// ---------------------------------------------------------------------------
double initial_bearing_deg(double lat1_deg, double lon1_deg,
                           double lat2_deg, double lon2_deg) {
    const double lat1 = lat1_deg * DEG_TO_RAD;
    const double lat2 = lat2_deg * DEG_TO_RAD;
    const double dlon = (lon2_deg - lon1_deg) * DEG_TO_RAD;

    const double y = std::sin(dlon) * std::cos(lat2);
    const double x = std::cos(lat1) * std::sin(lat2) -
                     std::sin(lat1) * std::cos(lat2) * std::cos(dlon);
    double bearing = std::atan2(y, x) * RAD_TO_DEG;
    if (bearing < 0.0) bearing += 360.0;
    return bearing;
}

}  // namespace geo
}  // namespace aether
