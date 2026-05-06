// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// atlas_merger — port of the server-side Python atlas merger
// (worker_object_slam3r_surface_v1/pipeline/atlas_merger.py) to C++.
//
// Operates on already-decoded RGB byte buffers + per-vertex UVs. No
// GLB I/O — Phase 2 wraps cgltf around this. Pure data-structure in,
// pure data-structure out, deterministic given strict FP flags.
//
// The merged atlas + remapped UVs feed the single-prim/single-mat GLB
// emitter that lets Filament/Three.js skip the 5-9 s shader-compile
// chain on per-material baseColor textures (the headline reason this
// pipeline exists).

#ifndef AETHER_GLB_NORM_ATLAS_MERGER_H
#define AETHER_GLB_NORM_ATLAS_MERGER_H

#include <cstdint>
#include <vector>

namespace aether::glb_norm {

// One source chart: per-vertex UVs + the decoded RGB atlas they
// reference. UVs are interleaved [u0,v0,u1,v1,...] in [0,1] with
// (0,0) at top-left of the atlas (image-row convention — V increases
// downward). Phase 2's GLB loader handles glTF V-flip before calling.
struct ChartInput {
    std::vector<float> uvs;
    std::vector<uint8_t> atlas_rgb;   // row-major RGB, 3 bytes/pixel
    int atlas_w = 0;
    int atlas_h = 0;
};

struct AtlasMergerOptions {
    // Target output side. 0 = auto-pick smallest power-of-2 with
    // chart-pixel density ≈ target_utilization, capped at max.
    int target_atlas_size = 0;
    int max_atlas_size = 8192;
    float target_utilization = 0.7f;

    // Edge-replicate dilation around each packed chart, in output
    // pixels. 8 is the Python reference default — covers a 4-tap
    // bilinear filter at any mip level the renderer is likely to
    // sample at (cuts off above mip 3 anyway).
    int edge_dilate_px = 8;
};

struct AtlasMergerResult {
    // Final composited atlas, row-major RGB, 3 bytes/pixel. Side is
    // always a power-of-2 within [1024, max_atlas_size].
    std::vector<uint8_t> output_rgb;
    int output_w = 0;
    int output_h = 0;

    // Per-chart remapped UVs, same shape & ordering as the matching
    // input.uvs entry. All values in [0,1].
    std::vector<std::vector<float>> remapped_uvs;

    int chosen_atlas_size = 0;
    float scale_factor = 1.0f;
};

// Merge `inputs` into a single atlas. Returns true on success.
//
// On failure (no inputs, packing impossible at max_atlas_size, etc.)
// returns false and leaves `result` partially populated for caller
// diagnostics — chosen_atlas_size in particular is set to whatever
// size the auto-picker landed on so callers can surface "atlas would
// need to be ≥ N px to pack, exceeded max_atlas_size".
bool merge_atlases(const std::vector<ChartInput>& inputs,
                   const AtlasMergerOptions& opts,
                   AtlasMergerResult& result);

}  // namespace aether::glb_norm

#endif  // AETHER_GLB_NORM_ATLAS_MERGER_H
