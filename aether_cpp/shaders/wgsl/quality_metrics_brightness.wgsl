// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Ported from App/Shaders/QualityMetrics.metal — computeBrightnessStats.
// Luminance histogram + mean/variance + dark-pixel count. Subsamples
// every 4 pixels (matches Metal 4x skip), uses BT.601 weights.
//
// Bindings are identical to quality_metrics_blur.wgsl so the two
// kernels can share the same QualityMetricsOutput buffer.

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

@group(0) @binding(0) var input_tex: texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> output_buf: QualityMetricsOutput;
@group(0) @binding(2) var<uniform> uniforms: QualityMetricsUniforms;

@compute @workgroup_size(8, 8, 1)
fn computeBrightnessStats(@builtin(global_invocation_id) gid: vec3<u32>) {
    let x = gid.x;
    let y = gid.y;

    // 4x subsample (every 4th pixel on both axes).
    if ((x & 3u) != 0u || (y & 3u) != 0u) { return; }
    if (x >= uniforms.width || y >= uniforms.height) { return; }

    let px = textureLoad(input_tex, vec2<i32>(i32(x), i32(y)), 0);
    // BT.601 luminance.
    let lum = 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
    let lum_byte = u32(clamp(lum * 255.0, 0.0, 255.0));

    atomicAdd(&output_buf.brightness_sum, lum_byte);
    atomicAdd(&output_buf.pixel_count, 1u);

    let threshold = uniforms.brightness_threshold / 255.0;
    if (lum < threshold) {
        atomicAdd(&output_buf.dark_pixel_count, 1u);
    }

    // Histogram bump.
    atomicAdd(&output_buf.histogram[lum_byte], 1u);
}
