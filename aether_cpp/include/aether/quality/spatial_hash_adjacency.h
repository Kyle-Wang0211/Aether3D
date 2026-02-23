// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_SPATIAL_HASH_ADJACENCY_H
#define AETHER_QUALITY_SPATIAL_HASH_ADJACENCY_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace quality {

struct Triangle3f {
    float ax{0.0f};
    float ay{0.0f};
    float az{0.0f};
    float bx{0.0f};
    float by{0.0f};
    float bz{0.0f};
    float cx{0.0f};
    float cy{0.0f};
    float cz{0.0f};
};

// Build adjacency in CSR form. offsets has size triangle_count + 1.
aether::core::Status build_spatial_hash_adjacency(
    const Triangle3f* triangles,
    std::size_t triangle_count,
    float cell_size,
    float epsilon,
    std::vector<std::uint32_t>* out_offsets,
    std::vector<std::uint32_t>* out_neighbors);

// BFS distances over CSR adjacency graph. unreachable = -1.
aether::core::Status bfs_distances(
    const std::uint32_t* offsets,
    const std::uint32_t* neighbors,
    std::size_t triangle_count,
    const std::uint32_t* sources,
    std::size_t source_count,
    int max_hops,
    std::vector<std::int32_t>* out_distances);

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_SPATIAL_HASH_ADJACENCY_H
