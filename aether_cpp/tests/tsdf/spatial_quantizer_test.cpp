// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/spatial_quantizer.h"

#include <cmath>
#include <cstdint>
#include <cstdio>

namespace {

bool approx(float a, float b, float eps = 1e-5f) {
    return std::fabs(a - b) <= eps;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    // -----------------------------------------------------------------------
    // Test 1: Morton code roundtrip with known values.
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_coords[][3] = {
            {0, 0, 0},
            {1, 0, 0},
            {0, 1, 0},
            {0, 0, 1},
            {1, 1, 1},
            {10, 20, 30},
            {255, 255, 255},
            {1000, 2000, 500},
            {0, 0, (1 << 21) - 1},  // max 21-bit value
            {(1 << 21) - 1, (1 << 21) - 1, (1 << 21) - 1},
        };

        for (const auto& tc : test_coords) {
            const std::uint64_t code = SpatialQuantizer::morton_encode(tc[0], tc[1], tc[2]);
            std::int32_t dx = 0;
            std::int32_t dy = 0;
            std::int32_t dz = 0;
            SpatialQuantizer::morton_decode(code, dx, dy, dz);

            // Mask to 21 bits for comparison (encode only uses lower 21 bits).
            const std::int32_t mask = (1 << 21) - 1;
            if ((dx & mask) != (tc[0] & mask) ||
                (dy & mask) != (tc[1] & mask) ||
                (dz & mask) != (tc[2] & mask)) {
                std::fprintf(stderr,
                    "morton roundtrip failed for (%d, %d, %d): got (%d, %d, %d)\n",
                    tc[0], tc[1], tc[2], dx, dy, dz);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 2: Morton code matches loop-based reference implementation.
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_coords[][3] = {
            {5, 10, 15},
            {100, 200, 300},
            {42, 0, 99},
        };

        for (const auto& tc : test_coords) {
            // Compute with old loop-based method.
            std::uint64_t ref_code = 0u;
            (void)morton_encode_21bit(tc[0], tc[1], tc[2], &ref_code);

            // Compute with new efficient method.
            const std::uint64_t fast_code = SpatialQuantizer::morton_encode(tc[0], tc[1], tc[2]);

            if (ref_code != fast_code) {
                std::fprintf(stderr,
                    "morton encode mismatch for (%d, %d, %d): ref=0x%llx fast=0x%llx\n",
                    tc[0], tc[1], tc[2],
                    static_cast<unsigned long long>(ref_code),
                    static_cast<unsigned long long>(fast_code));
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 3: Z-order curve locality property.
    // Nearby grid cells should have closer Morton codes than distant cells.
    // -----------------------------------------------------------------------
    {
        const std::uint64_t code_origin = SpatialQuantizer::morton_encode(100, 100, 100);
        const std::uint64_t code_near = SpatialQuantizer::morton_encode(101, 100, 100);
        const std::uint64_t code_far = SpatialQuantizer::morton_encode(200, 200, 200);

        // We can't guarantee |near-origin| < |far-origin| in all cases for Z-curve,
        // but for these specific coords the near one should differ by less.
        const std::uint64_t diff_near = (code_near > code_origin)
            ? (code_near - code_origin) : (code_origin - code_near);
        const std::uint64_t diff_far = (code_far > code_origin)
            ? (code_far - code_origin) : (code_origin - code_far);

        if (diff_near >= diff_far) {
            std::fprintf(stderr,
                "Z-curve locality: near diff (%llu) should be < far diff (%llu)\n",
                static_cast<unsigned long long>(diff_near),
                static_cast<unsigned long long>(diff_far));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 4: Morton code of origin is 0.
    // -----------------------------------------------------------------------
    {
        const std::uint64_t code = SpatialQuantizer::morton_encode(0, 0, 0);
        if (code != 0u) {
            std::fprintf(stderr, "morton_encode(0,0,0) should be 0, got %llu\n",
                static_cast<unsigned long long>(code));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 5: SpatialQuantizer quantize + world_position roundtrip.
    // -----------------------------------------------------------------------
    {
        SpatialQuantizer sq{};
        sq.origin_x = -5.0f;
        sq.origin_y = -5.0f;
        sq.origin_z = -5.0f;
        sq.cell_size = 0.1f;

        const float test_points[][3] = {
            {0.0f, 0.0f, 0.0f},
            {1.5f, 2.3f, -3.7f},
            {-5.0f, -5.0f, -5.0f},
            {4.95f, 4.95f, 4.95f},
        };

        for (const auto& pt : test_points) {
            std::int32_t gx = 0;
            std::int32_t gy = 0;
            std::int32_t gz = 0;
            sq.quantize(pt[0], pt[1], pt[2], gx, gy, gz);

            float wx = 0.0f;
            float wy = 0.0f;
            float wz = 0.0f;
            sq.world_position(gx, gy, gz, wx, wy, wz);

            // The world position should be within one cell_size of the original.
            if (std::fabs(wx - pt[0]) > sq.cell_size ||
                std::fabs(wy - pt[1]) > sq.cell_size ||
                std::fabs(wz - pt[2]) > sq.cell_size) {
                std::fprintf(stderr,
                    "quantize roundtrip too far for (%.2f, %.2f, %.2f): got (%.2f, %.2f, %.2f)\n",
                    pt[0], pt[1], pt[2], wx, wy, wz);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 6: SpatialQuantizer morton_code convenience.
    // -----------------------------------------------------------------------
    {
        SpatialQuantizer sq{};
        sq.origin_x = 0.0f;
        sq.origin_y = 0.0f;
        sq.origin_z = 0.0f;
        sq.cell_size = 1.0f;

        const std::uint64_t code = sq.morton_code(3.5f, 7.2f, 1.9f);
        std::int32_t gx = 0;
        std::int32_t gy = 0;
        std::int32_t gz = 0;
        sq.quantize(3.5f, 7.2f, 1.9f, gx, gy, gz);
        const std::uint64_t expected = SpatialQuantizer::morton_encode(gx, gy, gz);

        if (code != expected) {
            std::fprintf(stderr,
                "morton_code convenience mismatch: got %llu expected %llu\n",
                static_cast<unsigned long long>(code),
                static_cast<unsigned long long>(expected));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 7: world_position returns center of cell.
    // -----------------------------------------------------------------------
    {
        SpatialQuantizer sq{};
        sq.origin_x = 0.0f;
        sq.origin_y = 0.0f;
        sq.origin_z = 0.0f;
        sq.cell_size = 2.0f;

        float wx = 0.0f;
        float wy = 0.0f;
        float wz = 0.0f;
        sq.world_position(0, 0, 0, wx, wy, wz);

        // Cell 0 with size 2.0 should have center at 1.0.
        if (!approx(wx, 1.0f) || !approx(wy, 1.0f) || !approx(wz, 1.0f)) {
            std::fprintf(stderr,
                "world_position center: expected (1.0, 1.0, 1.0) got (%.4f, %.4f, %.4f)\n",
                wx, wy, wz);
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 8: Morton encode single-axis bits.
    // x=1 should set bit 0, y=1 should set bit 1, z=1 should set bit 2.
    // -----------------------------------------------------------------------
    {
        const std::uint64_t cx = SpatialQuantizer::morton_encode(1, 0, 0);
        const std::uint64_t cy = SpatialQuantizer::morton_encode(0, 1, 0);
        const std::uint64_t cz = SpatialQuantizer::morton_encode(0, 0, 1);

        if (cx != 1u) {
            std::fprintf(stderr, "morton_encode(1,0,0) should be 1, got %llu\n",
                static_cast<unsigned long long>(cx));
            ++failed;
        }
        if (cy != 2u) {
            std::fprintf(stderr, "morton_encode(0,1,0) should be 2, got %llu\n",
                static_cast<unsigned long long>(cy));
            ++failed;
        }
        if (cz != 4u) {
            std::fprintf(stderr, "morton_encode(0,0,1) should be 4, got %llu\n",
                static_cast<unsigned long long>(cz));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 9: Hilbert code roundtrip with known values.
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_coords[][3] = {
            {0, 0, 0},
            {1, 0, 0},
            {0, 1, 0},
            {0, 0, 1},
            {1, 1, 1},
            {10, 20, 30},
            {255, 255, 255},
            {1000, 2000, 500},
            {0, 0, (1 << 21) - 1},  // max 21-bit value
            {(1 << 21) - 1, (1 << 21) - 1, (1 << 21) - 1},
            {7, 3, 5},
            {123, 456, 789},
            {(1 << 21) - 1, 0, 0},
            {0, (1 << 21) - 1, 0},
        };

        for (const auto& tc : test_coords) {
            const std::uint64_t code = SpatialQuantizer::hilbert_encode(tc[0], tc[1], tc[2]);
            std::int32_t dx = 0;
            std::int32_t dy = 0;
            std::int32_t dz = 0;
            SpatialQuantizer::hilbert_decode(code, dx, dy, dz);

            const std::int32_t mask = (1 << 21) - 1;
            if ((dx & mask) != (tc[0] & mask) ||
                (dy & mask) != (tc[1] & mask) ||
                (dz & mask) != (tc[2] & mask)) {
                std::fprintf(stderr,
                    "hilbert roundtrip failed for (%d, %d, %d): got (%d, %d, %d)\n",
                    tc[0], tc[1], tc[2], dx, dy, dz);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 10: Hilbert encode of origin (0,0,0) maps to code 0.
    // -----------------------------------------------------------------------
    {
        const std::uint64_t code = SpatialQuantizer::hilbert_encode(0, 0, 0);
        if (code != 0u) {
            std::fprintf(stderr, "hilbert_encode(0,0,0) should be 0, got %llu\n",
                static_cast<unsigned long long>(code));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 11: Hilbert code preserves spatial locality better than Morton.
    // For a set of spatially adjacent cells, measure the average code
    // distance.  Hilbert should have smaller average distance than Morton.
    // -----------------------------------------------------------------------
    {
        // Compute average absolute code difference for the 6 face-adjacent
        // neighbors of a center cell, comparing Hilbert vs. Morton.
        const std::int32_t cx = 500;
        const std::int32_t cy = 500;
        const std::int32_t cz = 500;
        const std::int32_t neighbors[][3] = {
            {cx + 1, cy, cz}, {cx - 1, cy, cz},
            {cx, cy + 1, cz}, {cx, cy - 1, cz},
            {cx, cy, cz + 1}, {cx, cy, cz - 1},
        };

        const std::uint64_t h_center = SpatialQuantizer::hilbert_encode(cx, cy, cz);
        const std::uint64_t m_center = SpatialQuantizer::morton_encode(cx, cy, cz);

        std::uint64_t h_sum = 0u;
        std::uint64_t m_sum = 0u;
        for (const auto& nb : neighbors) {
            const std::uint64_t hc = SpatialQuantizer::hilbert_encode(nb[0], nb[1], nb[2]);
            const std::uint64_t mc = SpatialQuantizer::morton_encode(nb[0], nb[1], nb[2]);
            h_sum += (hc > h_center) ? (hc - h_center) : (h_center - hc);
            m_sum += (mc > m_center) ? (mc - m_center) : (m_center - mc);
        }

        // Hilbert curve should have better (smaller) average distance for
        // face-adjacent cells than Morton/Z-order.
        if (h_sum >= m_sum) {
            std::fprintf(stderr,
                "hilbert locality: avg hilbert dist (%llu) should be < morton dist (%llu)\n",
                static_cast<unsigned long long>(h_sum),
                static_cast<unsigned long long>(m_sum));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 12: Hilbert codes are unique for distinct coordinates (small grid).
    // Verify no collisions in an 8x8x8 cube.
    // -----------------------------------------------------------------------
    {
        // Use a simple array to store codes and check uniqueness.
        constexpr int side = 8;
        constexpr int total = side * side * side;
        std::uint64_t codes[total];
        int idx = 0;
        for (int x = 0; x < side; ++x) {
            for (int y = 0; y < side; ++y) {
                for (int z = 0; z < side; ++z) {
                    codes[idx++] = SpatialQuantizer::hilbert_encode(x, y, z);
                }
            }
        }

        // Check all pairs for uniqueness (brute force for small grid).
        bool dup_found = false;
        for (int i = 0; i < total && !dup_found; ++i) {
            for (int j = i + 1; j < total && !dup_found; ++j) {
                if (codes[i] == codes[j]) {
                    std::fprintf(stderr,
                        "hilbert uniqueness: duplicate code %llu at indices %d and %d\n",
                        static_cast<unsigned long long>(codes[i]), i, j);
                    ++failed;
                    dup_found = true;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 13: All 21-bit values are valid (max coordinate roundtrip).
    // -----------------------------------------------------------------------
    {
        const std::int32_t max_val = (1 << 21) - 1;
        const std::int32_t edge_coords[][3] = {
            {max_val, 0, 0},
            {0, max_val, 0},
            {0, 0, max_val},
            {max_val, max_val, 0},
            {max_val, 0, max_val},
            {0, max_val, max_val},
            {max_val, max_val, max_val},
        };

        for (const auto& ec : edge_coords) {
            const std::uint64_t code = SpatialQuantizer::hilbert_encode(ec[0], ec[1], ec[2]);
            std::int32_t dx = 0;
            std::int32_t dy = 0;
            std::int32_t dz = 0;
            SpatialQuantizer::hilbert_decode(code, dx, dy, dz);

            if (dx != ec[0] || dy != ec[1] || dz != ec[2]) {
                std::fprintf(stderr,
                    "hilbert max-value roundtrip failed for (%d, %d, %d): got (%d, %d, %d)\n",
                    ec[0], ec[1], ec[2], dx, dy, dz);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 14: Hilbert code differs from Morton code (they are different
    // space-filling curves and should produce different orderings).
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_coords[][3] = {
            {1, 2, 3},
            {10, 20, 30},
            {100, 200, 300},
        };

        for (const auto& tc : test_coords) {
            const std::uint64_t hcode = SpatialQuantizer::hilbert_encode(tc[0], tc[1], tc[2]);
            const std::uint64_t mcode = SpatialQuantizer::morton_encode(tc[0], tc[1], tc[2]);
            if (hcode == mcode) {
                std::fprintf(stderr,
                    "hilbert and morton should differ for (%d, %d, %d): both = %llu\n",
                    tc[0], tc[1], tc[2],
                    static_cast<unsigned long long>(hcode));
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 15: SpatialQuantizer hilbert_code convenience matches manual
    // quantize + hilbert_encode.
    // -----------------------------------------------------------------------
    {
        SpatialQuantizer sq{};
        sq.origin_x = 0.0f;
        sq.origin_y = 0.0f;
        sq.origin_z = 0.0f;
        sq.cell_size = 1.0f;

        const std::uint64_t code = sq.hilbert_code(3.5f, 7.2f, 1.9f);
        std::int32_t gx = 0;
        std::int32_t gy = 0;
        std::int32_t gz = 0;
        sq.quantize(3.5f, 7.2f, 1.9f, gx, gy, gz);
        const std::uint64_t expected = SpatialQuantizer::hilbert_encode(gx, gy, gz);

        if (code != expected) {
            std::fprintf(stderr,
                "hilbert_code convenience mismatch: got %llu expected %llu\n",
                static_cast<unsigned long long>(code),
                static_cast<unsigned long long>(expected));
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 16: Hilbert code with negative grid coordinates (lower 21 bits).
    // Negative integers when masked to 21 bits should roundtrip correctly.
    // -----------------------------------------------------------------------
    {
        const std::int32_t neg_coords[][3] = {
            {-1, 0, 0},
            {0, -1, 0},
            {0, 0, -1},
            {-1, -1, -1},
            {-100, -200, -50},
        };

        const std::int32_t mask = (1 << 21) - 1;
        for (const auto& nc : neg_coords) {
            const std::int32_t ex = nc[0] & mask;
            const std::int32_t ey = nc[1] & mask;
            const std::int32_t ez = nc[2] & mask;

            const std::uint64_t code = SpatialQuantizer::hilbert_encode(nc[0], nc[1], nc[2]);
            std::int32_t dx = 0;
            std::int32_t dy = 0;
            std::int32_t dz = 0;
            SpatialQuantizer::hilbert_decode(code, dx, dy, dz);

            if (dx != ex || dy != ey || dz != ez) {
                std::fprintf(stderr,
                    "hilbert negative roundtrip: input (%d, %d, %d) masked (%d, %d, %d) got (%d, %d, %d)\n",
                    nc[0], nc[1], nc[2], ex, ey, ez, dx, dy, dz);
                ++failed;
            }
        }
    }

    return failed;
}
