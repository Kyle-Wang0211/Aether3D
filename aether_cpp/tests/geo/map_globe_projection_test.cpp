// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_globe_projection.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

namespace {

bool roundtrip_check(const char* name, double lat, double lon, double alt,
                     double tol_m, int& failed) {
    aether::geo::GeodeticCoord geo_in{lat, lon, alt};
    aether::geo::ECEFCoord ecef{};
    aether::geo::GeodeticCoord geo_out{};

    auto s1 = aether::geo::geodetic_to_ecef(geo_in, &ecef);
    if (s1 != aether::core::Status::kOk) {
        std::fprintf(stderr, "%s: geodetic_to_ecef failed\n", name);
        ++failed;
        return false;
    }

    auto s2 = aether::geo::ecef_to_geodetic(ecef, &geo_out);
    if (s2 != aether::core::Status::kOk) {
        std::fprintf(stderr, "%s: ecef_to_geodetic failed\n", name);
        ++failed;
        return false;
    }

    double dlat = std::fabs(geo_out.lat_deg - lat);
    double dlon = std::fabs(geo_out.lon_deg - lon);
    double dalt = std::fabs(geo_out.alt_m - alt);

    // Convert lat/lon error to meters (approximate)
    double lat_error_m = dlat * aether::geo::DEG_TO_RAD * aether::geo::WGS84_A;
    double lon_error_m = dlon * aether::geo::DEG_TO_RAD * aether::geo::WGS84_A
                       * std::cos(lat * aether::geo::DEG_TO_RAD);

    double total_error = std::sqrt(lat_error_m * lat_error_m
                                 + lon_error_m * lon_error_m
                                 + dalt * dalt);

    if (total_error > tol_m) {
        std::fprintf(stderr, "%s: roundtrip error %.6f m (lat:%.9f lon:%.9f alt:%.3f)"
                     " -> (lat:%.9f lon:%.9f alt:%.3f)\n",
                     name, total_error, lat, lon, alt,
                     geo_out.lat_deg, geo_out.lon_deg, geo_out.alt_m);
        ++failed;
        return false;
    }

    return true;
}

}  // anonymous namespace

int main() {
    int failed = 0;

    // --- Test 1: Roundtrip London (51.5074, -0.1278, 11m) < 1mm ---
    roundtrip_check("London", 51.5074, -0.1278, 11.0, 0.001, failed);

    // --- Test 2: Roundtrip Tokyo (35.6762, 139.6503, 40m) < 1mm ---
    roundtrip_check("Tokyo", 35.6762, 139.6503, 40.0, 0.001, failed);

    // --- Test 3: Roundtrip North Pole (90.0, 0.0, 0m) < 1mm ---
    roundtrip_check("North Pole", 90.0, 0.0, 0.0, 0.001, failed);

    // --- Test 4: Roundtrip Equator/Prime Meridian (0.0, 0.0, 0m) < 1mm ---
    roundtrip_check("Equator", 0.0, 0.0, 0.0, 0.001, failed);

    // --- Test 5: Roundtrip High Altitude (45.0, 90.0, 35000m) < 1mm ---
    roundtrip_check("High Alt", 45.0, 90.0, 35000.0, 0.001, failed);

    // --- Test 6: Known ECEF values for equator, prime meridian ---
    // At (0, 0, 0m): ECEF should be (WGS84_A, 0, 0)
    {
        aether::geo::GeodeticCoord geo{0.0, 0.0, 0.0};
        aether::geo::ECEFCoord ecef{};
        auto s = aether::geo::geodetic_to_ecef(geo, &ecef);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "equator ECEF: status != kOk\n");
            ++failed;
        } else {
            if (std::fabs(ecef.x - aether::geo::WGS84_A) > 0.01) {
                std::fprintf(stderr, "equator ECEF x: got %.3f, expected %.3f\n",
                             ecef.x, aether::geo::WGS84_A);
                ++failed;
            }
            if (std::fabs(ecef.y) > 0.01) {
                std::fprintf(stderr, "equator ECEF y: got %.3f, expected 0\n", ecef.y);
                ++failed;
            }
            if (std::fabs(ecef.z) > 0.01) {
                std::fprintf(stderr, "equator ECEF z: got %.3f, expected 0\n", ecef.z);
                ++failed;
            }
        }
    }

    // --- Test 7: horizon_cull basic test ---
    {
        double R = aether::geo::WGS84_A;
        // Camera at 2R above the surface on X axis
        aether::geo::ECEFCoord camera{3.0 * R, 0, 0};
        // Point on the surface directly visible
        aether::geo::ECEFCoord visible{R, 0, 0};
        // Point on the far side of earth
        aether::geo::ECEFCoord behind{-R, 0, 0};

        bool cull_visible = aether::geo::horizon_cull(camera, visible, R);
        bool cull_behind = aether::geo::horizon_cull(camera, behind, R);

        if (cull_visible) {
            std::fprintf(stderr, "horizon_cull: visible point was culled\n");
            ++failed;
        }
        if (!cull_behind) {
            std::fprintf(stderr, "horizon_cull: behind point was NOT culled\n");
            ++failed;
        }
    }

    // --- Test 8: rte_split precision ---
    {
        double value = 6378137.123456789;
        float hi = 0, lo = 0;
        aether::geo::rte_split(value, &hi, &lo);

        // Reconstruct
        double reconstructed = static_cast<double>(hi) + static_cast<double>(lo);
        double error = std::fabs(reconstructed - value);
        if (error > 1.0) {
            std::fprintf(stderr, "rte_split: error %.10f for value %.10f\n",
                         error, value);
            ++failed;
        }
    }

    // --- Test 9: Null pointer checks ---
    {
        aether::geo::GeodeticCoord geo{0, 0, 0};
        auto s1 = aether::geo::geodetic_to_ecef(geo, nullptr);
        if (s1 != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "geodetic_to_ecef null: expected kInvalidArgument\n");
            ++failed;
        }

        aether::geo::ECEFCoord ecef{0, 0, 0};
        auto s2 = aether::geo::ecef_to_geodetic(ecef, nullptr);
        if (s2 != aether::core::Status::kInvalidArgument) {
            std::fprintf(stderr, "ecef_to_geodetic null: expected kInvalidArgument\n");
            ++failed;
        }
    }

    // --- Test 10: Out of range lat/lon ---
    {
        aether::geo::GeodeticCoord bad_lat{91.0, 0.0, 0.0};
        aether::geo::ECEFCoord ecef{};
        auto s = aether::geo::geodetic_to_ecef(bad_lat, &ecef);
        if (s != aether::core::Status::kOutOfRange) {
            std::fprintf(stderr, "geodetic_to_ecef bad lat: expected kOutOfRange\n");
            ++failed;
        }
    }

    return failed;
}
