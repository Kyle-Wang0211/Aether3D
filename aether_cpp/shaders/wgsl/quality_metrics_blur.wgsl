// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Ported from App/Shaders/QualityMetrics.metal — computeBlurScore.
// Tenengrad Sobel gradient magnitude on the green channel. Higher
// accumulated score = sharper image. Subsamples every 2 pixels to
// match the Metal original exactly.
//
// Workgroup size: 8x8 — gives good occupancy on A14 / Snapdragon 8 Gen 2.
// Bindings:
//   @group(0) @binding(0) input_tex   : texture_storage_2d<rgba8unorm, read>
//   @group(0) @binding(1) output_buf  : atomic storage { gradient_sum, pixel_count, ... }
//   @group(0) @binding(2) uniforms    : QualityMetricsUniforms
//
// NOTE: the output layout uses plain atomic<u32> fields to match the
// Metal struct's atomic_uint members. The WGSL struct must be kept in
// lockstep with the Dart/Swift mirror struct's field order and size.

struct QualityMetricsUniforms {
    width: u32,
    height: u32,
    blur_normalization: f32,
    brightness_threshold: f32,
};

struct QualityMetricsOutput {
    gradient_sum: atomic<u32>,
    pixel_count: atomic<u32>,
    brightness_sum: atomic<u32>,
    dark_pixel_count: atomic<u32>,
    motion_sum: atomic<u32>,
    // Histogram bins 0..255 — atomic so every pixel in-flight can
    // increment its bucket independently.
    histogram: array<atomic<u32>, 256>,
};

@group(0) @binding(0) var input_tex: texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> output_buf: QualityMetricsOutput;
@group(0) @binding(2) var<uniform> uniforms: QualityMetricsUniforms;

@compute @workgroup_size(8, 8, 1)
fn computeBlurScore(@builtin(global_invocation_id) gid: vec3<u32>) {
    let x = gid.x;
    let y = gid.y;

    // Border skip + 2x subsample — identical predicate to Metal.
    if (x < 1u || y < 1u ||
        x >= uniforms.width - 1u || y >= uniforms.height - 1u ||
        (x & 1u) != 0u || (y & 1u) != 0u) {
        return;
    }

    // 3x3 green-channel read (highest SNR).
    let tl = textureLoad(input_tex, vec2<i32>(i32(x) - 1, i32(y) - 1), 0).g;
    let tc = textureLoad(input_tex, vec2<i32>(i32(x),     i32(y) - 1), 0).g;
    let tr = textureLoad(input_tex, vec2<i32>(i32(x) + 1, i32(y) - 1), 0).g;
    let ml = textureLoad(input_tex, vec2<i32>(i32(x) - 1, i32(y)),     0).g;
    let mr = textureLoad(input_tex, vec2<i32>(i32(x) + 1, i32(y)),     0).g;
    let bl = textureLoad(input_tex, vec2<i32>(i32(x) - 1, i32(y) + 1), 0).g;
    let bc = textureLoad(input_tex, vec2<i32>(i32(x),     i32(y) + 1), 0).g;
    let br = textureLoad(input_tex, vec2<i32>(i32(x) + 1, i32(y) + 1), 0).g;

    // Sobel kernels — identical to Metal.
    let gx = -tl + tr - 2.0 * ml + 2.0 * mr - bl + br;
    let gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;

    // Squared magnitude, fixed-point cast (matches Metal scaling by
    // 65536).
    let mag = clamp((gx * gx + gy * gy) * 65536.0, 0.0, 4294967295.0);
    atomicAdd(&output_buf.gradient_sum, u32(mag));
    atomicAdd(&output_buf.pixel_count, 1u);
}
