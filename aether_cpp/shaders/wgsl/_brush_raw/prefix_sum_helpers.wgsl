// VENDORED FROM Brush (https://github.com/ArthurBrussee/brush)
// Source: brush/crates/brush-prefix-sum/src/shaders/prefix_sum_helpers.wgsl
// Brush version: v0.3.0 (commit 3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486)
// License: Apache-2.0 — see aether_cpp/third_party/brush/LICENSE
// Math: gSplat reference kernels (3DGS paper, Kerbl et al. 2023)
//
// This file is the RAW unmodified Brush WGSL. Phase 6.3a/b will produce
// ADAPTED versions in the parent shaders/wgsl/ directory with #import
// resolution + bind group layout matching aether_cpp's GPUBufferDesc API.
// The raw file is preserved here for upstream re-pin reproducibility.

@group(0) @binding(0) var<storage, read> input: array<u32>;
@group(0) @binding(1) var<storage, read_write> output: array<u32>;

const THREADS_PER_GROUP: u32 = 512u;

var<workgroup> bucket: array<u32, THREADS_PER_GROUP>;

fn groupScan(id: u32, gi: u32, x: u32) {
    bucket[gi] = x;
    for (var t = 1u; t < THREADS_PER_GROUP; t = t * 2u) {
        workgroupBarrier();
        var temp = bucket[gi];
        if (gi >= t) {
            temp += bucket[gi - t];
        }
        workgroupBarrier();
        bucket[gi] = temp;
    }
    if id < arrayLength(&output) {
        output[id] = bucket[gi];
    }
}
 