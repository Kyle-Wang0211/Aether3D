// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_MESH_FIEDLER_H
#define AETHER_TSDF_MESH_FIEDLER_H

#include <cstddef>
#include <cstdint>

namespace aether {
namespace tsdf {

/// Result of Fiedler value (algebraic connectivity) computation.
///
/// The Fiedler value is λ₂ of the mesh graph Laplacian L = D - A.
///   λ₂ > 0 ⟹ connected graph
///   λ₂ large ⟹ strong connectivity (well-meshed surface)
///
/// Triggered ONLY at S4→S5 transition, not during real-time scanning.
struct FiedlerResult {
    double fiedler_value{0.0};  // λ₂ of mesh Laplacian
    bool computed{false};       // true if computation succeeded
    int iterations_used{0};     // power iteration count used
};

/// Compute the Fiedler value (λ₂) of a mesh graph Laplacian using
/// inverse power iteration with spectral shift.
///
/// Algorithm:
///   1. Build vertex adjacency from triangle indices
///   2. Compute largest eigenvalue λ_max via power iteration on L
///   3. Compute λ₂ via power iteration on (λ_max·I - L), deflating
///      the constant eigenvector v₁ = (1,1,...,1)/√n
///
/// Complexity: O(max_iterations × E) where E = edge count.
///
/// - indices: raw triangle index array (3 per triangle)
/// - index_count: number of indices (must be divisible by 3)
/// - vertex_count: V
/// - max_iterations: upper bound on power iteration steps (default 100)
FiedlerResult compute_fiedler_value(
    const uint32_t* indices,
    std::size_t index_count,
    std::size_t vertex_count,
    int max_iterations = 100);

}  // namespace tsdf
}  // namespace aether

#endif  // AETHER_TSDF_MESH_FIEDLER_H
