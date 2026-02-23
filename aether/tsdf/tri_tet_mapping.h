// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_TRI_TET_MAPPING_H
#define AETHER_TSDF_TRI_TET_MAPPING_H

#ifdef __cplusplus

#include <cstdint>

namespace aether {
namespace tsdf {

// ---------------------------------------------------------------------------
// TriTetMappedCell: a single tetrahedron within a unit cube decomposition.
// vertex_indices are indices into the 8 cube vertices (0-7).
// ---------------------------------------------------------------------------
struct TriTetMappedCell {
    std::int32_t vertex_indices[4]{0, 0, 0, 0};  // 4 vertices of tetrahedron
    std::int32_t tet_index{0};                     // which of the 5 tetrahedra
};

// ---------------------------------------------------------------------------
// TriTetMapping: Kuhn 5-tetrahedron decomposition of a unit cube.
//
// Partitions [0,1]^3 into 5 tetrahedra. Parity = (bx + by + bz) % 2
// determines which of the two topologically consistent decompositions is used.
//
// Cube vertex numbering:
//   0 = (0,0,0)  1 = (1,0,0)  2 = (0,1,0)  3 = (1,1,0)
//   4 = (0,0,1)  5 = (1,0,1)  6 = (0,1,1)  7 = (1,1,1)
//
// Even parity (sum % 2 == 0):
//   Tet 0: {0, 1, 3, 5}   Tet 1: {0, 3, 2, 6}   Tet 2: {0, 5, 4, 6}
//   Tet 3: {3, 5, 6, 7}   Tet 4: {0, 3, 5, 6}
//
// Odd parity (sum % 2 == 1):
//   Tet 0: {1, 0, 2, 4}   Tet 1: {1, 2, 3, 7}   Tet 2: {1, 4, 5, 7}
//   Tet 3: {2, 4, 6, 7}   Tet 4: {1, 2, 4, 7}
// ---------------------------------------------------------------------------
struct TriTetMapping {
    // Compute parity from block index: (bx + by + bz) % 2.
    static int parity(std::int32_t bx, std::int32_t by, std::int32_t bz) noexcept;

    // Get the 5-tet decomposition for a given block.
    // Returns number of tets written (always 5).
    static int decompose(std::int32_t bx, std::int32_t by, std::int32_t bz,
                         TriTetMappedCell out_cells[5]) noexcept;

    // Map a single tetrahedron by local index (0-4).
    // Returns false if local_tet_index is out of range.
    static bool map_single(std::int32_t bx, std::int32_t by, std::int32_t bz,
                           int local_tet_index,
                           TriTetMappedCell& out_cell) noexcept;

    // Check if decomposition is deterministic (always returns true for valid inputs).
    static bool is_deterministic(std::int32_t bx, std::int32_t by, std::int32_t bz) noexcept;
};

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_TRI_TET_MAPPING_H
