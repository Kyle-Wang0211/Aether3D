// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/asc_cell.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // Test 1: Hilbert roundtrip at order 15
    {
        std::uint32_t x = 12345, y = 23456;
        std::uint64_t d = aether::geo::xy_to_hilbert(x, y, 15);
        std::uint32_t rx = 0, ry = 0;
        aether::geo::hilbert_to_xy(d, 15, &rx, &ry);
        if (rx != x || ry != y) {
            std::fprintf(stderr, "hilbert roundtrip: (%u,%u) -> %llu -> (%u,%u)\n",
                         x, y, (unsigned long long)d, rx, ry);
            ++failed;
        }
    }

    // Test 2: latlon → cell → latlon roundtrip (London)
    {
        const double lat = 51.5074, lon = -0.1278;
        std::uint64_t cell = 0;
        auto s = aether::geo::latlon_to_cell(lat, lon, 15, &cell);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "latlon_to_cell London failed\n");
            ++failed;
        } else {
            double rlat = 0, rlon = 0;
            s = aether::geo::cell_to_latlon(cell, &rlat, &rlon);
            if (s != aether::core::Status::kOk) {
                std::fprintf(stderr, "cell_to_latlon London failed\n");
                ++failed;
            }
            // At level 15, cell edge ≈ 153m → center should be within ~200m
            double dlat = std::fabs(rlat - lat);
            double dlon = std::fabs(rlon - lon);
            if (dlat > 0.01 || dlon > 0.01) {
                std::fprintf(stderr, "roundtrip London: lat err %.6f, lon err %.6f\n", dlat, dlon);
                ++failed;
            }
        }
    }

    // Test 3: Multiple points on different faces
    {
        struct TestPt { double lat; double lon; const char* name; };
        TestPt points[] = {
            {0.0, 0.0, "Null Island"},
            {90.0, 0.0, "North Pole"},
            {-90.0, 0.0, "South Pole"},
            {0.0, 90.0, "Indian Ocean"},
            {0.0, -90.0, "Ecuador"},
            {0.0, 180.0, "Intl Date Line"},
            {35.6762, 139.6503, "Tokyo"},
            {-33.8688, 151.2093, "Sydney"},
        };
        for (const auto& pt : points) {
            std::uint64_t cell = 0;
            auto s = aether::geo::latlon_to_cell(pt.lat, pt.lon, 10, &cell);
            if (s != aether::core::Status::kOk) {
                std::fprintf(stderr, "latlon_to_cell %s failed\n", pt.name);
                ++failed;
                continue;
            }
            double rlat = 0, rlon = 0;
            s = aether::geo::cell_to_latlon(cell, &rlat, &rlon);
            if (s != aether::core::Status::kOk) {
                std::fprintf(stderr, "cell_to_latlon %s failed\n", pt.name);
                ++failed;
                continue;
            }
            // Level 10: each cell ≈ 153 * 32 ≈ 4.9 km → allow ~0.2° error
            // At poles (|lat|>89), longitude is undefined so we only check latitude
            bool ok = true;
            if (std::fabs(pt.lat) > 89.0) {
                ok = std::fabs(rlat - pt.lat) < 0.5;  // relaxed tolerance at poles
            } else {
                ok = std::fabs(rlat - pt.lat) < 0.2 && std::fabs(rlon - pt.lon) < 0.2;
            }
            if (!ok) {
                std::fprintf(stderr, "roundtrip %s: (%.4f,%.4f) → (%.4f,%.4f)\n",
                             pt.name, pt.lat, pt.lon, rlat, rlon);
                ++failed;
            }
        }
    }

    // Test 4: Face extraction
    {
        std::uint64_t cell = 0;
        aether::geo::latlon_to_cell(0.0, 0.0, 15, &cell);
        std::uint32_t face = aether::geo::cell_face(cell);
        if (face >= 6) {
            std::fprintf(stderr, "face out of range: %u\n", face);
            ++failed;
        }
    }

    // Test 5: Level extraction
    {
        for (std::uint32_t lv = 0; lv <= 15; ++lv) {
            std::uint64_t cell = 0;
            aether::geo::latlon_to_cell(45.0, 90.0, lv, &cell);
            if (aether::geo::cell_level(cell) != lv) {
                std::fprintf(stderr, "level mismatch at %u\n", lv);
                ++failed;
            }
        }
    }

    // Test 6: Parent relationship
    {
        std::uint64_t cell = 0;
        aether::geo::latlon_to_cell(51.5074, -0.1278, 15, &cell);
        std::uint64_t parent = aether::geo::cell_parent(cell);
        if (aether::geo::cell_level(parent) != 14) {
            std::fprintf(stderr, "parent level: expected 14, got %u\n",
                         aether::geo::cell_level(parent));
            ++failed;
        }
        // Parent's face should be same as child's
        if (aether::geo::cell_face(parent) != aether::geo::cell_face(cell)) {
            std::fprintf(stderr, "parent face != child face\n");
            ++failed;
        }
    }

    // Test 7: Out-of-range level
    {
        std::uint64_t cell = 0;
        auto s = aether::geo::latlon_to_cell(0, 0, 16, &cell);
        if (s != aether::core::Status::kOutOfRange) {
            std::fprintf(stderr, "level 16: expected kOutOfRange\n");
            ++failed;
        }
    }

    // Test 8: Spatio-temporal cell
    {
        aether::geo::AetherSTCellId stid{};
        auto s = aether::geo::latlon_to_st_cell(51.5074, -0.1278, 15,
                                                 1700000000.0, 3600, &stid);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "st_cell creation failed\n");
            ++failed;
        }
        if (stid.spatial == 0) {
            std::fprintf(stderr, "st_cell spatial is zero\n");
            ++failed;
        }
        if (stid.temporal_bucket != 1700000000u / 3600u) {
            std::fprintf(stderr, "st_cell bucket: expected %u, got %u\n",
                         1700000000u / 3600u, stid.temporal_bucket);
            ++failed;
        }
    }

    // Test 9: Hilbert order-1 known values
    {
        // Order 1 Hilbert curve: (0,0)→0, (1,0)→1, (1,1)→2, (0,1)→3
        // Actually the standard Hilbert for order 1 is:
        // d=0 → (0,0), d=1 → (0,1), d=2 → (1,1), d=3 → (1,0)
        // Let's verify roundtrip for all 4
        for (std::uint64_t d = 0; d < 4; ++d) {
            std::uint32_t x = 0, y = 0;
            aether::geo::hilbert_to_xy(d, 1, &x, &y);
            std::uint64_t d2 = aether::geo::xy_to_hilbert(x, y, 1);
            if (d2 != d) {
                std::fprintf(stderr, "hilbert order-1: d=%llu → (%u,%u) → %llu\n",
                             (unsigned long long)d, x, y, (unsigned long long)d2);
                ++failed;
            }
        }
    }

    return failed;
}
