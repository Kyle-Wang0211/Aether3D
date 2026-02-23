// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/rtree.h"
#include "aether/geo/haversine.h"
#include "aether/core/status.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main() {
    int failed = 0;

    // Test 1: Create and destroy
    {
        auto* tree = aether::geo::rtree_create();
        if (!tree) { std::fprintf(stderr, "rtree_create returned null\n"); ++failed; }
        else {
            if (aether::geo::rtree_size(tree) != 0) {
                std::fprintf(stderr, "new tree size != 0\n"); ++failed;
            }
            aether::geo::rtree_destroy(tree);
        }
    }

    // Test 2: Insert + range query
    {
        auto* tree = aether::geo::rtree_create();
        aether::geo::RTreeEntry e{};
        e.lat = 51.5074; e.lon = -0.1278; e.id = 1; e.score = 1.0f;
        aether::geo::rtree_insert(tree, e);
        e.lat = 48.8566; e.lon = 2.3522; e.id = 2;
        aether::geo::rtree_insert(tree, e);
        e.lat = 40.7128; e.lon = -74.0060; e.id = 3;
        aether::geo::rtree_insert(tree, e);

        if (aether::geo::rtree_size(tree) != 3) {
            std::fprintf(stderr, "after 3 inserts, size = %zu\n", aether::geo::rtree_size(tree));
            ++failed;
        }

        // Query Europe
        aether::geo::MBR range{40.0, 55.0, -5.0, 10.0};
        aether::geo::RTreeEntry results[10];
        std::size_t count = 0;
        auto s = aether::geo::rtree_query_range(tree, range, results, 10, &count);
        if (s != aether::core::Status::kOk || count != 2) {
            std::fprintf(stderr, "range query Europe: status=%d count=%zu expected 2\n",
                         static_cast<int>(s), count);
            ++failed;
        }

        aether::geo::rtree_destroy(tree);
    }

    // Test 3: Remove
    {
        auto* tree = aether::geo::rtree_create();
        for (int i = 0; i < 10; ++i) {
            aether::geo::RTreeEntry e{};
            e.lat = 50.0 + i * 0.1;
            e.lon = 10.0 + i * 0.1;
            e.id = static_cast<std::uint64_t>(i);
            aether::geo::rtree_insert(tree, e);
        }
        auto s = aether::geo::rtree_remove(tree, 5);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "remove id=5 failed\n"); ++failed;
        }
        if (aether::geo::rtree_size(tree) != 9) {
            std::fprintf(stderr, "after remove, size=%zu expected 9\n", aether::geo::rtree_size(tree));
            ++failed;
        }
        s = aether::geo::rtree_remove(tree, 99);
        if (s != aether::core::Status::kOutOfRange) {
            std::fprintf(stderr, "remove nonexistent: expected kOutOfRange\n"); ++failed;
        }
        aether::geo::rtree_destroy(tree);
    }

    // Test 4: kNN query
    {
        auto* tree = aether::geo::rtree_create();
        struct City { double lat; double lon; const char* name; };
        City cities[] = {
            {51.5074, -0.1278, "London"},
            {48.8566, 2.3522, "Paris"},
            {52.5200, 13.4050, "Berlin"},
            {41.9028, 12.4964, "Rome"},
            {40.4168, -3.7038, "Madrid"},
        };
        for (int i = 0; i < 5; ++i) {
            aether::geo::RTreeEntry e{};
            e.lat = cities[i].lat;
            e.lon = cities[i].lon;
            e.id = static_cast<std::uint64_t>(i);
            aether::geo::rtree_insert(tree, e);
        }

        // Find 3 nearest to Brussels (50.85, 4.35)
        aether::geo::KNNResult knn[3];
        std::size_t knn_count = 0;
        auto s = aether::geo::rtree_query_knn(tree, 50.85, 4.35, 3, knn, &knn_count);
        if (s != aether::core::Status::kOk || knn_count != 3) {
            std::fprintf(stderr, "knn: status=%d count=%zu expected 3\n",
                         static_cast<int>(s), knn_count);
            ++failed;
        }
        // Nearest should be Paris or London (both ~300 km from Brussels)
        if (knn_count >= 1 && knn[0].distance_m > 400000.0) {
            std::fprintf(stderr, "knn[0] distance %.0f > 400km\n", knn[0].distance_m);
            ++failed;
        }
        // Results should be sorted
        if (knn_count >= 2 && knn[0].distance_m > knn[1].distance_m) {
            std::fprintf(stderr, "knn not sorted\n"); ++failed;
        }

        aether::geo::rtree_destroy(tree);
    }

    // Test 5: Large random insert + brute-force kNN verification
    {
        auto* tree = aether::geo::rtree_create();
        static constexpr int N = 1000;
        std::vector<aether::geo::RTreeEntry> all(N);
        std::srand(42);

        for (int i = 0; i < N; ++i) {
            all[i].lat = -90.0 + 180.0 * (std::rand() / static_cast<double>(RAND_MAX));
            all[i].lon = -180.0 + 360.0 * (std::rand() / static_cast<double>(RAND_MAX));
            all[i].id = static_cast<std::uint64_t>(i);
            all[i].score = 1.0f;
            aether::geo::rtree_insert(tree, all[i]);
        }

        if (aether::geo::rtree_size(tree) != N) {
            std::fprintf(stderr, "large insert size=%zu expected %d\n",
                         aether::geo::rtree_size(tree), N);
            ++failed;
        }

        // kNN brute-force verification
        double qlat = 30.0, qlon = 60.0;
        std::size_t k = 5;
        aether::geo::KNNResult tree_results[5];
        std::size_t tree_count = 0;
        aether::geo::rtree_query_knn(tree, qlat, qlon, k, tree_results, &tree_count);

        // Compute brute-force
        struct BF { double dist; std::uint64_t id; };
        std::vector<BF> brute(N);
        for (int i = 0; i < N; ++i) {
            brute[i].dist = aether::geo::distance_haversine(qlat, qlon, all[i].lat, all[i].lon);
            brute[i].id = all[i].id;
        }
        std::partial_sort(brute.begin(), brute.begin() + static_cast<std::ptrdiff_t>(k), brute.end(),
            [](const BF& a, const BF& b) { return a.dist < b.dist; });

        for (std::size_t i = 0; i < k && i < tree_count; ++i) {
            if (std::fabs(tree_results[i].distance_m - brute[i].dist) > 1.0) {
                std::fprintf(stderr, "kNN[%zu] tree=%.1f brute=%.1f\n",
                             i, tree_results[i].distance_m, brute[i].dist);
                ++failed;
            }
        }

        aether::geo::rtree_destroy(tree);
    }

    // Test 6: Bulk load
    {
        auto* tree = aether::geo::rtree_create();
        static constexpr int N = 500;
        std::vector<aether::geo::RTreeEntry> entries(N);
        std::srand(123);
        for (int i = 0; i < N; ++i) {
            entries[i].lat = -80.0 + 160.0 * (std::rand() / static_cast<double>(RAND_MAX));
            entries[i].lon = -170.0 + 340.0 * (std::rand() / static_cast<double>(RAND_MAX));
            entries[i].id = static_cast<std::uint64_t>(i);
            entries[i].score = 1.0f;
        }
        auto s = aether::geo::rtree_bulk_load(tree, entries.data(), N);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "bulk_load failed\n"); ++failed;
        }
        if (aether::geo::rtree_size(tree) != N) {
            std::fprintf(stderr, "bulk_load size=%zu expected %d\n",
                         aether::geo::rtree_size(tree), N);
            ++failed;
        }

        // Verify range query still works
        aether::geo::MBR range{-10, 10, -10, 10};
        std::size_t count = 0;
        aether::geo::rtree_query_range(tree, range, nullptr, 0, &count);
        // Should find some entries near the equator
        // (count verification — just check it doesn't crash)

        aether::geo::rtree_destroy(tree);
    }

    // Test 7: MBR operations
    {
        aether::geo::MBR a{10, 20, 30, 40};
        aether::geo::MBR b{15, 25, 35, 45};
        auto u = aether::geo::mbr_union(a, b);
        if (u.lat_min != 10 || u.lat_max != 25 || u.lon_min != 30 || u.lon_max != 45) {
            std::fprintf(stderr, "mbr_union incorrect\n"); ++failed;
        }
        if (!a.contains(15, 35)) { std::fprintf(stderr, "contains failed\n"); ++failed; }
        if (a.contains(25, 35)) { std::fprintf(stderr, "contains false positive\n"); ++failed; }
        if (!a.intersects(b)) { std::fprintf(stderr, "intersects failed\n"); ++failed; }
        aether::geo::MBR c{50, 60, 50, 60};
        if (a.intersects(c)) { std::fprintf(stderr, "intersects false positive\n"); ++failed; }
    }

    return failed;
}
