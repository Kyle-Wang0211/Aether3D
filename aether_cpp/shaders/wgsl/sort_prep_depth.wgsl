// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6.4f.2.a — sort_prep_depth.wgsl (Aether3D-original)
//
// Builds the (key, value) pair arrays consumed by Brush's 5-kernel
// radix sort so the per-splat instanced-quad rasterizer
// (splat_render.wgsl) can iterate ProjectedSplat[] in back-to-front
// depth order. Without this, alpha blending under the
// One/OneMinusSrcAlpha "OVER" operator produces wrong colors on
// overlapping splats — the well-known "fizzing" artifact on hair,
// fabric folds, foliage etc.
//
// Why per-splat sort and not per-tile: our viewer rasterizer is
// vertex+fragment + instanced quads (see splat_render.wgsl docstring
// for the 23×-mobile-speedup rationale). The hardware tiles the
// fragment work; we just need the right INSTANCE order. Brush's
// rasterize.wgsl (compute-tile path) sorts on (tile_id<<32 | depth)
// because IT iterates per tile in the kernel. We don't, so a plain
// 32-bit depth-only sort suffices.
//
// The radix sort is unsigned-ascending. We want farthest-first, so
// we encode the key as `~bitcast<u32>(depth)`. For all non-negative
// depths (project_forward.wgsl rejects mean_c.z < 0.01, so we're
// guaranteed > 0), IEEE-754 bits monotonically increase with the
// float value, so bit-flipping yields a key whose ascending order
// reads farthest-to-nearest.
//
// Slots beyond [0, num_visible) get key=0xFFFFFFFFu (sentinels that
// stay at the end of the sort range, but the radix sort only reads
// the first num_visible keys anyway via num_keys_arr[0]) and
// values[i] = i so splat_render.wgsl can safely look up
// splats[values[ii]] for any ii ∈ [0, total_splats); the surrounding
// frame-start clearBuffer on splats_buf guarantees those slots are
// alpha=0 and get discarded.

struct RenderUniforms {
    viewmat: mat4x4<f32>,
    focal: vec2<f32>,
    img_size: vec2<u32>,
    tile_bounds: vec2<u32>,
    pixel_center: vec2<f32>,
    camera_position: vec4<f32>,
    sh_degree: u32,
    num_visible: u32,
    total_splats: u32,
    max_intersects: u32,
    background: vec4<f32>,
}

@group(0) @binding(0) var<storage> uniforms: RenderUniforms;
@group(0) @binding(1) var<storage> depths: array<f32>;
@group(0) @binding(2) var<storage, read_write> num_keys_arr: array<u32>;
@group(0) @binding(3) var<storage, read_write> keys: array<u32>;
@group(0) @binding(4) var<storage, read_write> values: array<u32>;

@compute @workgroup_size(256, 1, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if (i == 0u) {
        num_keys_arr[0] = uniforms.num_visible;
    }
    let total = uniforms.total_splats;
    if (i >= total) { return; }
    values[i] = i;
    let nv = uniforms.num_visible;
    if (i < nv) {
        // ~bitcast: ascending sort → farthest depth first.
        keys[i] = ~bitcast<u32>(depths[i]);
    } else {
        keys[i] = 0xffffffffu;
    }
}
