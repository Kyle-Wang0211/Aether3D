// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// mesh_simplify — Phase 3 of the client-side GLB normalizer.
//
// Wraps zeux/meshoptimizer's quadric-error simplifier. Operates on a
// single chart's submesh in-place: positions / normals / uvs / indices
// all shrink to the simplified vertex set, with indices kept dense
// (consecutive [0, N) into the surviving vertex array).
//
// We pass meshopt_SimplifyLockBorder so chart-boundary vertices stay
// pinned — per-chart simplification then doesn't introduce cracks where
// adjacent charts meet (the natural failure mode of option A in the
// Phase 3 brief). If the lock turns out to be too conservative on the
// user's test scale, escalate to meshopt_simplifyWithAttributes (option
// B in the brief, single global pass with UV-continuity weight).

#ifndef AETHER_GLB_NORM_MESH_SIMPLIFY_H
#define AETHER_GLB_NORM_MESH_SIMPLIFY_H

#include <cstdint>
#include <vector>

namespace aether::glb_norm {

// Simplify a single chart's submesh in place.
//
// Inputs are flat arrays in chart-local index space:
//   positions: [3*N] floats, [x0,y0,z0,x1,y1,z1,...]
//   normals:   [3*N] floats, same layout (may be empty if chart had none)
//   uvs:       [2*N] floats, [u0,v0,u1,v1,...]
//   indices:   [3*M] uint32, references into the chart-local vertex array
//
// On return, positions / normals / uvs / indices are all repacked to
// only contain surviving vertices, with indices remapped to the new
// dense [0, N') vertex range.
//
// target_face_count is the desired triangle count after simplification.
// The simplifier may stop short if topology constraints (locked borders,
// degeneracies) prevent reaching it — `indices.size() / 3` after the
// call is the actual face count.
//
// target_error is the per-chart relative error tolerance in [0,1]. The
// simplifier walks edges in quadric-error order until it either hits
// target_face_count or all remaining collapses would exceed
// target_error * mesh_extent. 0.01 (= 1% of bounding-box diagonal) is
// the meshoptimizer-recommended visually-imperceptible default.
//
// Returns true on success. Returns false (leaves inputs untouched) if
// inputs are inconsistent (e.g. positions.size() % 3 != 0, indices not
// a triangle list, normals/uvs sized inconsistently with positions).
bool simplify_chart_inplace(std::vector<float>& positions,
                            std::vector<uint32_t>& indices,
                            std::vector<float>& normals,
                            std::vector<float>& uvs,
                            uint32_t target_face_count,
                            float target_error = 0.01f);

}  // namespace aether::glb_norm

#endif  // AETHER_GLB_NORM_MESH_SIMPLIFY_H
