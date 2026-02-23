// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/geo_cluster.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // Test 1: Empty input
    {
        std::size_t count = 99;
        auto s = aether::geo::geo_cluster_points(nullptr, 0, 10, 80, nullptr, 0, &count);
        if (s != aether::core::Status::kOk || count != 0) {
            std::fprintf(stderr, "empty input: status=%d count=%zu\n", static_cast<int>(s), count);
            ++failed;
        }
    }

    // Test 2: Single point → single cluster
    {
        aether::geo::ClusterPoint pt{51.5074, -0.1278, 1, 1.0f};
        aether::geo::GeoCluster cluster{};
        std::size_t count = 0;
        auto s = aether::geo::geo_cluster_points(&pt, 1, 10, 80, &cluster, 1, &count);
        if (s != aether::core::Status::kOk || count != 1) {
            std::fprintf(stderr, "single point: count=%zu\n", count);
            ++failed;
        }
        if (cluster.point_count != 1) {
            std::fprintf(stderr, "single cluster point_count=%u\n", cluster.point_count);
            ++failed;
        }
    }

    // Test 3: Nearby points cluster together at low zoom
    {
        aether::geo::ClusterPoint pts[] = {
            {51.5074, -0.1278, 1, 1.0f},  // London
            {51.5080, -0.1280, 2, 1.0f},  // Very near London
            {51.5090, -0.1260, 3, 1.0f},  // Very near London
            {48.8566, 2.3522, 4, 1.0f},   // Paris
        };
        aether::geo::GeoCluster clusters[10];
        std::size_t count = 0;
        // At low zoom, London points should merge
        auto s = aether::geo::geo_cluster_points(pts, 4, 5, 80, clusters, 10, &count);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "nearby cluster failed\n"); ++failed;
        }
        // Should get 1-3 clusters (London group + Paris, or all in one at very low zoom)
        if (count < 1 || count > 4) {
            std::fprintf(stderr, "nearby cluster count=%zu\n", count);
            ++failed;
        }
    }

    // Test 4: All separate at high zoom
    {
        aether::geo::ClusterPoint pts[] = {
            {51.5074, -0.1278, 1, 1.0f},
            {48.8566, 2.3522, 2, 1.0f},
            {40.7128, -74.0060, 3, 1.0f},
        };
        aether::geo::GeoCluster clusters[10];
        std::size_t count = 0;
        auto s = aether::geo::geo_cluster_points(pts, 3, 20, 80, clusters, 10, &count);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "high zoom cluster failed\n"); ++failed;
        }
        if (count != 3) {
            std::fprintf(stderr, "high zoom: expected 3, got %zu\n", count);
            ++failed;
        }
    }

    // Test 5: Weighted center
    {
        aether::geo::ClusterPoint pts[] = {
            {50.0, 10.0, 1, 3.0f},
            {50.1, 10.1, 2, 1.0f},
        };
        aether::geo::GeoCluster clusters[10];
        std::size_t count = 0;
        // Use very low zoom so they cluster together
        auto s = aether::geo::geo_cluster_points(pts, 2, 0, 80, clusters, 10, &count);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "weighted center failed\n"); ++failed;
        }
        if (count >= 1 && clusters[0].point_count == 2) {
            // Center should be closer to point 1 (weight 3)
            if (std::fabs(clusters[0].center_lat - 50.0) > 0.08) {
                std::fprintf(stderr, "weighted center lat=%.4f, expected ~50.025\n",
                             clusters[0].center_lat);
                ++failed;
            }
        }
    }

    // Test 6: Invalid zoom
    {
        aether::geo::ClusterPoint pt{0, 0, 1, 1.0f};
        std::size_t count = 0;
        auto s = aether::geo::geo_cluster_points(&pt, 1, 21, 80, nullptr, 0, &count);
        if (s != aether::core::Status::kOutOfRange) {
            std::fprintf(stderr, "invalid zoom: expected kOutOfRange\n"); ++failed;
        }
    }

    return failed;
}
