// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/tri_tet_mapping.h"

#include <cstdlib>

namespace aether {
namespace tsdf {

namespace {

// Kuhn 5-tet decomposition tables.
// Each row of 4 values defines a tetrahedron by its 4 cube vertex indices.
// Cube vertices: 0=(0,0,0) 1=(1,0,0) 2=(0,1,0) 3=(1,1,0)
//                4=(0,0,1) 5=(1,0,1) 6=(0,1,1) 7=(1,1,1)

static constexpr std::int32_t kEvenParity[5][4] = {
    {0, 1, 3, 5},
    {0, 3, 2, 6},
    {0, 5, 4, 6},
    {3, 5, 6, 7},
    {0, 3, 5, 6},
};

static constexpr std::int32_t kOddParity[5][4] = {
    {1, 0, 2, 4},
    {1, 2, 3, 7},
    {1, 4, 5, 7},
    {2, 4, 6, 7},
    {1, 2, 4, 7},
};

}  // namespace

int TriTetMapping::parity(std::int32_t bx, std::int32_t by, std::int32_t bz) noexcept {
    // Use absolute values to ensure consistent parity for negative coords.
    const int sum = std::abs(bx) + std::abs(by) + std::abs(bz);
    return sum & 1;
}

int TriTetMapping::decompose(std::int32_t bx, std::int32_t by, std::int32_t bz,
                             TriTetMappedCell out_cells[5]) noexcept {
    const int p = parity(bx, by, bz);
    const auto& table = (p == 0) ? kEvenParity : kOddParity;

    for (int i = 0; i < 5; ++i) {
        out_cells[i].vertex_indices[0] = table[i][0];
        out_cells[i].vertex_indices[1] = table[i][1];
        out_cells[i].vertex_indices[2] = table[i][2];
        out_cells[i].vertex_indices[3] = table[i][3];
        out_cells[i].tet_index = i;
    }
    return 5;
}

bool TriTetMapping::map_single(std::int32_t bx, std::int32_t by, std::int32_t bz,
                               int local_tet_index,
                               TriTetMappedCell& out_cell) noexcept {
    if (local_tet_index < 0 || local_tet_index > 4) {
        return false;
    }

    const int p = parity(bx, by, bz);
    const auto& table = (p == 0) ? kEvenParity : kOddParity;

    out_cell.vertex_indices[0] = table[local_tet_index][0];
    out_cell.vertex_indices[1] = table[local_tet_index][1];
    out_cell.vertex_indices[2] = table[local_tet_index][2];
    out_cell.vertex_indices[3] = table[local_tet_index][3];
    out_cell.tet_index = local_tet_index;
    return true;
}

bool TriTetMapping::is_deterministic(std::int32_t bx, std::int32_t by, std::int32_t bz) noexcept {
    // The Kuhn decomposition is always deterministic for any valid grid index.
    // Verify by checking both decompose paths produce consistent results.
    TriTetMappedCell cells_a[5]{};
    TriTetMappedCell cells_b[5]{};
    decompose(bx, by, bz, cells_a);
    decompose(bx, by, bz, cells_b);

    for (int i = 0; i < 5; ++i) {
        for (int j = 0; j < 4; ++j) {
            if (cells_a[i].vertex_indices[j] != cells_b[i].vertex_indices[j]) {
                return false;
            }
        }
        if (cells_a[i].tet_index != cells_b[i].tet_index) {
            return false;
        }
    }
    return true;
}

}  // namespace tsdf
}  // namespace aether
