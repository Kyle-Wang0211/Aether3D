// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityMetrics.metal
// Aether3D
//
// GPU compute shaders for frame quality analysis.
// Replaces CPU-only blur/exposure/motion detection with Metal compute.
// ~0.2ms per metric on A14 (vs ~2ms on CPU).
//
// Kernels:
//   1. computeBlurScore      — Tenengrad gradient magnitude (noise-robust)
//   2. computeBrightnessStats — Luminance histogram + mean/variance
//   3. computeMotionEnergy   — Frame-to-frame pixel difference

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// Shared Types
// ═══════════════════════════════════════════════════════════════════════

struct QualityMetricsUniforms {
    uint width;
    uint height;
    float blur_normalization;    // Scale factor for blur score
    float brightness_threshold;  // Low-light threshold (e.g., 50/255)
};

struct QualityMetricsOutput {
    atomic_uint gradient_sum;       // Tenengrad gradient accumulator
    atomic_uint pixel_count;        // Number of pixels sampled
    atomic_uint brightness_sum;     // Sum of luminance values
    atomic_uint dark_pixel_count;   // Pixels below threshold
    atomic_uint motion_sum;         // Sum of frame-to-frame differences
    uint histogram[256];            // Luminance histogram
};

// ═══════════════════════════════════════════════════════════════════════
// Kernel 1: Blur Detection (Tenengrad)
// ═══════════════════════════════════════════════════════════════════════
// Computes Sobel gradient magnitude on green channel.
// More noise-robust than Laplacian variance.
// Higher score = sharper image.

kernel void computeBlurScore(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device QualityMetricsOutput& output [[buffer(0)]],
    constant QualityMetricsUniforms& uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Skip border pixels and subsample (every 2nd pixel for speed)
    if (gid.x < 1 || gid.y < 1 ||
        gid.x >= uniforms.width - 1 || gid.y >= uniforms.height - 1 ||
        (gid.x & 1) != 0 || (gid.y & 1) != 0) return;

    // Read 3x3 neighborhood (green channel = highest SNR)
    float tl = inputTexture.read(uint2(gid.x - 1, gid.y - 1)).g;
    float tc = inputTexture.read(uint2(gid.x,     gid.y - 1)).g;
    float tr = inputTexture.read(uint2(gid.x + 1, gid.y - 1)).g;
    float ml = inputTexture.read(uint2(gid.x - 1, gid.y)).g;
    float mr = inputTexture.read(uint2(gid.x + 1, gid.y)).g;
    float bl = inputTexture.read(uint2(gid.x - 1, gid.y + 1)).g;
    float bc = inputTexture.read(uint2(gid.x,     gid.y + 1)).g;
    float br = inputTexture.read(uint2(gid.x + 1, gid.y + 1)).g;

    // Sobel Gx
    float gx = -tl + tr - 2*ml + 2*mr - bl + br;
    // Sobel Gy
    float gy = -tl - 2*tc - tr + bl + 2*bc + br;

    // Gradient magnitude (squared, avoid sqrt for speed)
    uint gradient = uint(clamp((gx*gx + gy*gy) * 65536.0, 0.0, 4294967295.0));

    atomic_fetch_add_explicit(&output.gradient_sum, gradient, memory_order_relaxed);
    atomic_fetch_add_explicit(&output.pixel_count, 1, memory_order_relaxed);
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 2: Brightness Statistics
// ═══════════════════════════════════════════════════════════════════════
// Computes mean brightness, dark pixel count, and luminance histogram.
// Used for low-light detection and exposure quality assessment.

kernel void computeBrightnessStats(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device QualityMetricsOutput& output [[buffer(0)]],
    constant QualityMetricsUniforms& uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Subsample every 4th pixel
    if ((gid.x & 3) != 0 || (gid.y & 3) != 0) return;
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;

    float4 pixel = inputTexture.read(gid);

    // Luminance: 0.299R + 0.587G + 0.114B (BT.601)
    float luminance = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
    uint lum_byte = uint(clamp(luminance * 255.0, 0.0, 255.0));

    atomic_fetch_add_explicit(&output.brightness_sum, lum_byte, memory_order_relaxed);
    atomic_fetch_add_explicit(&output.pixel_count, 1, memory_order_relaxed);

    // Dark pixel detection
    float threshold = uniforms.brightness_threshold / 255.0;
    if (luminance < threshold) {
        atomic_fetch_add_explicit(&output.dark_pixel_count, 1, memory_order_relaxed);
    }

    // Histogram (atomic increment of bin)
    atomic_fetch_add_explicit(
        (device atomic_uint*)&output.histogram[lum_byte], 1, memory_order_relaxed);
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 3: Motion Energy
// ═══════════════════════════════════════════════════════════════════════
// Computes absolute pixel difference between current and previous frame.
// High motion energy + low light = motion blur risk.

kernel void computeMotionEnergy(
    texture2d<float, access::read> currentFrame [[texture(0)]],
    texture2d<float, access::read> previousFrame [[texture(1)]],
    device QualityMetricsOutput& output [[buffer(0)]],
    constant QualityMetricsUniforms& uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Subsample every 4th pixel
    if ((gid.x & 3) != 0 || (gid.y & 3) != 0) return;
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;

    float4 curr = currentFrame.read(gid);
    float4 prev = previousFrame.read(gid);

    // Absolute difference (luminance)
    float currLum = 0.299 * curr.r + 0.587 * curr.g + 0.114 * curr.b;
    float prevLum = 0.299 * prev.r + 0.587 * prev.g + 0.114 * prev.b;

    uint diff = uint(abs(currLum - prevLum) * 255.0);
    atomic_fetch_add_explicit(&output.motion_sum, diff, memory_order_relaxed);
}
