// VENDORED FROM Brush (https://github.com/ArthurBrussee/brush)
// Source: brush/crates/brush-prefix-sum/src/shaders/prefix_sum_scan_sums.wgsl
// Brush version: v0.3.0 (commit 3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486)
// License: Apache-2.0 — see aether_cpp/third_party/brush/LICENSE
// Math: gSplat reference kernels (3DGS paper, Kerbl et al. 2023)
//
// This file is the RAW unmodified Brush WGSL. Phase 6.3a/b will produce
// ADAPTED versions in the parent shaders/wgsl/ directory with #import
// resolution + bind group layout matching aether_cpp's GPUBufferDesc API.
// The raw file is preserved here for upstream re-pin reproducibility.

#import prefix_sum_helpers as helpers

@compute
@workgroup_size(helpers::THREADS_PER_GROUP, 1, 1)
fn main(
    @builtin(global_invocation_id) id: vec3u, 
    @builtin(local_invocation_index) gid: u32,
) {
    let idx = id.x * helpers::THREADS_PER_GROUP - 1u;
    
    var x = 0u;
    if (idx >= 0u && idx < arrayLength(&helpers::input)) {
        x = helpers::input[idx];
    }
 
    helpers::groupScan(id.x, gid, x);
}
