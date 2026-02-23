// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/tri_tet_mapping.h"

#include <cstdio>
#include <cstdint>

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    // -----------------------------------------------------------------------
    // Test 1: decompose always returns 5 tetrahedra.
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_blocks[][3] = {
            {0, 0, 0},
            {1, 0, 0},
            {0, 1, 0},
            {0, 0, 1},
            {1, 1, 1},
            {2, 3, 4},
            {-1, -2, -3},
            {100, 200, 300},
        };

        for (const auto& b : test_blocks) {
            TriTetMappedCell cells[5]{};
            const int count = TriTetMapping::decompose(b[0], b[1], b[2], cells);
            if (count != 5) {
                std::fprintf(stderr,
                    "decompose(%d,%d,%d) returned %d tets, expected 5\n",
                    b[0], b[1], b[2], count);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 2: parity consistency.
    // Parity should be (|bx| + |by| + |bz|) % 2.
    // -----------------------------------------------------------------------
    {
        if (TriTetMapping::parity(0, 0, 0) != 0) {
            std::fprintf(stderr, "parity(0,0,0) should be 0\n");
            ++failed;
        }
        if (TriTetMapping::parity(1, 0, 0) != 1) {
            std::fprintf(stderr, "parity(1,0,0) should be 1\n");
            ++failed;
        }
        if (TriTetMapping::parity(1, 1, 0) != 0) {
            std::fprintf(stderr, "parity(1,1,0) should be 0\n");
            ++failed;
        }
        if (TriTetMapping::parity(1, 1, 1) != 1) {
            std::fprintf(stderr, "parity(1,1,1) should be 1\n");
            ++failed;
        }
        if (TriTetMapping::parity(2, 3, 4) != 1) {
            std::fprintf(stderr, "parity(2,3,4) should be 1\n");
            ++failed;
        }
        // Negative coords: parity(-1, 0, 0) = (1+0+0) % 2 = 1
        if (TriTetMapping::parity(-1, 0, 0) != 1) {
            std::fprintf(stderr, "parity(-1,0,0) should be 1\n");
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 3: vertex indices validity (all must be in 0-7 range).
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_blocks[][3] = {
            {0, 0, 0},
            {1, 1, 1},
            {5, 10, 15},
            {-3, 7, -12},
        };

        for (const auto& b : test_blocks) {
            TriTetMappedCell cells[5]{};
            TriTetMapping::decompose(b[0], b[1], b[2], cells);

            for (int t = 0; t < 5; ++t) {
                for (int v = 0; v < 4; ++v) {
                    const std::int32_t vi = cells[t].vertex_indices[v];
                    if (vi < 0 || vi > 7) {
                        std::fprintf(stderr,
                            "block(%d,%d,%d) tet %d vertex %d out of range: %d\n",
                            b[0], b[1], b[2], t, v, vi);
                        ++failed;
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 4: tet_index values are 0-4.
    // -----------------------------------------------------------------------
    {
        TriTetMappedCell cells[5]{};
        TriTetMapping::decompose(0, 0, 0, cells);

        for (int i = 0; i < 5; ++i) {
            if (cells[i].tet_index != i) {
                std::fprintf(stderr,
                    "tet_index mismatch: expected %d got %d\n",
                    i, cells[i].tet_index);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 5: even parity (0,0,0) first tet should be {0, 1, 3, 5}.
    // -----------------------------------------------------------------------
    {
        TriTetMappedCell cells[5]{};
        TriTetMapping::decompose(0, 0, 0, cells);

        if (cells[0].vertex_indices[0] != 0 ||
            cells[0].vertex_indices[1] != 1 ||
            cells[0].vertex_indices[2] != 3 ||
            cells[0].vertex_indices[3] != 5) {
            std::fprintf(stderr,
                "even parity tet 0 mismatch: got {%d,%d,%d,%d} expected {0,1,3,5}\n",
                cells[0].vertex_indices[0], cells[0].vertex_indices[1],
                cells[0].vertex_indices[2], cells[0].vertex_indices[3]);
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 6: odd parity (1,0,0) first tet should be {1, 0, 2, 4}.
    // -----------------------------------------------------------------------
    {
        TriTetMappedCell cells[5]{};
        TriTetMapping::decompose(1, 0, 0, cells);

        if (cells[0].vertex_indices[0] != 1 ||
            cells[0].vertex_indices[1] != 0 ||
            cells[0].vertex_indices[2] != 2 ||
            cells[0].vertex_indices[3] != 4) {
            std::fprintf(stderr,
                "odd parity tet 0 mismatch: got {%d,%d,%d,%d} expected {1,0,2,4}\n",
                cells[0].vertex_indices[0], cells[0].vertex_indices[1],
                cells[0].vertex_indices[2], cells[0].vertex_indices[3]);
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 7: map_single returns correct tet for valid index.
    // -----------------------------------------------------------------------
    {
        TriTetMappedCell cell{};
        const bool ok = TriTetMapping::map_single(0, 0, 0, 4, cell);
        if (!ok) {
            std::fprintf(stderr, "map_single(0,0,0, 4) should return true\n");
            ++failed;
        }
        // Even parity tet 4: {0, 3, 5, 6}
        if (cell.vertex_indices[0] != 0 ||
            cell.vertex_indices[1] != 3 ||
            cell.vertex_indices[2] != 5 ||
            cell.vertex_indices[3] != 6) {
            std::fprintf(stderr,
                "map_single tet 4 mismatch: got {%d,%d,%d,%d} expected {0,3,5,6}\n",
                cell.vertex_indices[0], cell.vertex_indices[1],
                cell.vertex_indices[2], cell.vertex_indices[3]);
            ++failed;
        }
        if (cell.tet_index != 4) {
            std::fprintf(stderr, "map_single tet_index mismatch: %d != 4\n",
                cell.tet_index);
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 8: map_single returns false for invalid index.
    // -----------------------------------------------------------------------
    {
        TriTetMappedCell cell{};
        if (TriTetMapping::map_single(0, 0, 0, -1, cell)) {
            std::fprintf(stderr, "map_single with index -1 should return false\n");
            ++failed;
        }
        if (TriTetMapping::map_single(0, 0, 0, 5, cell)) {
            std::fprintf(stderr, "map_single with index 5 should return false\n");
            ++failed;
        }
    }

    // -----------------------------------------------------------------------
    // Test 9: is_deterministic returns true for various inputs.
    // -----------------------------------------------------------------------
    {
        const std::int32_t test_blocks[][3] = {
            {0, 0, 0},
            {1, 2, 3},
            {-5, 10, -15},
            {999, 999, 999},
        };

        for (const auto& b : test_blocks) {
            if (!TriTetMapping::is_deterministic(b[0], b[1], b[2])) {
                std::fprintf(stderr,
                    "is_deterministic(%d,%d,%d) should be true\n",
                    b[0], b[1], b[2]);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 10: map_single matches decompose for all 5 tets.
    // -----------------------------------------------------------------------
    {
        const std::int32_t bx = 3;
        const std::int32_t by = 7;
        const std::int32_t bz = 11;

        TriTetMappedCell cells[5]{};
        TriTetMapping::decompose(bx, by, bz, cells);

        for (int i = 0; i < 5; ++i) {
            TriTetMappedCell single{};
            if (!TriTetMapping::map_single(bx, by, bz, i, single)) {
                std::fprintf(stderr,
                    "map_single(%d,%d,%d, %d) failed\n", bx, by, bz, i);
                ++failed;
                continue;
            }
            for (int v = 0; v < 4; ++v) {
                if (single.vertex_indices[v] != cells[i].vertex_indices[v]) {
                    std::fprintf(stderr,
                        "map_single vs decompose mismatch at tet %d vertex %d\n",
                        i, v);
                    ++failed;
                }
            }
            if (single.tet_index != cells[i].tet_index) {
                std::fprintf(stderr,
                    "map_single vs decompose tet_index mismatch at tet %d\n", i);
                ++failed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 11: each tetrahedron uses 4 distinct vertices.
    // -----------------------------------------------------------------------
    {
        TriTetMappedCell cells[5]{};
        TriTetMapping::decompose(0, 0, 0, cells);

        for (int t = 0; t < 5; ++t) {
            for (int a = 0; a < 4; ++a) {
                for (int b = a + 1; b < 4; ++b) {
                    if (cells[t].vertex_indices[a] == cells[t].vertex_indices[b]) {
                        std::fprintf(stderr,
                            "tet %d has duplicate vertex index %d at positions %d and %d\n",
                            t, cells[t].vertex_indices[a], a, b);
                        ++failed;
                    }
                }
            }
        }
    }

    return failed;
}
