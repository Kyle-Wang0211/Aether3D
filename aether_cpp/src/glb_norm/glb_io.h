// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// glb_io — Phase 2 of the client-side GLB normalizer.
//
// parse_glb decodes an input multi-prim GLB into:
//   - a global concatenated mesh (positions/normals/indices already
//     world-space-baked, indices already offset into the global vertex
//     array), and
//   - one ChartInput per source primitive (per-vertex UVs in the local
//     prim order + the prim's already-decoded baseColor RGB atlas).
//
// write_glb takes that InputGlb together with the AtlasMergerResult
// (merged atlas + remapped UVs) and emits a single-prim, single-material
// GLB with explicit metallicFactor=0.0 (else strict viewers default to
// 1.0 → solid black, the headline failure mode this whole pipeline
// exists to avoid).
//
// We use cgltf for parse but hand-roll the GLB writer — the cgltf
// distribution we vendor (third_party/cgltf/cgltf.h) is parser-only;
// cgltf_write.h ships separately upstream and adding it just to emit a
// fixed-shape glTF (one mesh, one prim, one material, one texture, one
// image, four accessors, five bufferViews) is more code than spelling
// the JSON out by hand.
//
// Coordinate / texture conventions:
//   - glTF TEXCOORD_0 origin is top-left, V increases downward; this is
//     the same convention atlas_merger expects, so UVs pass through
//     unchanged in both directions (no V-flip).
//   - cgltf_node_transform_world is folded into vertex positions and
//     normals at parse time, so the output GLB's single node has
//     identity transform (matches Phase 1's render expectations).

#ifndef AETHER_GLB_NORM_GLB_IO_H
#define AETHER_GLB_NORM_GLB_IO_H

#include "atlas_merger.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace aether::glb_norm {

struct InputGlb {
    // One ChartInput per source primitive — feeds atlas_merger directly.
    // charts[i].uvs are in the local vertex order of that primitive.
    std::vector<ChartInput> charts;

    // Global concatenated mesh. positions/normals are interleaved as
    // [x0,y0,z0,x1,y1,z1,...]. Indices reference the global vertex
    // array (per-prim local indices have already been offset by each
    // prim's vertex-range start).
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;

    // (vertex_start, vertex_count) per chart. Lets write_glb stitch
    // merged.remapped_uvs[i] back into the global vertex array.
    std::vector<std::pair<uint32_t, uint32_t>> chart_vertex_ranges;

    // (face_start, face_count) per chart — face_start is the index of
    // the first index triple, NOT the first index. face_count is the
    // number of triangles. The brief defines this for downstream face
    // → chart lookups; write_glb itself doesn't currently use it but
    // the field is part of the documented Phase 2 contract.
    std::vector<std::pair<uint32_t, uint32_t>> chart_face_ranges;

    // Useful for stats reporting on the C ABI side.
    uint32_t input_primitive_count = 0;
    uint32_t input_material_count = 0;
};

// Parse a GLB from in-memory bytes. Returns false and sets *err (if
// non-null) on any failure. On success, `out` is fully populated.
//
// Expected input shape: one or more triangle primitives, each with
// POSITION + NORMAL + TEXCOORD_0 attributes, optional indices, and a
// PBR-metallic-roughness material whose baseColorTexture references an
// embedded PNG/JPEG. Primitives missing TEXCOORD_0 or with non-triangle
// topology are skipped with a logged warning; an input with zero
// usable primitives returns false.
bool parse_glb(const uint8_t* bytes, std::size_t size, InputGlb& out,
               std::string* err);

// Serialize the merged result into a single-primitive GLB. Returns
// false and sets *err on any failure (PNG encode, JSON build, etc.).
//
// The output GLB has exactly one mesh, one primitive, one material
// (metallicFactor=0.0, doubleSided=false, no explicit baseColorFactor),
// one texture, and one embedded PNG image. `merged.output_w/output_h`
// must be populated; positions/normals/indices come from `in`.
bool write_glb(const InputGlb& in, const AtlasMergerResult& merged,
               std::vector<uint8_t>& out_bytes, std::string* err);

}  // namespace aether::glb_norm

#endif  // AETHER_GLB_NORM_GLB_IO_H
