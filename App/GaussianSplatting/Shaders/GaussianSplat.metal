// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GaussianSplat.metal
// Aether3D
//
// GPU shaders for 3D Gaussian Splatting rendering.
// Algorithm sources:
//   - gsplat.js RenderProgram.ts: EWA projection, eigendecomposition
//   - Spark (World Labs): PackedSplat decoding, GPU distance sort
//
// Pipeline:
//   1. computeSplatDepths   — decode float16 center → view-space depth
//   2. radixSortGPU         — stable GPU 4-pass radix sort by depth
//   3. splatVertex          — EWA projection → instanced quad
//   4. splatFragment        — Gaussian alpha evaluation
//   5. Blending             — back-to-front premultiplied src-over

#include <metal_stdlib>
#include "GaussianSplatTypes.h"

using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// Utility: float16 decode, sRGB→linear, octahedral decode
// ═══════════════════════════════════════════════════════════════════════

/// sRGB byte → linear float.
inline float srgb_to_linear(uint8_t srgb) {
    float s = float(srgb) / 255.0;
    return (s <= 0.04045) ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
}

/// Decode float16 → float.
inline float decode_half(uint16_t h) {
    return float(as_type<half>(h));
}

/// Decode octahedral unit vector from 2 bytes.
inline float3 octahedral_decode(uint8_t u_byte, uint8_t v_byte) {
    float ox = float(u_byte) / 255.0 * 2.0 - 1.0;
    float oy = float(v_byte) / 255.0 * 2.0 - 1.0;

    float az = 1.0 - abs(ox) - abs(oy);
    float ax, ay;
    if (az >= 0.0) {
        ax = ox;
        ay = oy;
    } else {
        ax = (1.0 - abs(oy)) * (ox >= 0.0 ? 1.0 : -1.0);
        ay = (1.0 - abs(ox)) * (oy >= 0.0 ? 1.0 : -1.0);
    }
    return normalize(float3(ax, ay, az));
}

/// Decode log-encoded scale byte → positive scale.
inline float decode_log_scale(uint8_t encoded) {
    float normalized = float(encoded) / 255.0;
    return exp(normalized * 16.0 - 8.0);
}

/// Decode quaternion from octahedral axis + angle.
inline float4 decode_quaternion(uint8_t uv0, uint8_t uv1, uint8_t angle_byte) {
    float3 axis = octahedral_decode(uv0, uv1);
    float theta = float(angle_byte) * (M_PI_2_F / 255.0);
    float sin_t = sin(theta);
    return float4(cos(theta), axis.x * sin_t, axis.y * sin_t, axis.z * sin_t);
}

/// Convert float to sortable uint32 (IEEE 754 bit trick).
inline uint float_to_sortable(float f) {
    uint bits = as_type<uint>(f);
    uint mask = -int(bits >> 31) | 0x80000000;
    return bits ^ mask;
}

/// Quaternion → 3x3 rotation matrix.
inline float3x3 quat_to_matrix(float4 q) {
    float w = q.x, x = q.y, y = q.z, z = q.w;
    float xx = x*x, yy = y*y, zz = z*z;
    float xy = x*y, xz = x*z, yz = y*z;
    float wx = w*x, wy = w*y, wz = w*z;

    return float3x3(
        float3(1.0 - 2.0*(yy+zz), 2.0*(xy+wz),     2.0*(xz-wy)),
        float3(2.0*(xy-wz),        1.0 - 2.0*(xx+zz), 2.0*(yz+wx)),
        float3(2.0*(xz+wy),        2.0*(yz-wx),       1.0 - 2.0*(xx+yy))
    );
}

// ═══════════════════════════════════════════════════════════════════════
// 1. Compute Splat Depths
// ═══════════════════════════════════════════════════════════════════════
// Decode float16 center from PackedSplat → transform to view space → depth.

kernel void computeSplatDepths(
    device const PackedSplatGPU* splats   [[buffer(0)]],
    constant SplatCameraUniforms& camera  [[buffer(1)]],
    device uint* depth_keys               [[buffer(2)]],
    device uint* indices                  [[buffer(3)]],
    uint gid                              [[thread_position_in_grid]])
{
    if (gid >= camera.splatCount) return;

    // Decode position from float16
    float px = decode_half(splats[gid].center[0]);
    float py = decode_half(splats[gid].center[1]);
    float pz = decode_half(splats[gid].center[2]);
    float4 worldPos = float4(px, py, pz, 1.0);

    // Transform to view space
    float4 viewPos = camera.viewMatrix * worldPos;

    // Precompute the sortable 32-bit key once per frame instead of
    // rebuilding it in every radix pass.
    depth_keys[gid] = float_to_sortable(viewPos.z);
    indices[gid] = gid;
}

// ═══════════════════════════════════════════════════════════════════════
// 2. Stable GPU Radix Sort (per-pass)
// ═══════════════════════════════════════════════════════════════════════
// 8-bit radix, 4 passes for 32-bit keys. Each dispatch handles one pass.
// For each pass:
//   1. Build a 256-bin histogram per threadgroup.
//   2. Prefix those histograms into absolute bucket offsets.
//   3. Scatter stably using deterministic in-group ranks.

constant uint NUM_BUCKETS = 256;

/// Compatibility kernel: not used by the stable viewer path anymore.
kernel void radixClearHistogram(
    device atomic_uint* histogram             [[buffer(0)]],
    uint gid                                  [[thread_position_in_grid]])
{
    if (gid < NUM_BUCKETS) {
        atomic_store_explicit(&histogram[gid], 0u, memory_order_relaxed);
    }
}

/// Phase 1: Build a histogram for each threadgroup.
/// Output layout: group_histograms[group_id * 256 + bucket] = count.
kernel void radixHistogram(
    device const uint* depth_keys             [[buffer(0)]],
    device const uint* src_indices            [[buffer(1)]],
    constant SortPassParams& params           [[buffer(2)]],
    device uint* group_histograms             [[buffer(3)]],
    uint gid                                  [[thread_position_in_grid]],
    uint lid                                  [[thread_position_in_threadgroup]],
    uint group_id                             [[threadgroup_position_in_grid]])
{
    threadgroup atomic_uint local_hist[NUM_BUCKETS];
    if (lid < NUM_BUCKETS) {
        atomic_store_explicit(&local_hist[lid], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid < params.totalCount) {
        uint key = depth_keys[src_indices[gid]];
        uint bucket = (key >> params.bitOffset) & 0xFF;
        atomic_fetch_add_explicit(
            &local_hist[bucket], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lid < NUM_BUCKETS) {
        if (group_id < params._pad) {
            group_histograms[group_id * NUM_BUCKETS + lid] =
                atomic_load_explicit(&local_hist[lid], memory_order_relaxed);
        }
    }
}

/// Phase 2: Convert per-threadgroup counts into absolute offsets.
/// Each thread handles one bucket across all threadgroups.
kernel void radixPrefixSum(
    device uint* group_histograms             [[buffer(0)]],
    constant SortPassParams& params           [[buffer(1)]],
    uint lid                                  [[thread_position_in_threadgroup]])
{
    threadgroup uint bucket_starts[NUM_BUCKETS];
    threadgroup uint buf[2][NUM_BUCKETS];

    uint running = 0;
    for (uint group = 0; group < params._pad; ++group) {
        uint idx = group * NUM_BUCKETS + lid;
        uint count = group_histograms[idx];
        group_histograms[idx] = running;
        running += count;
    }

    bucket_starts[lid] = running;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    buf[0][lid] = bucket_starts[lid];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint read_buf = 0u;
    for (uint offset = 1; offset < NUM_BUCKETS; offset *= 2) {
        uint write_buf = 1u - read_buf;
        if (lid >= offset) {
            buf[write_buf][lid] = buf[read_buf][lid] + buf[read_buf][lid - offset];
        } else {
            buf[write_buf][lid] = buf[read_buf][lid];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        read_buf = write_buf;
    }

    if (lid == 0) {
        bucket_starts[0] = 0;
    } else {
        bucket_starts[lid] = buf[read_buf][lid - 1];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint bucket_start = bucket_starts[lid];
    for (uint group = 0; group < params._pad; ++group) {
        uint idx = group * NUM_BUCKETS + lid;
        group_histograms[idx] += bucket_start;
    }
}

/// Phase 3: Scatter elements into the destination buffer.
/// Stability comes from deterministic group order + deterministic local rank.
/// We build per-bucket bitmasks inside the threadgroup, then derive each
/// element's local rank with popcount instead of scanning all prior lanes.
kernel void radixScatter(
    device const uint* depth_keys             [[buffer(0)]],
    device const uint* src_indices            [[buffer(1)]],
    device uint* dst_indices                  [[buffer(2)]],
    constant SortPassParams& params           [[buffer(3)]],
    device const uint* group_offsets          [[buffer(4)]],
    uint gid                                  [[thread_position_in_grid]],
    uint lid                                  [[thread_position_in_threadgroup]],
    uint group_id                             [[threadgroup_position_in_grid]])
{
    constexpr uint WORDS_PER_GROUP = NUM_BUCKETS / 32;
    threadgroup atomic_uint bucket_masks[NUM_BUCKETS * WORDS_PER_GROUP];
    uint bucket = 0;

    if (lid < NUM_BUCKETS) {
        uint base = lid * WORDS_PER_GROUP;
        for (uint word = 0; word < WORDS_PER_GROUP; ++word) {
            atomic_store_explicit(&bucket_masks[base + word], 0u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid < params.totalCount) {
        uint original_idx = src_indices[gid];
        uint key = depth_keys[original_idx];
        bucket = (key >> params.bitOffset) & 0xFF;
        uint word_index = lid >> 5;
        uint bit_mask = 1u << (lid & 31u);
        atomic_fetch_or_explicit(
            &bucket_masks[bucket * WORDS_PER_GROUP + word_index],
            bit_mask,
            memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid >= params.totalCount) return;

    uint original_idx = src_indices[gid];

    uint local_rank = 0;
    uint word_index = lid >> 5;
    uint bucket_base = bucket * WORDS_PER_GROUP;
    for (uint word = 0; word < word_index; ++word) {
        local_rank += popcount(
            atomic_load_explicit(
                &bucket_masks[bucket_base + word],
                memory_order_relaxed));
    }
    uint current_word = atomic_load_explicit(
        &bucket_masks[bucket_base + word_index],
        memory_order_relaxed);
    uint lane_mask = (lid & 31u) == 0u ? 0u : ((1u << (lid & 31u)) - 1u);
    local_rank += popcount(current_word & lane_mask);

    uint pos = group_offsets[group_id * NUM_BUCKETS + bucket] + local_rank;
    dst_indices[pos] = original_idx;
}

// ═══════════════════════════════════════════════════════════════════════
// 3. Splat Vertex Shader (EWA Projection)
// ═══════════════════════════════════════════════════════════════════════
// Source: gsplat.js RenderProgram.ts + Spark GPU sort output.
//
// Each instance is one Gaussian. The vertex shader:
//   1. Decodes PackedSplat → position, rotation, scale, color
//   2. Computes 3D covariance: Σ = (R·S)(R·S)ᵀ
//   3. Projects to 2D via EWA: Σ₂D = J·W·Σ₃D·Wᵀ·Jᵀ
//   4. Eigendecomposes Σ₂D for ellipse parameters
//   5. Outputs instanced quad vertices covering the splat ellipse

struct SplatVertexOutput {
    float4 position [[position]];
    float2 uv;                      // quad UV in [-1, 1]
    float4 color;                   // linear RGBA
    float2 cov_params;              // packed 2D covariance params
    float  inv_det;                 // 1 / det(Sigma2D) for fragment
    float  depth01;                 // clip-space depth remapped to [0, 1]
    float3 cov2d;                   // [a, b, c] upper triangle
};

vertex SplatVertexOutput splatVertex(
    uint vid                              [[vertex_id]],
    uint iid                              [[instance_id]],
    device const PackedSplatGPU* splats   [[buffer(0)]],
    device const uint* sorted_indices     [[buffer(1)]],
    constant SplatCameraUniforms& camera  [[buffer(2)]],
    device const float4* sh_data          [[buffer(3)]],
    device const uchar* region_ids        [[buffer(4)]],
    device const float* region_fade       [[buffer(5)]])
{
    SplatVertexOutput out;
    (void)region_ids;
    (void)region_fade;

    // Get sorted splat index (back-to-front for premultiplied src-over)
    uint splat_idx = sorted_indices[iid];
    device const PackedSplatGPU& splat = splats[splat_idx];

    // ─── Decode PackedSplat ─────────────────────────────────────────
    float3 pos = float3(
        decode_half(splat.center[0]),
        decode_half(splat.center[1]),
        decode_half(splat.center[2])
    );

    // PackedSplat stores sRGB-encoded color (C++ pack_gaussian calls linear_to_srgb_byte).
    // Must decode sRGB → linear for correct gamma-aware blending.
    float3 color_linear = float3(
        srgb_to_linear(splat.rgba[0]),
        srgb_to_linear(splat.rgba[1]),
        srgb_to_linear(splat.rgba[2])
    );
    float opacity = float(splat.rgba[3]) / 255.0;

    // ─── Transform to camera space ─────────────────────────────────
    float4 viewPos = camera.viewMatrix * float4(pos, 1.0);

    // Camera convention: viewPos.z < 0 for objects in front (OpenGL lookAt).
    // Use positive depth for cull and screen projection.
    float depth = -viewPos.z;

    // Near-plane cull (depth > 0 means in front of camera)
    if (depth <= 0.2) {
        out.position = float4(0, 0, -2, 1);  // Behind clip plane
        out.color = float4(0);
        out.depth01 = 1.0f;
        return out;
    }

    float4 quat = decode_quaternion(splat.quat_uv[0], splat.quat_uv[1],
                                     splat.quat_angle);
    float3 scale = float3(
        decode_log_scale(splat.log_scale[0]),
        decode_log_scale(splat.log_scale[1]),
        decode_log_scale(splat.log_scale[2])
    );

    // ─── SH Degree-1 evaluation: view-dependent color ─────────────
    // Reconstruct camera world position from view matrix:
    //   cam_pos = -R^T * t  where R = upper 3x3, t = translation column
    float3 cam_pos = float3(
        -dot(camera.viewMatrix[0].xyz, camera.viewMatrix[3].xyz),
        -dot(camera.viewMatrix[1].xyz, camera.viewMatrix[3].xyz),
        -dot(camera.viewMatrix[2].xyz, camera.viewMatrix[3].xyz)
    );

    float3 view_dir = normalize(pos - cam_pos);

    // SH degree-1 basis functions (real spherical harmonics):
    //   Y_1^{-1}(d) = -sqrt(3/(4π)) * d.y
    //   Y_1^{0}(d)  =  sqrt(3/(4π)) * d.z
    //   Y_1^{+1}(d) = -sqrt(3/(4π)) * d.x
    const float SH_C1 = 0.4886025;  // sqrt(3/(4*pi))
    float3 sh_basis = float3(-view_dir.y, view_dir.z, -view_dir.x) * SH_C1;

    // SH buffer layout: 3 float4 per splat (R/G/B channels)
    //   sh_data[splat_idx*3 + 0].xyz = R channel [b0, b1, b2]
    //   sh_data[splat_idx*3 + 1].xyz = G channel [b0, b1, b2]
    //   sh_data[splat_idx*3 + 2].xyz = B channel [b0, b1, b2]
    uint sh_offset = splat_idx * 3;
    float3 sh_color = float3(
        dot(sh_data[sh_offset + 0].xyz, sh_basis),
        dot(sh_data[sh_offset + 1].xyz, sh_basis),
        dot(sh_data[sh_offset + 2].xyz, sh_basis)
    );

    // Add SH contribution to DC color and clamp to non-negative
    color_linear = max(color_linear + sh_color, float3(0.0));

    float inv_depth = 1.0 / depth;           // positive
    float inv_depth2 = inv_depth * inv_depth;

    // Screen-space center (pinhole projection with positive depth).
    // In this convention, screen Y increases upward (same direction as camera Y).
    float2 screen_center = float2(
        camera.fx * viewPos.x * inv_depth + camera.cx,
        camera.fy * viewPos.y * inv_depth + camera.cy
    );

    // ─── Compute 3D Covariance: Σ = (R·S)(R·S)ᵀ ───────────────────
    float3x3 R = quat_to_matrix(quat);
    float3x3 S = float3x3(
        float3(scale.x, 0, 0),
        float3(0, scale.y, 0),
        float3(0, 0, scale.z)
    );
    float3x3 M = R * S;
    float3x3 sigma3d = M * transpose(M);

    // ─── EWA Projection: Σ₂D = J·W·Σ₃D·Wᵀ·Jᵀ ─────────────────────
    // Jacobian uses inv_tz = 1/viewPos.z (NEGATIVE) to stay consistent with
    // view matrix W having -forward in row 2. This ensures T = J*W produces
    // the same covariance as the standard EWA formulation.
    float inv_tz = -inv_depth;      // = 1/viewPos.z (negative, matches W sign)
    float inv_tz2 = inv_depth2;     // = 1/viewPos.z² (positive)

    float j00 = camera.fx * inv_tz;
    float j02 = -camera.fx * viewPos.x * inv_tz2;
    float j11 = camera.fy * inv_tz;
    float j12 = -camera.fy * viewPos.y * inv_tz2;

    // W = upper-left 3x3 of view matrix (row-major access: w[row][col])
    // Metal float3x3(col0, col1, col2) stores columns, so W[col][row] = V(row, col).
    // To get w[i][j] = V(i, j) we extract elements explicitly:
    float w00 = camera.viewMatrix[0][0], w01 = camera.viewMatrix[1][0], w02 = camera.viewMatrix[2][0];
    float w10 = camera.viewMatrix[0][1], w11 = camera.viewMatrix[1][1], w12 = camera.viewMatrix[2][1];
    float w20 = camera.viewMatrix[0][2], w21 = camera.viewMatrix[1][2], w22 = camera.viewMatrix[2][2];

    // T = J * W (2x3)
    float t00 = j00 * w00 + j02 * w20;
    float t01 = j00 * w01 + j02 * w21;
    float t02 = j00 * w02 + j02 * w22;
    float t10 = j11 * w10 + j12 * w20;
    float t11 = j11 * w11 + j12 * w21;
    float t12 = j11 * w12 + j12 * w22;

    // Σ₂D = T * Σ₃D * Tᵀ
    float s00 = sigma3d[0][0], s01 = sigma3d[0][1], s02 = sigma3d[0][2];
    float s11 = sigma3d[1][1], s12 = sigma3d[1][2], s22 = sigma3d[2][2];

    float m00 = t00*s00 + t01*s01 + t02*s02;
    float m01 = t00*s01 + t01*s11 + t02*s12;
    float m02 = t00*s02 + t01*s12 + t02*s22;
    float m10 = t10*s00 + t11*s01 + t12*s02;
    float m11 = t10*s01 + t11*s11 + t12*s12;
    float m12 = t10*s02 + t11*s12 + t12*s22;

    float c00 = m00*t00 + m01*t01 + m02*t02;
    float c01 = m00*t10 + m01*t11 + m02*t12;
    float c11 = m10*t10 + m11*t11 + m12*t12;

    // Keep the projection path close to the upstream Gaussian renderer:
    // EWA projection + a light low-pass filter, without viewer-specific
    // large-splat suppression, region fading, or heuristic opacity damping.
    float pixel_area = camera.fx * camera.fy * inv_depth2;
    float mip_filter = max(0.3f, 1.0f / sqrt(max(pixel_area, 1e-6f)));
    c00 += mip_filter;
    c11 += mip_filter;

    // ─── Eigendecompose 2x2 for ellipse ─────────────────────────────
    float trace_val = c00 + c11;
    float diff = c00 - c11;
    float disc = sqrt(diff * diff + 4.0 * c01 * c01);
    float lambda1 = max(0.5 * (trace_val + disc), 1e-6);
    float lambda2 = max(0.5 * (trace_val - disc), 1e-6);

    float radius_major = sqrt(lambda1);
    float radius_minor = sqrt(lambda2);

    // 3-sigma radius for quad sizing
    float radius = 3.0 * radius_major;

    // DEBUG: Force minimum radius to verify rendering pipeline works.
    // If splats appear as large colored squares with this enabled,
    // the issue is in covariance projection, not the rendering pipeline.
    // Set to 0.0 to disable, or e.g. 30.0 to force 30-pixel quads.
    const float DEBUG_MIN_RADIUS = 0.0;
    if (DEBUG_MIN_RADIUS > 0.0 && radius < DEBUG_MIN_RADIUS) {
        radius = DEBUG_MIN_RADIUS;
    }

    // Apply only a very light screen-space ceiling to the largest projected
    // splats. This keeps the current "official/plain" renderer direction, but
    // reins in the handful of huge quads that smear broad areas of the frame.
    constexpr float kSoftCeilingStartPx = 80.0f;
    constexpr float kSoftCeilingEndPx = 160.0f;
    constexpr float kSoftCeilingExcessScale = 0.58f;
    if (radius > kSoftCeilingStartPx) {
        float excess = radius - kSoftCeilingStartPx;
        float ceiling_t = clamp(excess /
                                    max(kSoftCeilingEndPx - kSoftCeilingStartPx,
                                        1e-5f),
                                0.0f,
                                1.0f);
        float excess_scale = mix(1.0f, kSoftCeilingExcessScale, ceiling_t);
        float softened_radius = kSoftCeilingStartPx + excess * excess_scale;
        float screen_scale = softened_radius / max(radius, 1e-5f);
        float cov_scale = screen_scale * screen_scale;
        c00 *= cov_scale;
        c01 *= cov_scale;
        c11 *= cov_scale;
        radius_major *= screen_scale;
        radius_minor *= screen_scale;
        radius = softened_radius;
    }

    // Max screen radius cull
    if (radius > 1024.0) {
        out.position = float4(0, 0, -2, 1);
        out.color = float4(0);
        out.depth01 = 1.0f;
        return out;
    }

    // ─── Instanced quad vertices ────────────────────────────────────
    // vid: 0=BL, 1=BR, 2=TL, 3=TR (triangle strip)
    float2 corner = float2(
        (vid & 1) ? 1.0 : -1.0,
        (vid & 2) ? 1.0 : -1.0
    );

    float2 screen_pos = screen_center + corner * radius;

    // Convert to NDC.
    // Screen coords use same Y direction as camera (up = positive),
    // matching Metal NDC where +Y = up.
    float2 ndc = float2(
        screen_pos.x / float(camera.vpWidth) * 2.0 - 1.0,
        screen_pos.y / float(camera.vpHeight) * 2.0 - 1.0
    );

    float4 clip_center = camera.projMatrix * viewPos;
    out.position = float4(ndc * clip_center.w, clip_center.z, clip_center.w);
    out.uv = corner * radius;  // pixel offset from center
    out.depth01 = clamp((clip_center.z / max(clip_center.w, 1e-6f)) * 0.5f + 0.5f,
                        0.0f,
                        1.0f);

    float det = c00 * c11 - c01 * c01;
    if (det <= 1e-10f) {
        out.position = float4(0, 0, -2, 1);
        out.color = float4(0);
        out.depth01 = 1.0f;
        return out;
    }

    out.color = float4(color_linear, opacity);
    out.cov2d = float3(c00, c01, c11);
    out.inv_det = 1.0 / det;
    out.cov_params = float2(radius_major, radius_minor);

    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// 4. Splat Fragment Shader
// ═══════════════════════════════════════════════════════════════════════
// Evaluate Gaussian at pixel position: alpha = opacity * exp(-0.5 * d²)
// where d² = [dx,dy] · Σ⁻¹ · [dx,dy]ᵀ

struct SplatFragmentOutput {
    half4 color [[color(0)]];
};

struct SplatAccumFragmentOutput {
    float4 accum [[color(0)]];
    float reveal [[color(1)]];
};

struct SplatCoreFragmentOutput {
    float4 color [[color(0)]];
    float depth [[color(1)]];
};

struct SplatCompositeVertexOutput {
    float4 position [[position]];
    float2 uv;
};

struct HTGSCoreTailUniforms {
    uint coreLayer;
    uint coreLayerCount;
    float depthEpsilon;
    float _pad;
};

vertex SplatCompositeVertexOutput splatCompositeVertex(uint vid [[vertex_id]]) {
    constexpr float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    constexpr float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    SplatCompositeVertexOutput out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

inline float2 htgs_depth_uv(float4 position,
                            constant SplatCameraUniforms& camera) {
    float2 dims = float2(max(float(camera.vpWidth), 1.0f),
                         max(float(camera.vpHeight), 1.0f));
    return clamp(position.xy / dims, float2(0.0f), float2(1.0f));
}

inline bool htgs_is_occluded_by_core(
    float depth01,
    float2 uv,
    constant HTGSCoreTailUniforms& params,
    texture2d<float> coreDepth0,
    texture2d<float> coreDepth1,
    texture2d<float> coreDepth2,
    texture2d<float> coreDepth3)
{
    constexpr sampler s(address::clamp_to_edge,
                        mag_filter::nearest,
                        min_filter::nearest);

    if (params.coreLayer > 0) {
        float d0 = coreDepth0.sample(s, uv).r;
        if (d0 < 0.9999f && depth01 <= d0 + params.depthEpsilon) return true;
    }
    if (params.coreLayer > 1) {
        float d1 = coreDepth1.sample(s, uv).r;
        if (d1 < 0.9999f && depth01 <= d1 + params.depthEpsilon) return true;
    }
    if (params.coreLayer > 2) {
        float d2 = coreDepth2.sample(s, uv).r;
        if (d2 < 0.9999f && depth01 <= d2 + params.depthEpsilon) return true;
    }
    if (params.coreLayer > 3) {
        float d3 = coreDepth3.sample(s, uv).r;
        if (d3 < 0.9999f && depth01 <= d3 + params.depthEpsilon) return true;
    }
    return false;
}

inline float splat_alpha_threshold(float projected_radius, bool forCore) {
    constexpr float kBaseAlphaThreshold = 1.0f / 255.0f;
    constexpr float kHybridCoreAlphaThreshold = 0.05f;
    constexpr float kLargeSplatThresholdPx = 8.0f;
    constexpr float kHugeSplatThresholdPx = 20.0f;
    float threshold_t = clamp((projected_radius - kLargeSplatThresholdPx) /
                                  max(kHugeSplatThresholdPx - kLargeSplatThresholdPx, 1e-5f),
                              0.0f,
                              1.0f);
    float alpha_threshold = mix(kBaseAlphaThreshold,
                                kHybridCoreAlphaThreshold,
                                threshold_t);
    if (forCore) {
        alpha_threshold = max(alpha_threshold, 0.03f);
    }
    return alpha_threshold;
}

inline float evaluate_splat_alpha(SplatVertexOutput in) {
    float2 d = in.uv;
    float3 cov = in.cov2d;
    float power = -0.5 * (cov.z * d.x * d.x - 2.0 * cov.y * d.x * d.y +
                          cov.x * d.y * d.y) * in.inv_det;
    if (power > 0.0 || power < -4.0) {
        discard_fragment();
    }
    return in.color.a * exp(power);
}

fragment SplatCoreFragmentOutput splatCoreFragmentHTGS(
    SplatVertexOutput in [[stage_in]],
    constant SplatCameraUniforms& camera [[buffer(0)]],
    constant HTGSCoreTailUniforms& params [[buffer(1)]],
    texture2d<float> coreDepth0 [[texture(0)]],
    texture2d<float> coreDepth1 [[texture(1)]],
    texture2d<float> coreDepth2 [[texture(2)]],
    texture2d<float> coreDepth3 [[texture(3)]])
{
    SplatCoreFragmentOutput out;
    float alpha = evaluate_splat_alpha(in);
    float projected_radius = max(in.cov_params.x, in.cov_params.y);
    if (alpha < splat_alpha_threshold(projected_radius, true)) {
        discard_fragment();
    }

    float2 uv = htgs_depth_uv(in.position, camera);
    if (htgs_is_occluded_by_core(in.depth01, uv, params,
                                 coreDepth0, coreDepth1, coreDepth2, coreDepth3)) {
        discard_fragment();
    }

    out.color = float4(in.color.rgb * alpha, alpha);
    out.depth = in.depth01;
    return out;
}

fragment SplatAccumFragmentOutput splatTailFragmentHTGS(
    SplatVertexOutput in [[stage_in]],
    constant SplatCameraUniforms& camera [[buffer(0)]],
    constant HTGSCoreTailUniforms& params [[buffer(1)]],
    texture2d<float> coreDepth0 [[texture(0)]],
    texture2d<float> coreDepth1 [[texture(1)]],
    texture2d<float> coreDepth2 [[texture(2)]],
    texture2d<float> coreDepth3 [[texture(3)]])
{
    SplatAccumFragmentOutput out;
    float alpha = evaluate_splat_alpha(in);
    float projected_radius = max(in.cov_params.x, in.cov_params.y);
    if (alpha < splat_alpha_threshold(projected_radius, false)) {
        discard_fragment();
    }

    float2 uv = htgs_depth_uv(in.position, camera);
    if (htgs_is_occluded_by_core(in.depth01, uv, params,
                                 coreDepth0, coreDepth1, coreDepth2, coreDepth3)) {
        discard_fragment();
    }

    // Tail remains order-independent, but only for fragments that survived
    // the explicitly peeled core layers above.
    float z = clamp(in.depth01, 0.0f, 1.0f);
    float weight = alpha * max(1e-2f, 3e3f * pow(1.0f - z, 3.0f));
    out.accum = float4(in.color.rgb * alpha * weight, alpha * weight);
    out.reveal = alpha;
    return out;
}

inline float4 over_premultiplied(float4 front, float4 back) {
    return float4(front.rgb + (1.0f - front.a) * back.rgb,
                  front.a + (1.0f - front.a) * back.a);
}

fragment float4 splatCompositeFragmentHTGS(
    SplatCompositeVertexOutput in [[stage_in]],
    float4 existingColor [[color(0)]],
    texture2d<float> coreColor0 [[texture(0)]],
    texture2d<float> coreColor1 [[texture(1)]],
    texture2d<float> coreColor2 [[texture(2)]],
    texture2d<float> coreColor3 [[texture(3)]],
    texture2d<float> accumTexture [[texture(4)]],
    texture2d<float> revealTexture [[texture(5)]])
{
    constexpr sampler s(address::clamp_to_edge,
                        mag_filter::nearest,
                        min_filter::nearest);

    float4 core0 = coreColor0.sample(s, in.uv);
    float4 core1 = coreColor1.sample(s, in.uv);
    float4 core2 = coreColor2.sample(s, in.uv);
    float4 core3 = coreColor3.sample(s, in.uv);
    float4 accum = accumTexture.sample(s, in.uv);
    float reveal = revealTexture.sample(s, in.uv).r;

    float4 bg = float4(existingColor.rgb * existingColor.a, existingColor.a);
    float4 core = over_premultiplied(core0,
                  over_premultiplied(core1,
                  over_premultiplied(core2, core3)));

    if (core.a < 1e-5f && accum.a < 1e-5f) {
        return existingColor;
    }

    float coverage = (accum.a > 1e-5f) ? clamp(1.0f - reveal, 0.0f, 1.0f) : 0.0f;
    float3 avgColor = (accum.a > 1e-5f) ? accum.rgb / max(accum.a, 1e-5f) : float3(0.0f);
    float4 tail = float4(avgColor * coverage, coverage);

    float4 finalPremul = over_premultiplied(core, over_premultiplied(tail, bg));
    float3 finalColor = finalPremul.a > 1e-5f ? finalPremul.rgb / finalPremul.a : float3(0.0f);
    return float4(finalColor, finalPremul.a);
}

fragment SplatFragmentOutput splatFragment(
    SplatVertexOutput in [[stage_in]])
{
    SplatFragmentOutput out;

    float2 d = in.uv;  // pixel offset from Gaussian center
    float3 cov = in.cov2d;  // [a, b, c]

    // Mahalanobis distance: d^T · Σ⁻¹ · d
    // For Σ = [[c00, c01], [c01, c11]], the inverse is:
    //   Σ⁻¹ = (1/det) × [[c11, -c01], [-c01, c00]]
    // So d^T·Σ⁻¹·d = (c11·dx² - 2·c01·dx·dy + c00·dy²) / det
    // cov = [c00, c01, c11], so we use cov.z (c11) with dx² and cov.x (c00) with dy²
    float power = -0.5 * (cov.z * d.x * d.x - 2.0 * cov.y * d.x * d.y +
                           cov.x * d.y * d.y) * in.inv_det;

    // Cutoff beyond 3-sigma
    if (power > 0.0 || power < -4.0) {
        // DEBUG: When DEBUG_MIN_RADIUS > 0 in vertex shader, pixels outside
        // the Gaussian radius are still in the quad. Render them as semi-transparent
        // fill so we can see the quad extent. Set to false to disable.
        constexpr bool DEBUG_SHOW_QUAD_FILL = false;
        if (DEBUG_SHOW_QUAD_FILL) {
            out.color = half4(half3(in.color.rgb) * half(0.15), half(0.15));
            return out;
        }
        discard_fragment();
    }

    float alpha = in.color.a * exp(power);

    constexpr float kBaseAlphaThreshold = 1.0f / 255.0f;
    if (alpha < kBaseAlphaThreshold) {
        discard_fragment();
    }

    // Pre-multiplied alpha output
    out.color = half4(half3(in.color.rgb) * half(alpha), half(alpha));
    return out;
}
