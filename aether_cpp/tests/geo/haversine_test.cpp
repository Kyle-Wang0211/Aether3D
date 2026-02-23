// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/haversine.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // Golden vector: London (51.5074, -0.1278) → Paris (48.8566, 2.3522)
    // Expected haversine ≈ 343.56 km (WGS-84 sphere)
    {
        const double d = aether::geo::distance_haversine(51.5074, -0.1278, 48.8566, 2.3522);
        if (std::fabs(d - 343560.0) > 500.0) {
            std::fprintf(stderr, "haversine London-Paris: got %.1f, expected ~343560 m\n", d);
            ++failed;
        }
    }

    // Equirectangular should be in same ballpark (< 1% off for short distances)
    {
        const double d = aether::geo::distance_equirectangular(51.5074, -0.1278, 48.8566, 2.3522);
        if (std::fabs(d - 343560.0) > 5000.0) {
            std::fprintf(stderr, "equirect London-Paris: got %.1f, expected ~343560 m\n", d);
            ++failed;
        }
    }

    // Vincenty on same golden vector — should be more precise
    {
        double dist = 0.0;
        auto s = aether::geo::distance_vincenty(51.5074, -0.1278, 48.8566, 2.3522, &dist);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "vincenty London-Paris: status != kOk\n");
            ++failed;
        }
        // Vincenty reference: ~343.9 km on the WGS-84 ellipsoid
        if (std::fabs(dist - 343900.0) > 500.0) {
            std::fprintf(stderr, "vincenty London-Paris: got %.1f, expected ~343900 m\n", dist);
            ++failed;
        }
    }

    // Same point → 0
    {
        const double d = aether::geo::distance_haversine(0.0, 0.0, 0.0, 0.0);
        if (d > 0.001) {
            std::fprintf(stderr, "haversine same point: got %.6f, expected 0\n", d);
            ++failed;
        }
    }

    // Antipodal points — half circumference ≈ 20015 km
    {
        const double d = aether::geo::distance_haversine(0.0, 0.0, 0.0, 180.0);
        if (std::fabs(d - 20015086.8) > 1000.0) {
            std::fprintf(stderr, "haversine antipodal: got %.1f, expected ~20015087 m\n", d);
            ++failed;
        }
    }

    return failed;
}