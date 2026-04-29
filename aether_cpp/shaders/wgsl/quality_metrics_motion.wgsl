// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Ported from App/Shaders/QualityMetrics.metal — computeMotionEnergy.
// Frame-to-frame absolute luminance difference. Accumulates into
// `motion_sum`. Pairs with computeBrightnessStats to flag
// "low-light + high motion = motion blur" in the guidance engine.

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
    histogram: array<atomic<u32>, 256>,
};

@group(0) @binding(0) var current_frame: texture_2d<f32>;
@group(0) @binding(1) var previous_frame: texture_2d<f32>;
@group(0) @binding(2) var<storage, read_write> output_buf: QualityMetricsOutput;
@group(0) @binding(3) var<uniform> uniforms: QualityMetricsUniforms;

@compute @workgroup_size(8, 8, 1)
fn computeMotionEnergy(@builtin(global_invocation_id) gid: vec3<u32>) {
    let x = gid.x;
    let y = gid.y;

    if ((x & 3u) != 0u || (y & 3u) != 0u) { return; }
    if (x >= uniforms.width || y >= uniforms.height) { return; }

    let curr = textureLoad(current_frame, vec2<i32>(i32(x), i32(y)), 0);
    let prev = textureLoad(previous_frame, vec2<i32>(i32(x), i32(y)), 0);

    let currLum = 0.299 * curr.r + 0.587 * curr.g + 0.114 * curr.b;
    let prevLum = 0.299 * prev.r + 0.587 * prev.g + 0.114 * prev.b;

    let diff = u32(abs(currLum - prevLum) * 255.0);
    atomicAdd(&output_buf.motion_sum, diff);
}
