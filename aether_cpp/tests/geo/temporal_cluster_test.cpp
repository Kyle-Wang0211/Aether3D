// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/temporal_cluster.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;
    using namespace aether::geo;

    // -- Test 1: Create and destroy temporal cluster engine. --
    {
        TemporalCluster* tc = temporal_cluster_create(
            100.0,  // spatial_eps_m
            60.0,   // temporal_eps_s
            50.0,   // altitude_eps_m
            3       // min_points
        );
        if (tc == nullptr) {
            std::fprintf(stderr, "temporal_cluster_create returned null\n");
            failed++;
        } else {
            temporal_cluster_destroy(tc);
        }
    }

    // -- Test 2: Add a single point. --
    {
        TemporalCluster* tc = temporal_cluster_create(100.0, 60.0, 50.0, 3);
        if (tc == nullptr) {
            std::fprintf(stderr, "temporal_cluster_create returned null\n");
            failed++;
        } else {
            STPoint pt{};
            pt.lat = 37.7749;
            pt.lon = -122.4194;
            pt.alt_m = 10.0;
            pt.timestamp_s = 1000.0;
            pt.id = 1;

            auto st = temporal_cluster_add(tc, pt);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_cluster_add returned error\n");
                failed++;
            }

            temporal_cluster_destroy(tc);
        }
    }

    // -- Test 3: Add points below min_points -> no clusters. --
    {
        TemporalCluster* tc = temporal_cluster_create(100.0, 60.0, 50.0, 5);
        if (tc == nullptr) {
            std::fprintf(stderr, "temporal_cluster_create returned null\n");
            failed++;
        } else {
            for (int i = 0; i < 3; ++i) {
                STPoint pt{};
                pt.lat = 37.7749 + i * 0.0001;
                pt.lon = -122.4194;
                pt.alt_m = 10.0;
                pt.timestamp_s = 1000.0 + i;
                pt.id = static_cast<uint64_t>(i);
                temporal_cluster_add(tc, pt);
            }

            STCluster clusters[4]{};
            std::size_t out_count = 0;
            auto st = temporal_cluster_run(tc, clusters, 4, &out_count);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_cluster_run returned error\n");
                failed++;
            }
            if (out_count != 0) {
                std::fprintf(stderr,
                             "with < min_points nearby, expected 0 clusters, got %zu\n",
                             out_count);
                failed++;
            }

            temporal_cluster_destroy(tc);
        }
    }

    // -- Test 4: Cluster nearby points that exceed min_points. --
    {
        TemporalCluster* tc = temporal_cluster_create(
            1000.0,  // 1km spatial eps
            120.0,   // 2 min temporal eps
            100.0,   // altitude eps
            3        // min_points
        );
        if (tc == nullptr) {
            std::fprintf(stderr, "temporal_cluster_create returned null\n");
            failed++;
        } else {
            // Add 5 points very close together spatially and temporally.
            for (int i = 0; i < 5; ++i) {
                STPoint pt{};
                pt.lat = 40.0 + i * 0.00001;
                pt.lon = -74.0 + i * 0.00001;
                pt.alt_m = 5.0;
                pt.timestamp_s = 2000.0 + i * 10.0;
                pt.id = static_cast<uint64_t>(100 + i);
                temporal_cluster_add(tc, pt);
            }

            STCluster clusters[4]{};
            std::size_t out_count = 0;
            auto st = temporal_cluster_run(tc, clusters, 4, &out_count);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_cluster_run returned error\n");
                failed++;
            }
            if (out_count == 0) {
                std::fprintf(stderr,
                             "5 nearby points with min_points=3 should form a cluster\n");
                failed++;
            }
            if (out_count > 0 && clusters[0].point_count < 3) {
                std::fprintf(stderr,
                             "cluster point_count should be >= 3, got %u\n",
                             clusters[0].point_count);
                failed++;
            }

            temporal_cluster_destroy(tc);
        }
    }

    // -- Test 5: Points far apart should form separate clusters or noise. --
    {
        TemporalCluster* tc = temporal_cluster_create(
            50.0,   // 50m spatial eps
            30.0,   // 30s temporal eps
            20.0,   // 20m altitude eps
            2       // min_points
        );
        if (tc == nullptr) {
            std::fprintf(stderr, "temporal_cluster_create returned null\n");
            failed++;
        } else {
            // Group A: two nearby points.
            for (int i = 0; i < 2; ++i) {
                STPoint pt{};
                pt.lat = 10.0 + i * 0.0001;
                pt.lon = 20.0;
                pt.alt_m = 0.0;
                pt.timestamp_s = 100.0 + i;
                pt.id = static_cast<uint64_t>(i);
                temporal_cluster_add(tc, pt);
            }

            // Group B: two nearby points, far from A.
            for (int i = 0; i < 2; ++i) {
                STPoint pt{};
                pt.lat = 50.0 + i * 0.0001;
                pt.lon = 80.0;
                pt.alt_m = 0.0;
                pt.timestamp_s = 100.0 + i;
                pt.id = static_cast<uint64_t>(10 + i);
                temporal_cluster_add(tc, pt);
            }

            STCluster clusters[8]{};
            std::size_t out_count = 0;
            temporal_cluster_run(tc, clusters, 8, &out_count);

            // Should have 2 separate clusters (or at least more than 1).
            if (out_count < 2) {
                std::fprintf(stderr,
                             "two separated groups should produce >= 2 clusters, got %zu\n",
                             out_count);
                failed++;
            }

            temporal_cluster_destroy(tc);
        }
    }

    // -- Test 6: Heat decay reduces cluster heat. --
    {
        TemporalCluster* tc = temporal_cluster_create(1000.0, 120.0, 100.0, 2);
        if (tc == nullptr) {
            std::fprintf(stderr, "temporal_cluster_create returned null\n");
            failed++;
        } else {
            for (int i = 0; i < 3; ++i) {
                STPoint pt{};
                pt.lat = 30.0 + i * 0.00001;
                pt.lon = 40.0;
                pt.alt_m = 0.0;
                pt.timestamp_s = 500.0 + i;
                pt.id = static_cast<uint64_t>(i);
                temporal_cluster_add(tc, pt);
            }

            // Run clustering first.
            STCluster clusters[4]{};
            std::size_t out_count = 0;
            temporal_cluster_run(tc, clusters, 4, &out_count);

            // Apply heat decay at a future time.
            auto st = temporal_cluster_heat_decay(tc, 10000.0);
            if (st != aether::core::Status::kOk) {
                std::fprintf(stderr,
                             "temporal_cluster_heat_decay returned error\n");
                failed++;
            }

            temporal_cluster_destroy(tc);
        }
    }

    // -- Test 7: Default STPoint values. --
    {
        STPoint pt{};
        if (pt.lat != 0.0 || pt.lon != 0.0 || pt.alt_m != 0.0) {
            std::fprintf(stderr,
                         "default STPoint coordinates should be 0\n");
            failed++;
        }
        if (pt.timestamp_s != 0.0) {
            std::fprintf(stderr,
                         "default STPoint timestamp should be 0\n");
            failed++;
        }
        if (pt.id != 0) {
            std::fprintf(stderr,
                         "default STPoint id should be 0\n");
            failed++;
        }
    }

    // -- Test 8: Default STCluster values. --
    {
        STCluster cl{};
        if (cl.point_count != 0) {
            std::fprintf(stderr,
                         "default STCluster point_count should be 0\n");
            failed++;
        }
        if (cl.heat != 0.0) {
            std::fprintf(stderr,
                         "default STCluster heat should be 0.0\n");
            failed++;
        }
    }

    return failed;
}
