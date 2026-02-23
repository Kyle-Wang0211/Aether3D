// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// GeoEngine C API test — validates the C-linkage wrappers for geo modules.

#include "aether_tsdf_c.h"

#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>

int main() {
    int failed = 0;

    // -----------------------------------------------------------------------
    // Haversine: London -> Paris ~343.56 km
    // -----------------------------------------------------------------------
    {
        double dist = 0.0;
        int rc = aether_geo_distance_haversine(51.5074, -0.1278,
                                               48.8566, 2.3522, &dist);
        if (rc != 0) {
            std::fprintf(stderr, "haversine: unexpected error %d\n", rc);
            ++failed;
        } else if (std::fabs(dist - 343560.0) > 500.0) {
            std::fprintf(stderr, "haversine London-Paris: got %.1f, expected ~343560 m\n", dist);
            ++failed;
        }
    }

    // Haversine null output
    {
        int rc = aether_geo_distance_haversine(0.0, 0.0, 0.0, 0.0, nullptr);
        if (rc == 0) {
            std::fprintf(stderr, "haversine: expected null output to fail\n");
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Vincenty: London -> Paris ~343.9 km on WGS-84 ellipsoid
    // -----------------------------------------------------------------------
    {
        double dist = 0.0;
        int rc = aether_geo_distance_vincenty(51.5074, -0.1278,
                                              48.8566, 2.3522, &dist);
        if (rc != 0) {
            std::fprintf(stderr, "vincenty: unexpected error %d\n", rc);
            ++failed;
        } else if (std::fabs(dist - 343900.0) > 500.0) {
            std::fprintf(stderr, "vincenty London-Paris: got %.1f, expected ~343900 m\n", dist);
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // latlon_to_cell roundtrip
    // -----------------------------------------------------------------------
    {
        uint64_t cell = 0;
        int rc = aether_geo_latlon_to_cell(37.7749, -122.4194, 10, &cell);
        if (rc != 0) {
            std::fprintf(stderr, "latlon_to_cell: unexpected error %d\n", rc);
            ++failed;
        } else {
            double lat_out = 0.0, lon_out = 0.0;
            rc = aether_geo_cell_to_latlon(cell, &lat_out, &lon_out);
            if (rc != 0) {
                std::fprintf(stderr, "cell_to_latlon: unexpected error %d\n", rc);
                ++failed;
            } else {
                // At level 10, cell resolution is ~600m; expect <1 degree error
                if (std::fabs(lat_out - 37.7749) > 1.0) {
                    std::fprintf(stderr, "cell roundtrip lat: got %.4f, expected ~37.7749\n", lat_out);
                    ++failed;
                }
                if (std::fabs(lon_out - (-122.4194)) > 1.0) {
                    std::fprintf(stderr, "cell roundtrip lon: got %.4f, expected ~-122.4194\n", lon_out);
                    ++failed;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Geodetic <-> ECEF roundtrip
    // -----------------------------------------------------------------------
    {
        aether_geo_geodetic_coord_t geo{};
        geo.lat_deg = 37.7749;
        geo.lon_deg = -122.4194;
        geo.alt_m   = 100.0;

        aether_geo_ecef_coord_t ecef{};
        int rc = aether_geo_geodetic_to_ecef(&geo, &ecef);
        if (rc != 0) {
            std::fprintf(stderr, "geodetic_to_ecef: unexpected error %d\n", rc);
            ++failed;
        } else {
            // ECEF should be nonzero
            double r = std::sqrt(ecef.x * ecef.x + ecef.y * ecef.y + ecef.z * ecef.z);
            if (r < 6000000.0 || r > 7000000.0) {
                std::fprintf(stderr, "geodetic_to_ecef: radius %.1f out of range\n", r);
                ++failed;
            }

            // Convert back
            aether_geo_geodetic_coord_t geo2{};
            rc = aether_geo_ecef_to_geodetic(&ecef, &geo2);
            if (rc != 0) {
                std::fprintf(stderr, "ecef_to_geodetic: unexpected error %d\n", rc);
                ++failed;
            } else {
                if (std::fabs(geo2.lat_deg - geo.lat_deg) > 1e-6) {
                    std::fprintf(stderr, "ecef roundtrip lat: got %.8f, expected %.8f\n",
                                 geo2.lat_deg, geo.lat_deg);
                    ++failed;
                }
                if (std::fabs(geo2.lon_deg - geo.lon_deg) > 1e-6) {
                    std::fprintf(stderr, "ecef roundtrip lon: got %.8f, expected %.8f\n",
                                 geo2.lon_deg, geo.lon_deg);
                    ++failed;
                }
                if (std::fabs(geo2.alt_m - geo.alt_m) > 0.01) {
                    std::fprintf(stderr, "ecef roundtrip alt: got %.4f, expected %.4f\n",
                                 geo2.alt_m, geo.alt_m);
                    ++failed;
                }
            }
        }
    }

    // Null checks for geodetic/ecef
    {
        aether_geo_ecef_coord_t ecef{};
        if (aether_geo_geodetic_to_ecef(nullptr, &ecef) == 0) {
            std::fprintf(stderr, "geodetic_to_ecef: expected null input to fail\n");
            ++failed;
        }
        aether_geo_geodetic_coord_t geo{};
        if (aether_geo_ecef_to_geodetic(nullptr, &geo) == 0) {
            std::fprintf(stderr, "ecef_to_geodetic: expected null input to fail\n");
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Solar position: noon at equator on March equinox should give ~0 declination
    // Unix timestamp for 2024-03-20 12:00:00 UTC = 1710936000
    // -----------------------------------------------------------------------
    {
        aether_geo_solar_position_t sp{};
        int rc = aether_geo_solar_position(1710936000.0, 0.0, 0.0, &sp);
        if (rc != 0) {
            std::fprintf(stderr, "solar_position: unexpected error %d\n", rc);
            ++failed;
        } else {
            // Near equinox, declination should be close to 0 (within a few degrees)
            if (std::fabs(sp.declination_deg) > 5.0) {
                std::fprintf(stderr, "solar declination at equinox: got %.2f, expected ~0\n",
                             sp.declination_deg);
                ++failed;
            }
            // Elevation should be defined (finite)
            if (!std::isfinite(sp.elevation_deg)) {
                std::fprintf(stderr, "solar elevation not finite\n");
                ++failed;
            }
        }

        // Null output check
        if (aether_geo_solar_position(1710936000.0, 0.0, 0.0, nullptr) == 0) {
            std::fprintf(stderr, "solar_position: expected null output to fail\n");
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // R-tree: create, insert, query, destroy
    // -----------------------------------------------------------------------
    {
        aether_geo_rtree_t* tree = aether_geo_rtree_create(64);
        if (!tree) {
            std::fprintf(stderr, "rtree_create: returned null\n");
            ++failed;
        } else {
            // Insert some points in San Francisco area
            struct { double lat; double lon; uint64_t id; } points[] = {
                {37.7749, -122.4194, 1},  // SF
                {37.7849, -122.4094, 2},  // Near SF
                {37.3382, -121.8863, 3},  // San Jose
                {37.8716, -122.2727, 4},  // Berkeley
            };

            for (const auto& p : points) {
                int rc = aether_geo_rtree_insert(tree, p.lat, p.lon, p.id, 0);
                if (rc != 0) {
                    std::fprintf(stderr, "rtree_insert id=%" PRIu64 ": error %d\n",
                                 p.id, rc);
                    ++failed;
                }
            }

            // Query range: small box around SF should find points 1 and 2
            uint64_t ids[10] = {};
            uint32_t count = 0;
            int rc = aether_geo_rtree_query_range(tree,
                                                  37.77, 37.79,
                                                  -122.42, -122.40,
                                                  ids, 10, &count);
            if (rc != 0) {
                std::fprintf(stderr, "rtree_query_range: error %d\n", rc);
                ++failed;
            } else if (count < 1 || count > 4) {
                std::fprintf(stderr, "rtree_query_range: expected 1-4 results, got %u\n", count);
                ++failed;
            }

            // Query wider range: should find all 4
            count = 0;
            rc = aether_geo_rtree_query_range(tree,
                                              37.0, 38.0,
                                              -123.0, -121.0,
                                              ids, 10, &count);
            if (rc != 0) {
                std::fprintf(stderr, "rtree_query_range wide: error %d\n", rc);
                ++failed;
            } else if (count != 4) {
                std::fprintf(stderr, "rtree_query_range wide: expected 4, got %u\n", count);
                ++failed;
            }

            // Null tree should fail
            if (aether_geo_rtree_insert(nullptr, 0.0, 0.0, 0, 0) == 0) {
                std::fprintf(stderr, "rtree_insert: expected null tree to fail\n");
                ++failed;
            }

            aether_geo_rtree_destroy(tree);
        }

        // Destroy null should be safe
        aether_geo_rtree_destroy(nullptr);
    }

    // -----------------------------------------------------------------------
    // Altitude engine: create, predict, get height, destroy
    // -----------------------------------------------------------------------
    {
        aether_geo_altitude_engine_t* engine = aether_geo_altitude_engine_create();
        if (!engine) {
            std::fprintf(stderr, "altitude_engine_create: returned null\n");
            ++failed;
        } else {
            // Initial height should be 0 (default state)
            double h = -999.0;
            int rc = aether_geo_altitude_engine_get_height(engine, &h);
            if (rc != 0) {
                std::fprintf(stderr, "altitude_engine_get_height: error %d\n", rc);
                ++failed;
            } else if (std::fabs(h) > 1e-6) {
                std::fprintf(stderr, "altitude_engine initial height: got %.6f, expected 0\n", h);
                ++failed;
            }

            // Predict step should succeed
            rc = aether_geo_altitude_engine_predict(engine, 0.1);
            if (rc != 0) {
                std::fprintf(stderr, "altitude_engine_predict: error %d\n", rc);
                ++failed;
            }

            // Height should still be finite after predict
            rc = aether_geo_altitude_engine_get_height(engine, &h);
            if (rc != 0 || !std::isfinite(h)) {
                std::fprintf(stderr, "altitude_engine: height not finite after predict\n");
                ++failed;
            }

            // Invalid dt should fail
            rc = aether_geo_altitude_engine_predict(engine, -1.0);
            if (rc == 0) {
                std::fprintf(stderr, "altitude_engine_predict: expected negative dt to fail\n");
                ++failed;
            }

            // Null engine should fail
            if (aether_geo_altitude_engine_predict(nullptr, 0.1) == 0) {
                std::fprintf(stderr, "altitude_engine_predict: expected null to fail\n");
                ++failed;
            }
            if (aether_geo_altitude_engine_get_height(nullptr, &h) == 0) {
                std::fprintf(stderr, "altitude_engine_get_height: expected null to fail\n");
                ++failed;
            }

            aether_geo_altitude_engine_destroy(engine);
        }

        // Destroy null should be safe
        aether_geo_altitude_engine_destroy(nullptr);
    }

    if (failed == 0) {
        std::fprintf(stdout, "geo_c_api_test: all tests passed\n");
    } else {
        std::fprintf(stderr, "geo_c_api_test: %d test(s) FAILED\n", failed);
    }
    return failed;
}
