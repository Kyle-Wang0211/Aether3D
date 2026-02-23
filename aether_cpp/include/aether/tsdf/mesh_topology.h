// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MESH_TOPOLOGY_H
#define AETHER_TSDF_MESH_TOPOLOGY_H

#include "aether/tsdf/mesh_output.h"
#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

/// Post-processing topology diagnostics for a triangle mesh.
///
/// Uses Euler characteristic: χ = V - E + F.
/// For a genus-0 closed (watertight) surface, χ = 2.
/// Boundary edges (referenced by only 1 triangle) indicate holes.
///
/// This is a DIAGNOSTIC tool, NOT a gate.  Topology defects come from the
/// Marching Cubes algorithm, not from user scanning quality.
struct MeshTopologyDiagnostics {
    int64_t vertex_count{0};         // V
    int64_t edge_count{0};           // E (unique undirected edges)
    int64_t face_count{0};           // F = triangle_count
    int32_t euler_characteristic{0}; // χ = V - E + F
    int32_t expected_euler{2};       // genus-0 closed surface
    bool topology_ok{false};         // χ == expected_euler
    int32_t boundary_edge_count{0};  // edges referenced by only 1 triangle
};

/// Compute topology diagnostics from a triangle mesh.
/// Complexity: O(F) where F = triangle_count.
///
/// Builds an edge set from triangle indices, counting unique edges and
/// boundary edges (edges shared by exactly 1 triangle).
///
/// - triangles: array of MeshTriangle (each has i0, i1, i2)
/// - triangle_count: number of triangles (F)
/// - vertex_count: number of vertices (V)
/// - Returns: MeshTopologyDiagnostics with all fields populated.
MeshTopologyDiagnostics compute_mesh_topology(
    const MeshTriangle* triangles,
    std::size_t triangle_count,
    std::size_t vertex_count);

/// Overload accepting raw index array (3 indices per triangle).
MeshTopologyDiagnostics compute_mesh_topology_from_indices(
    const uint32_t* indices,
    std::size_t index_count,
    std::size_t vertex_count);

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MESH_TOPOLOGY_H
