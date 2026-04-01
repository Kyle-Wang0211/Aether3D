// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GaussianTraining.metal
// Aether3D
//
// Metal compute kernels for on-device 3DGS training.
//
// Architecture: Per-pixel tile dispatch (16×16 threadgroups) with cooperative
// Gaussian loading from sorted depth order. Correct anisotropic EWA projection,
// full 14-parameter backward gradient chain, logit/log reparameterization.
//
// Kernels:
//   1. preprocessGaussians  — EWA projection, depth key generation
//   2. forwardRasterize     — Per-tile forward compositing (front-to-back)
//   3. computeL1Gradient    — Per-pixel L1 loss gradient
//   4. backwardRasterize    — Per-tile backward (back-to-front, atomic gradients)
//   5. adamUpdate           — Per-Gaussian Adam optimizer + quaternion normalize
//   6. densificationStats   — AbsGrad screen gradient accumulation
//   7. compactSplats        — Stream compaction for pruning
//
// Reference: 3DGS (Kerbl 2023), gsplat (Ye 2024), fused-ssim (Lirui 2024)

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

constant constexpr uint TILE_SIZE = 16;
constant constexpr uint BATCH_SIZE = 128;
constant constexpr float NEAR_CLIP = 0.2f;
constant constexpr float TRANSMITTANCE_THRESHOLD = 0.001f;

// ═══════════════════════════════════════════════════════════════════════
// Shared Structures
// ═══════════════════════════════════════════════════════════════════════

struct TrainingUniforms {
    float4x4 viewMatrix;       // world → camera (column-major)
    float fx, fy, cx, cy;      // camera intrinsics (at render resolution)
    uint imageWidth;
    uint imageHeight;
    uint numGaussians;
    uint currentStep;
    float lambdaDSSIM;         // D-SSIM loss weight (0.2)
    float _pad[3];
};

// Projected Gaussian: output of preprocessing, loaded cooperatively in tiles
struct ProjectedGaussian {
    float mean2d_x;            // Screen-space center x
    float mean2d_y;            // Screen-space center y
    float depth;               // View-space depth (for sorting)
    float conic_a;             // Inverse 2D covariance: [[a, b], [b, c]]
    float conic_b;
    float conic_c;
    float opacity;             // Activated opacity (after sigmoid)
    float color_r;
    float color_g;
    float color_b;
    float radius;              // Bounding radius (3× major axis)
    uint  gaussian_idx;        // Index into original params array
};

// Adam optimizer structures
struct AdamMoments {
    float first_moment[14];
    float second_moment[14];
    uint step;
    uint _pad[3];
};

struct AdamHyperparams {
    float beta1;
    float beta2;
    float epsilon;
    float lr_position;
    float lr_color;
    float lr_opacity;
    float lr_scale;
    float lr_rotation;
};

struct DensifyStats {
    float screen_grad_accum;
    uint grad_count;
    float max_screen_size;
    uint _pad;
};

// GPU Depth Supervision: dual depth source configuration
struct DepthConfig {
    float depthLambda;        // DAv2 Pearson loss weight (Layer 1)
    uint  hasRelativeDepth;   // 1 = DAv2 relative depth available (100% experience)
    uint  hasMetricDepth;     // 1 = LiDAR metric depth available (120% enhancement)
    float edgeBeta;           // Edge-aware modulation β (default 8.0)
    float gradClamp;          // Gradient clamp magnitude (default 1.0)
    float lidarLambda;        // LiDAR L1 loss weight (Layer 1b)
    uint  renderWidth;
    uint  renderHeight;
    uint  refDepthWidth;      // DAv2 output width
    uint  refDepthHeight;     // DAv2 output height
    uint  lidarWidth;         // LiDAR output width (256)
    uint  lidarHeight;        // LiDAR output height (192)
};

// ═══════════════════════════════════════════════════════════════════════
// Utility Functions
// ═══════════════════════════════════════════════════════════════════════

// Numerically stable sigmoid
inline float safe_sigmoid(float x) {
    if (x >= 0.0f) {
        float e = exp(-x);
        return 1.0f / (1.0f + e);
    }
    float e = exp(x);
    return e / (1.0f + e);
}

// Compare-and-swap atomic float addition — device memory (A14 compatible)
inline void atomic_add_float(device atomic_uint* addr, float val) {
    uint old_val = atomic_load_explicit(addr, memory_order_relaxed);
    while (true) {
        float new_val = as_type<float>(old_val) + val;
        if (atomic_compare_exchange_weak_explicit(
                addr, &old_val, as_type<uint>(new_val),
                memory_order_relaxed, memory_order_relaxed))
            break;
    }
}

// Compare-and-swap atomic float addition — threadgroup memory (10-50× lower latency)
// Used for per-tile gradient accumulation before flushing to device memory.
inline void tg_atomic_add_float(threadgroup atomic_uint* addr, float val) {
    uint old_val = atomic_load_explicit(addr, memory_order_relaxed);
    while (true) {
        float new_val = as_type<float>(old_val) + val;
        if (atomic_compare_exchange_weak_explicit(
                addr, &old_val, as_type<uint>(new_val),
                memory_order_relaxed, memory_order_relaxed))
            break;
    }
}

// Quaternion → 3×3 rotation matrix (row-major)
inline void quat_to_rotation(float4 q, thread float3x3& R) {
    float w = q.x, x = q.y, y = q.z, z = q.w;
    float x2 = x*x, y2 = y*y, z2 = z*z;
    float xy = x*y, xz = x*z, yz = y*z;
    float wx = w*x, wy = w*y, wz = w*z;

    R[0] = float3(1.0f - 2.0f*(y2+z2), 2.0f*(xy-wz),       2.0f*(xz+wy));
    R[1] = float3(2.0f*(xy+wz),        1.0f - 2.0f*(x2+z2), 2.0f*(yz-wx));
    R[2] = float3(2.0f*(xz-wy),        2.0f*(yz+wx),        1.0f - 2.0f*(x2+y2));
}

// Float → sortable uint (for radix sort)
inline uint float_to_sortable(float f) {
    uint bits = as_type<uint>(f);
    // IEEE 754: positive floats sort as unsigned integers
    // Negative floats: flip all bits. Positive: flip sign bit only.
    return (bits & 0x80000000u) ? ~bits : (bits ^ 0x80000000u);
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 1: Preprocess Gaussians (EWA Projection + Depth Keys)
// ═══════════════════════════════════════════════════════════════════════
//
// Per-Gaussian dispatch. Computes full anisotropic 2D covariance via:
//   Σ_3D = R·S²·R^T,  Σ_2D = J·W·Σ_3D·W^T·J^T  (EWA splatting)
// where J is the Jacobian of perspective projection, W is the view matrix.
//
// Params are in logit/log space: opacity = sigmoid(p[6]), scale = exp(p[7..9])

kernel void preprocessGaussians(
    device const float*        params              [[buffer(0)]],  // N × 14
    device ProjectedGaussian*  projected           [[buffer(1)]],  // N
    device uint*               depth_keys          [[buffer(2)]],  // N (sortable)
    device uint*               sort_indices        [[buffer(3)]],  // N (identity init)
    constant TrainingUniforms& uniforms            [[buffer(4)]],
    uint gid                                       [[thread_position_in_grid]])
{
    if (gid >= uniforms.numGaussians) return;

    uint base = gid * 14;
    float px = params[base+0], py = params[base+1], pz = params[base+2];
    float col_r = params[base+3], col_g = params[base+4], col_b = params[base+5];
    float opacity = safe_sigmoid(params[base+6]);
    float sx = exp(params[base+7]), sy = exp(params[base+8]), sz = exp(params[base+9]);
    float4 quat = float4(params[base+10], params[base+11], params[base+12], params[base+13]);

    // Transform to camera space
    float4 world_pos = float4(px, py, pz, 1.0f);
    float4 cam_pos = uniforms.viewMatrix * world_pos;

    if (cam_pos.z <= NEAR_CLIP) {
        // Mark as invalid (radius = 0)
        projected[gid].radius = 0.0f;
        depth_keys[gid] = 0xFFFFFFFFu;  // Sort to end
        sort_indices[gid] = gid;
        return;
    }

    float tz = cam_pos.z;
    float tx = cam_pos.x;
    float ty = cam_pos.y;
    float inv_tz = 1.0f / tz;
    float inv_tz2 = inv_tz * inv_tz;

    // Screen-space center
    float mean2d_x = uniforms.fx * tx * inv_tz + uniforms.cx;
    float mean2d_y = uniforms.fy * ty * inv_tz + uniforms.cy;

    // ── 3D Covariance: Σ = R·diag(s²)·R^T ──
    float3x3 Rot;
    quat_to_rotation(quat, Rot);

    // M = R·S (scale columns of R)
    float3 m0 = Rot[0] * sx;  // column 0 of M
    float3 m1 = Rot[1] * sy;
    float3 m2 = Rot[2] * sz;

    // Σ_3D upper triangle: [s00, s01, s02, s11, s12, s22]
    float s00 = dot(m0,m0), s01 = dot(m0,m1), s02 = dot(m0,m2);
    float s11 = dot(m1,m1), s12 = dot(m1,m2), s22 = dot(m2,m2);

    // ── Jacobian of perspective projection ──
    // J = [[fx/tz, 0, -fx*tx/tz²],
    //      [0, fy/tz, -fy*ty/tz²]]
    float j00 = uniforms.fx * inv_tz;
    float j02 = -uniforms.fx * tx * inv_tz2;
    float j11 = uniforms.fy * inv_tz;
    float j12 = -uniforms.fy * ty * inv_tz2;

    // ── View matrix 3×3 (extract rotation part) ──
    float3x3 W;
    W[0] = float3(uniforms.viewMatrix[0][0], uniforms.viewMatrix[1][0], uniforms.viewMatrix[2][0]);
    W[1] = float3(uniforms.viewMatrix[0][1], uniforms.viewMatrix[1][1], uniforms.viewMatrix[2][1]);
    W[2] = float3(uniforms.viewMatrix[0][2], uniforms.viewMatrix[1][2], uniforms.viewMatrix[2][2]);

    // T = J·W (2×3 matrix, but J is 2×3 with zeros)
    float t00 = j00*W[0][0] + j02*W[2][0];
    float t01 = j00*W[0][1] + j02*W[2][1];
    float t02 = j00*W[0][2] + j02*W[2][2];
    float t10 = j11*W[1][0] + j12*W[2][0];
    float t11 = j11*W[1][1] + j12*W[2][1];
    float t12 = j11*W[1][2] + j12*W[2][2];

    // ── 2D Covariance: Σ_2D = T·Σ_3D·T^T ──
    float c00 = t00*(t00*s00 + t01*s01 + t02*s02)
               + t01*(t00*s01 + t01*s11 + t02*s12)
               + t02*(t00*s02 + t01*s12 + t02*s22);
    float c01 = t10*(t00*s00 + t01*s01 + t02*s02)
               + t11*(t00*s01 + t01*s11 + t02*s12)
               + t12*(t00*s02 + t01*s12 + t02*s22);
    float c11 = t10*(t10*s00 + t11*s01 + t12*s02)
               + t11*(t10*s01 + t11*s11 + t12*s12)
               + t12*(t10*s02 + t11*s12 + t12*s22);

    // C3: Mip-Splatting depth-adaptive anti-aliasing (CVPR 2024).
    // Filter size adapts to depth: far objects get larger filter (prevents aliasing),
    // near objects get smaller filter (preserves detail).
    // pixel_footprint = max(1/fx, 1/fy) estimates physical size of a pixel in camera space.
    // filter = max(0.3, pixel_footprint² × depth²) — depth-dependent 2D filter.
    float pixel_footprint = max(1.0f / max(uniforms.fx, 1e-6f),
                                1.0f / max(uniforms.fy, 1e-6f));
    float depth_filter = max(0.3f, pixel_footprint * pixel_footprint * tz * tz);
    c00 += depth_filter;
    c11 += depth_filter;

    float det = c00 * c11 - c01 * c01;
    if (det <= 1e-8f) {
        projected[gid].radius = 0.0f;
        depth_keys[gid] = 0xFFFFFFFFu;
        sort_indices[gid] = gid;
        return;
    }

    float inv_det = 1.0f / det;

    // Conic (inverse covariance)
    float conic_a = c11 * inv_det;
    float conic_b = -c01 * inv_det;
    float conic_c = c00 * inv_det;

    // Bounding radius from eigenvalues
    float trace = c00 + c11;
    float diff = c00 - c11;
    float disc = sqrt(diff*diff + 4.0f*c01*c01);
    float lambda_max = max(0.5f * (trace + disc), 1e-6f);
    float radius = 3.0f * sqrt(lambda_max);

    if (radius > 1024.0f) {
        projected[gid].radius = 0.0f;
        depth_keys[gid] = 0xFFFFFFFFu;
        sort_indices[gid] = gid;
        return;
    }

    // Write output
    projected[gid].mean2d_x = mean2d_x;
    projected[gid].mean2d_y = mean2d_y;
    projected[gid].depth = tz;
    projected[gid].conic_a = conic_a;
    projected[gid].conic_b = conic_b;
    projected[gid].conic_c = conic_c;
    projected[gid].opacity = opacity;
    projected[gid].color_r = col_r;
    projected[gid].color_g = col_g;
    projected[gid].color_b = col_b;
    projected[gid].radius = radius;
    projected[gid].gaussian_idx = gid;

    depth_keys[gid] = float_to_sortable(tz);
    sort_indices[gid] = gid;
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 2: Forward Rasterize (Per-Tile, Front-to-Back)
// ═══════════════════════════════════════════════════════════════════════
//
// 16×16 tile dispatch (256 threads/threadgroup = 1 tile).
// Each thread handles ONE pixel.
// Sorted Gaussians loaded cooperatively in batches of BATCH_SIZE.
// Front-to-back compositing with early termination.
//
// Output: rendered RGB image + per-pixel transmittance (for backward)

kernel void forwardRasterize(
    device const ProjectedGaussian* sorted_projected [[buffer(0)]],
    device const uint*              sorted_indices   [[buffer(1)]],
    device float*                   rendered_image   [[buffer(2)]],  // W×H×3
    device float*                   transmittance    [[buffer(3)]],  // W×H
    device uint*                    last_contributor [[buffer(4)]],  // W×H: last Gaussian idx
    constant TrainingUniforms&      uniforms         [[buffer(5)]],
    device float*                   rendered_depth   [[buffer(6)]],  // B5: W×H depth output
    uint2 gid                                        [[thread_position_in_grid]],
    uint2 lid                                        [[thread_position_in_threadgroup]],
    uint2 tgid                                       [[threadgroup_position_in_grid]])
{
    uint px = gid.x;
    uint py = gid.y;
    bool valid_pixel = (px < uniforms.imageWidth && py < uniforms.imageHeight);

    float3 accum_color = float3(0.0f);
    float accum_depth = 0.0f;  // B5: alpha-weighted depth accumulation
    float T = 1.0f;
    uint last_idx = 0;

    uint tid = lid.y * TILE_SIZE + lid.x;  // 0-255 local thread index
    uint tile_x0 = tgid.x * TILE_SIZE;
    uint tile_y0 = tgid.y * TILE_SIZE;
    uint tile_x1 = min(tile_x0 + TILE_SIZE, uniforms.imageWidth);
    uint tile_y1 = min(tile_y0 + TILE_SIZE, uniforms.imageHeight);

    // Cooperative loading buffer
    threadgroup ProjectedGaussian shared_batch[BATCH_SIZE];
    // Bug 0.4 fix: declare all_done_flag OUTSIDE the loop so it persists across iterations.
    // Previously declared inside the early-exit block, causing re-allocation every iteration.
    threadgroup atomic_uint all_done_flag;

    uint num = uniforms.numGaussians;
    for (uint batch_start = 0; batch_start < num; batch_start += BATCH_SIZE) {
        // ── Cooperative load: 256 threads load up to BATCH_SIZE Gaussians ──
        uint load_end = min(batch_start + BATCH_SIZE, num);
        uint batch_count = load_end - batch_start;

        // Each thread loads at most 1 element (128 ≤ 256 threads available)
        if (tid < batch_count) {
            uint sorted_idx = sorted_indices[batch_start + tid];
            shared_batch[tid] = sorted_projected[sorted_idx];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // ── Each thread evaluates batch against its pixel ──
        if (valid_pixel && T > TRANSMITTANCE_THRESHOLD) {
            for (uint j = 0; j < batch_count; j++) {
                ProjectedGaussian g = shared_batch[j];
                if (g.radius <= 0.0f) continue;

                // Tile-level bounding box skip
                float g_xmin = g.mean2d_x - g.radius;
                float g_xmax = g.mean2d_x + g.radius;
                float g_ymin = g.mean2d_y - g.radius;
                float g_ymax = g.mean2d_y + g.radius;
                if (g_xmax < float(tile_x0) || g_xmin >= float(tile_x1) ||
                    g_ymax < float(tile_y0) || g_ymin >= float(tile_y1))
                    continue;

                // Pixel-level evaluation
                float dx = float(px) - g.mean2d_x;
                float dy = float(py) - g.mean2d_y;
                float power = -0.5f * (g.conic_a*dx*dx + 2.0f*g.conic_b*dx*dy + g.conic_c*dy*dy);
                if (power < -4.0f) continue;

                float alpha = g.opacity * exp(power);
                if (alpha < 1.0f / 255.0f) continue;
                alpha = min(alpha, 0.99f);

                float weight = alpha * T;
                accum_color += weight * float3(g.color_r, g.color_g, g.color_b);
                accum_depth += weight * g.depth;  // B5: depth compositing
                T *= (1.0f - alpha);
                last_idx = batch_start + j;

                if (T < TRANSMITTANCE_THRESHOLD) break;
            }
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Early exit if ALL threads in tile are done
        // (using simd_all on each SIMD group, then threadgroup check)
        bool done = !valid_pixel || (T < TRANSMITTANCE_THRESHOLD);
        if (simd_all(done)) {
            // Check if all SIMD groups are done via threadgroup shared flag
            // Bug 0.4 fix: all_done_flag is now declared outside the loop (persistent).
            if (tid == 0) atomic_store_explicit(&all_done_flag, 0u, memory_order_relaxed);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (simd_all(done)) {
                atomic_fetch_add_explicit(&all_done_flag, 1u, memory_order_relaxed);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            uint simd_groups = (TILE_SIZE * TILE_SIZE + 31) / 32;
            if (atomic_load_explicit(&all_done_flag, memory_order_relaxed) >= simd_groups) {
                break;
            }
        }
    }

    // Write output
    if (valid_pixel) {
        uint pidx = py * uniforms.imageWidth + px;
        uint cidx = pidx * 3;
        rendered_image[cidx + 0] = accum_color.x;
        rendered_image[cidx + 1] = accum_color.y;
        rendered_image[cidx + 2] = accum_color.z;
        transmittance[pidx] = T;
        last_contributor[pidx] = last_idx;
        // B5: Write rendered depth (alpha-weighted, 0 = no geometry visible)
        rendered_depth[pidx] = accum_depth;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 3: Compute L1 Loss Gradient (per-pixel)
// ═══════════════════════════════════════════════════════════════════════
//
// dL/d(rendered) = sign(rendered - target) / N
// Combined with D-SSIM: (1-λ)·dL1 + λ·dDSSIM
// Note: D-SSIM gradient is computed on CPU (separable box filter) and
// blended with L1 gradient. This kernel computes L1 portion only.

kernel void computeL1Gradient(
    device const float* rendered_image [[buffer(0)]],  // W×H×3
    device const float* target_image   [[buffer(1)]],  // W×H×3
    device float*       image_grad     [[buffer(2)]],  // W×H×3 output
    constant uint2&     image_size     [[buffer(3)]],  // (W, H)
    uint gid                           [[thread_position_in_grid]])
{
    uint total = image_size.x * image_size.y * 3;
    if (gid >= total) return;

    float inv_n = 1.0f / float(total);
    float diff = rendered_image[gid] - target_image[gid];
    image_grad[gid] = (diff > 0.0f) ? inv_n : -inv_n;
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 4: Backward Rasterize (Per-Tile, Back-to-Front)
// ═══════════════════════════════════════════════════════════════════════
//
// Reverse of forward: iterate sorted Gaussians from back to front.
// Reconstruct transmittance using stored final T and reverse alpha.
// Compute full gradient chain for all 14 parameters.
// Atomic accumulation into per-Gaussian gradient buffer.
//
// Gradient chain:
//   dL/dC → dL/d(color,opacity,alpha) → dL/d(mean2d,conic) →
//   dL/d(position,scale,rotation)

kernel void backwardRasterize(
    device const ProjectedGaussian* sorted_projected [[buffer(0)]],
    device const uint*              sorted_indices   [[buffer(1)]],
    device const float*             image_grad       [[buffer(2)]],   // W×H×3 dL/dC
    device const float*             fwd_transmittance[[buffer(3)]],   // W×H final T
    device const float*             rendered_image   [[buffer(4)]],   // W×H×3 forward output
    device const uint*              last_contributor [[buffer(5)]],   // W×H
    device const float*             params           [[buffer(6)]],   // N×14 original params
    device atomic_uint*             gradient_buffer  [[buffer(7)]],   // N×14 (atomic float)
    device atomic_uint*             absgrad_buffer   [[buffer(8)]],   // N (atomic float, AbsGrad)
    device atomic_uint*             grad_count_buf   [[buffer(9)]],   // N (atomic uint)
    device atomic_uint*             cov2d_grad_buf   [[buffer(10)]],  // N×3 (atomic float: dL/d(c00,c01,c11))
    constant TrainingUniforms&      uniforms         [[buffer(11)]],
    device const float*             depth_grad_buf   [[buffer(12)]],  // W×H: dL/d(rendered_depth)
    constant DepthConfig&           depth_config     [[buffer(13)]],  // Dual depth source config
    uint2 gid                                        [[thread_position_in_grid]],
    uint2 lid                                        [[thread_position_in_threadgroup]],
    uint2 tgid                                       [[threadgroup_position_in_grid]])
{
    uint px_x = gid.x;
    uint px_y = gid.y;
    bool valid = (px_x < uniforms.imageWidth && px_y < uniforms.imageHeight);

    uint pidx = px_y * uniforms.imageWidth + px_x;
    uint cidx = pidx * 3;

    // Load per-pixel state from forward pass
    float3 dL_dC = float3(0);
    float T_final = 1.0f;
    float3 accum_color = float3(0);
    uint last_idx = 0;

    if (valid) {
        dL_dC = float3(image_grad[cidx], image_grad[cidx+1], image_grad[cidx+2]);
        T_final = fwd_transmittance[pidx];
        accum_color = float3(rendered_image[cidx], rendered_image[cidx+1], rendered_image[cidx+2]);
        last_idx = last_contributor[pidx];
    }

    // View matrix for position gradient chain
    float3x3 W;
    W[0] = float3(uniforms.viewMatrix[0][0], uniforms.viewMatrix[1][0], uniforms.viewMatrix[2][0]);
    W[1] = float3(uniforms.viewMatrix[0][1], uniforms.viewMatrix[1][1], uniforms.viewMatrix[2][1]);
    W[2] = float3(uniforms.viewMatrix[0][2], uniforms.viewMatrix[1][2], uniforms.viewMatrix[2][2]);

    uint tid = lid.y * TILE_SIZE + lid.x;
    constexpr uint THREADS_PER_TILE = TILE_SIZE * TILE_SIZE;  // 256
    uint tile_x0 = tgid.x * TILE_SIZE;
    uint tile_y0 = tgid.y * TILE_SIZE;
    uint tile_x1 = min(tile_x0 + TILE_SIZE, uniforms.imageWidth);
    uint tile_y1 = min(tile_y0 + TILE_SIZE, uniforms.imageHeight);

    threadgroup ProjectedGaussian shared_batch[BATCH_SIZE];

    // ── Per-tile gradient accumulation (replaces per-pixel device atomics) ──
    // Each tile accumulates gradients in threadgroup memory (10-50× lower latency).
    // After each batch, ONE thread per Gaussian flushes the sum to device memory.
    // Reduces device atomic contention by ~50-100× for overlapping Gaussians.
    //
    // Layout: 7 grad params (pos3+color3+opacity1) + 3 cov2d + 1 absgrad + 1 count = 12 per Gaussian
    // Memory: BATCH_SIZE × 12 × 4 = 6,144 bytes + shared_batch 6,144 bytes = ~12 KB (of 32 KB limit)
    threadgroup atomic_uint tg_grad[BATCH_SIZE * 7];       // pos(3) + color(3) + opacity(1)
    threadgroup atomic_uint tg_cov2d[BATCH_SIZE * 3];      // dL/d(c00, c01, c11)
    threadgroup atomic_uint tg_absgrad[BATCH_SIZE];         // |screen gradient|
    threadgroup atomic_uint tg_count[BATCH_SIZE];           // pixel count

    // Reconstruct running state: T = T_final, C = accum_color
    float T = T_final;
    float3 C_accum = accum_color;

    // Iterate in REVERSE order (back to front)
    uint num = uniforms.numGaussians;
    uint num_batches = (num + BATCH_SIZE - 1) / BATCH_SIZE;

    for (int b = int(num_batches) - 1; b >= 0; b--) {
        uint batch_start = uint(b) * BATCH_SIZE;
        uint batch_end = min(batch_start + BATCH_SIZE, num);
        uint batch_count = batch_end - batch_start;

        // ── Phase 1: Cooperative load + zero accumulators ──
        if (tid < batch_count) {
            uint sorted_idx = sorted_indices[batch_start + tid];
            shared_batch[tid] = sorted_projected[sorted_idx];
        }
        // Zero tile accumulators (256 threads zero ~12×batch_count/256 elements each)
        for (uint k = tid; k < batch_count * 7; k += THREADS_PER_TILE) {
            atomic_store_explicit(&tg_grad[k], 0u, memory_order_relaxed);
        }
        for (uint k = tid; k < batch_count * 3; k += THREADS_PER_TILE) {
            atomic_store_explicit(&tg_cov2d[k], 0u, memory_order_relaxed);
        }
        if (tid < batch_count) {
            atomic_store_explicit(&tg_absgrad[tid], 0u, memory_order_relaxed);
            atomic_store_explicit(&tg_count[tid], 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // ── Phase 2: Per-pixel backward (accumulate to threadgroup) ──
        if (valid) {
            for (int j = int(batch_count) - 1; j >= 0; j--) {
                uint global_idx = batch_start + uint(j);
                if (global_idx > last_idx) continue;

                ProjectedGaussian g = shared_batch[j];
                if (g.radius <= 0.0f) continue;

                // Tile-level skip
                float g_xmin = g.mean2d_x - g.radius;
                float g_xmax = g.mean2d_x + g.radius;
                float g_ymin = g.mean2d_y - g.radius;
                float g_ymax = g.mean2d_y + g.radius;
                if (g_xmax < float(tile_x0) || g_xmin >= float(tile_x1) ||
                    g_ymax < float(tile_y0) || g_ymin >= float(tile_y1))
                    continue;

                // Pixel-level evaluation
                float dx = float(px_x) - g.mean2d_x;
                float dy = float(px_y) - g.mean2d_y;
                float power = -0.5f * (g.conic_a*dx*dx + 2.0f*g.conic_b*dx*dy + g.conic_c*dy*dy);
                if (power < -4.0f) continue;

                float exp_p = exp(power);
                float alpha = g.opacity * exp_p;
                if (alpha < 1.0f / 255.0f) continue;
                alpha = min(alpha, 0.99f);

                float one_minus_alpha = 1.0f - alpha;
                float T_before = T / max(one_minus_alpha, 1e-6f);
                float weight = T_before * alpha;
                float3 C_before = C_accum - weight * float3(g.color_r, g.color_g, g.color_b);

                // ── Gradient: dL/d(color) = dL/dC × weight ──
                float3 dL_dc = dL_dC * weight;

                // ── Gradient: dL/d(alpha) = dot(dL/dC, color) × T_before ──
                float dL_dalpha = dot(dL_dC, float3(g.color_r, g.color_g, g.color_b)) * T_before;

                // ── Layer 3: Depth gradient → alpha gradient ──
                if (depth_config.hasRelativeDepth > 0 || depth_config.hasMetricDepth > 0) {
                    float dg = depth_grad_buf[pidx];
                    if (abs(dg) > 1e-8f) {
                        dL_dalpha += dg * T_before * g.depth;
                    }
                }

                float dL_dopacity = dL_dalpha * exp_p;
                float dL_dlogit = dL_dopacity * g.opacity * (1.0f - g.opacity);
                float dL_dpower = dL_dalpha * g.opacity * exp_p;

                // ── dL/d(mean2d) from power ──
                float dp_ddx = -(g.conic_a * dx + g.conic_b * dy);
                float dp_ddy = -(g.conic_b * dx + g.conic_c * dy);
                float dL_dmean2d_x = -dL_dpower * dp_ddx;
                float dL_dmean2d_y = -dL_dpower * dp_ddy;

                float pixel_grad_mag = sqrt(dL_dmean2d_x * dL_dmean2d_x +
                                            dL_dmean2d_y * dL_dmean2d_y);

                // ── Position gradient via Jacobian chain ──
                uint gi = g.gaussian_idx;
                uint gi_base = gi * 14;
                float pos_x = params[gi_base+0], pos_y = params[gi_base+1], pos_z = params[gi_base+2];

                float4 cp = uniforms.viewMatrix * float4(pos_x, pos_y, pos_z, 1.0f);
                float tz = cp.z, tx_c = cp.x, ty_c = cp.y;
                float inv_tz = 1.0f / tz;
                float inv_tz2 = inv_tz * inv_tz;

                float dm_x_dpx = uniforms.fx * (W[0][0]*tz - tx_c*W[2][0]) * inv_tz2;
                float dm_x_dpy = uniforms.fx * (W[0][1]*tz - tx_c*W[2][1]) * inv_tz2;
                float dm_x_dpz = uniforms.fx * (W[0][2]*tz - tx_c*W[2][2]) * inv_tz2;
                float dm_y_dpx = uniforms.fy * (W[1][0]*tz - ty_c*W[2][0]) * inv_tz2;
                float dm_y_dpy = uniforms.fy * (W[1][1]*tz - ty_c*W[2][1]) * inv_tz2;
                float dm_y_dpz = uniforms.fy * (W[1][2]*tz - ty_c*W[2][2]) * inv_tz2;

                float dL_dpx = dL_dmean2d_x*dm_x_dpx + dL_dmean2d_y*dm_y_dpx;
                float dL_dpy = dL_dmean2d_x*dm_x_dpy + dL_dmean2d_y*dm_y_dpy;
                float dL_dpz = dL_dmean2d_x*dm_x_dpz + dL_dmean2d_y*dm_y_dpz;

                // ── Layer 3: Depth gradient → position gradient ──
                if (depth_config.hasRelativeDepth > 0 || depth_config.hasMetricDepth > 0) {
                    float dg = depth_grad_buf[pidx];
                    if (abs(dg) > 1e-8f) {
                        float dL_dtz = dg * weight;
                        dL_dpx += dL_dtz * W[2][0];
                        dL_dpy += dL_dtz * W[2][1];
                        dL_dpz += dL_dtz * W[2][2];
                    }
                }

                // ── Accumulate to THREADGROUP memory (not device) ──
                uint jj = uint(j);
                tg_atomic_add_float(&tg_grad[jj*7 + 0], dL_dpx);
                tg_atomic_add_float(&tg_grad[jj*7 + 1], dL_dpy);
                tg_atomic_add_float(&tg_grad[jj*7 + 2], dL_dpz);
                tg_atomic_add_float(&tg_grad[jj*7 + 3], dL_dc.x);
                tg_atomic_add_float(&tg_grad[jj*7 + 4], dL_dc.y);
                tg_atomic_add_float(&tg_grad[jj*7 + 5], dL_dc.z);
                tg_atomic_add_float(&tg_grad[jj*7 + 6], dL_dlogit);

                // ── dL/d(cov2d) for scale/rotation gradient chain ──
                {
                    float conic_det = g.conic_a * g.conic_c - g.conic_b * g.conic_b;
                    if (abs(conic_det) > 1e-12f) {
                        float inv_cd = 1.0f / conic_det;
                        float c00 = g.conic_c * inv_cd;
                        float c01 = -g.conic_b * inv_cd;
                        float c11 = g.conic_a * inv_cd;

                        float det_cov = c00 * c11 - c01 * c01;
                        if (abs(det_cov) > 1e-12f) {
                            float inv_det = 1.0f / det_cov;
                            float inv_det2 = inv_det * inv_det;
                            float N = c11*dx*dx - 2.0f*c01*dx*dy + c00*dy*dy;

                            float dl_c00 = dL_dpower * (-0.5f) * (dy*dy*det_cov - N*c11) * inv_det2;
                            float dl_c01 = dL_dpower * (-0.5f) * (-2.0f*dx*dy*det_cov + 2.0f*N*c01) * inv_det2;
                            float dl_c11 = dL_dpower * (-0.5f) * (dx*dx*det_cov - N*c00) * inv_det2;

                            tg_atomic_add_float(&tg_cov2d[jj*3 + 0], dl_c00);
                            tg_atomic_add_float(&tg_cov2d[jj*3 + 1], dl_c01);
                            tg_atomic_add_float(&tg_cov2d[jj*3 + 2], dl_c11);
                        }
                    }
                }

                tg_atomic_add_float(&tg_absgrad[jj], pixel_grad_mag);
                atomic_fetch_add_explicit(&tg_count[jj], 1u, memory_order_relaxed);

                // Update running state for next Gaussian (closer)
                T = T_before;
                C_accum = C_before;
            }
        }

        // ── Phase 3: Flush tile accumulators to device memory ──
        // One thread per Gaussian writes the aggregated sum — single device atomic per param.
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (tid < batch_count) {
            uint gi = shared_batch[tid].gaussian_idx;
            uint gi_base = gi * 14;

            // Flush 7 gradient components → global gradient_buffer[gi_base+0..6]
            for (uint k = 0; k < 7; k++) {
                float val = as_type<float>(atomic_load_explicit(&tg_grad[tid*7 + k], memory_order_relaxed));
                if (val != 0.0f) {
                    atomic_add_float(&gradient_buffer[gi_base + k], val);
                }
            }
            // Flush 3 cov2d gradient components
            for (uint k = 0; k < 3; k++) {
                float val = as_type<float>(atomic_load_explicit(&tg_cov2d[tid*3 + k], memory_order_relaxed));
                if (val != 0.0f) {
                    atomic_add_float(&cov2d_grad_buf[gi*3 + k], val);
                }
            }
            // Flush absgrad
            float ag = as_type<float>(atomic_load_explicit(&tg_absgrad[tid], memory_order_relaxed));
            if (ag != 0.0f) {
                atomic_add_float(&absgrad_buffer[gi], ag);
            }
            // Flush count
            uint gc = atomic_load_explicit(&tg_count[tid], memory_order_relaxed);
            if (gc > 0) {
                atomic_fetch_add_explicit(&grad_count_buf[gi], gc, memory_order_relaxed);
            }
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 5: Adam Update + Quaternion Normalization
// ═══════════════════════════════════════════════════════════════════════

kernel void adamUpdate(
    device float*                params              [[buffer(0)]],  // N × 14
    device const float*          grads               [[buffer(1)]],  // N × 14
    device AdamMoments*          moments             [[buffer(2)]],
    constant AdamHyperparams&    hyper               [[buffer(3)]],
    constant uint&               num_gaussians       [[buffer(4)]],
    uint gid                                         [[thread_position_in_grid]])
{
    if (gid >= num_gaussians) return;

    uint base = gid * 14;
    moments[gid].step++;
    float t = float(moments[gid].step);

    float bc1 = 1.0f / (1.0f - pow(hyper.beta1, t));
    float bc2 = 1.0f / (1.0f - pow(hyper.beta2, t));

    // Learning rate per parameter group
    float lr[14] = {
        hyper.lr_position, hyper.lr_position, hyper.lr_position,
        hyper.lr_color, hyper.lr_color, hyper.lr_color,
        hyper.lr_opacity,
        hyper.lr_scale, hyper.lr_scale, hyper.lr_scale,
        hyper.lr_rotation, hyper.lr_rotation, hyper.lr_rotation, hyper.lr_rotation
    };

    for (uint i = 0; i < 14; i++) {
        float g = grads[base + i];
        float m = hyper.beta1 * moments[gid].first_moment[i] +
                  (1.0f - hyper.beta1) * g;
        float v = hyper.beta2 * moments[gid].second_moment[i] +
                  (1.0f - hyper.beta2) * g * g;
        moments[gid].first_moment[i] = m;
        moments[gid].second_moment[i] = v;

        float m_hat = m * bc1;
        float v_hat = v * bc2;

        params[base + i] -= lr[i] * m_hat / (sqrt(v_hat) + hyper.epsilon);
    }

    // ── Color clamping: keep in [0, 1] after Adam step ──
    // Without this, Adam overshoots when rendered image is dark
    // (low Gaussian opacity) → gradient pushes colors >> 1.0 → white.
    params[base+3] = clamp(params[base+3], 0.0f, 1.0f);
    params[base+4] = clamp(params[base+4], 0.0f, 1.0f);
    params[base+5] = clamp(params[base+5], 0.0f, 1.0f);

    // ── Quaternion normalization guard ──
    float4 q = float4(params[base+10], params[base+11],
                       params[base+12], params[base+13]);
    float qnorm = length(q);
    if (qnorm < 1e-8f) {
        q = float4(1.0f, 0.0f, 0.0f, 0.0f);
    } else {
        q /= qnorm;
    }
    params[base+10] = q.x;
    params[base+11] = q.y;
    params[base+12] = q.z;
    params[base+13] = q.w;
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 6: Densification Stats (AbsGrad)
// ═══════════════════════════════════════════════════════════════════════
//
// Reads the atomically accumulated AbsGrad values and writes to the
// DensifyStats structure. Called after backward pass.

kernel void densificationStats(
    device const float*     absgrad_buf    [[buffer(0)]],  // N (accumulated absgrad)
    device const uint*      grad_count_buf [[buffer(1)]],  // N (count)
    device DensifyStats*    stats          [[buffer(2)]],
    constant uint&          num_gaussians  [[buffer(3)]],
    uint gid                               [[thread_position_in_grid]])
{
    if (gid >= num_gaussians) return;

    // Read atomic values (already stored as regular floats after backward)
    stats[gid].screen_grad_accum += absgrad_buf[gid];
    stats[gid].grad_count += grad_count_buf[gid];
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 7: Compact Splats (stream compaction after pruning)
// ═══════════════════════════════════════════════════════════════════════

kernel void compactSplats(
    device const float*     src_params   [[buffer(0)]],  // N_old × 14
    device float*           dst_params   [[buffer(1)]],  // N_new × 14
    device const uint*      prefix_sum   [[buffer(2)]],  // inclusive prefix sum
    device const uint*      keep_mask    [[buffer(3)]],  // 0 or 1 per gaussian
    constant uint&          old_count    [[buffer(4)]],
    uint gid                             [[thread_position_in_grid]])
{
    if (gid >= old_count) return;
    if (keep_mask[gid] == 0) return;

    uint dst_idx = prefix_sum[gid] - 1;  // Convert to 0-based
    uint src_base = gid * 14;
    uint dst_base = dst_idx * 14;

    for (uint i = 0; i < 14; i++) {
        dst_params[dst_base + i] = src_params[src_base + i];
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 8: Radix Sort (simplified, 4 passes, 8-bit per pass)
// ═══════════════════════════════════════════════════════════════════════
//
// Simple global radix sort for depth-ordering Gaussians.
// 4 passes × 256 bins = 32-bit key sort.
// Keys: depth_keys (sortable uint), Values: gaussian indices.

kernel void radixSortHistogram(
    device const uint*      keys         [[buffer(0)]],
    device atomic_uint*     histogram    [[buffer(1)]],  // 256 bins
    constant uint&          count        [[buffer(2)]],
    constant uint&          bit_offset   [[buffer(3)]],
    uint gid                             [[thread_position_in_grid]])
{
    if (gid >= count) return;
    uint key = keys[gid];
    uint bucket = (key >> bit_offset) & 0xFFu;
    atomic_fetch_add_explicit(&histogram[bucket], 1u, memory_order_relaxed);
}

kernel void radixSortPrefixSum(
    device uint*     histogram    [[buffer(0)]],  // 256 bins → exclusive prefix sum
    uint gid                      [[thread_position_in_grid]])
{
    // Single-threadgroup prefix sum (256 elements)
    // Use Hillis-Steele algorithm in threadgroup memory
    threadgroup uint shared[256];
    if (gid < 256) {
        shared[gid] = histogram[gid];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Hillis-Steele exclusive scan
    for (uint stride = 1; stride < 256; stride <<= 1) {
        uint val = 0;
        if (gid >= stride && gid < 256) {
            val = shared[gid - stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (gid < 256) {
            shared[gid] += val;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Bug 0.3 fix: Convert inclusive prefix sum → exclusive prefix sum.
    // Scatter kernel uses atomic_fetch_add on offsets, which requires exclusive sum.
    // Inclusive: shared[i] = sum(histogram[0..i])
    // Exclusive: histogram[i] = sum(histogram[0..i-1]) = shared[i-1], histogram[0] = 0
    if (gid < 256) {
        histogram[gid] = (gid > 0) ? shared[gid - 1] : 0;
    }
}

kernel void radixSortScatter(
    device const uint*      keys_in      [[buffer(0)]],
    device const uint*      vals_in      [[buffer(1)]],
    device uint*            keys_out     [[buffer(2)]],
    device uint*            vals_out     [[buffer(3)]],
    device atomic_uint*     offsets      [[buffer(4)]],  // 256 bins (prefix sum)
    constant uint&          count        [[buffer(5)]],
    constant uint&          bit_offset   [[buffer(6)]],
    uint gid                             [[thread_position_in_grid]])
{
    if (gid >= count) return;
    uint key = keys_in[gid];
    uint val = vals_in[gid];
    uint bucket = (key >> bit_offset) & 0xFFu;
    uint dst = atomic_fetch_add_explicit(&offsets[bucket], 1u, memory_order_relaxed);
    keys_out[dst] = key;
    vals_out[dst] = val;
}

// ═══════════════════════════════════════════════════════════════════════
// Kernel 9: Compute Scale & Rotation Gradients (per-Gaussian)
// ═══════════════════════════════════════════════════════════════════════
//
// Reads accumulated dL/d(cov2d) from backward pass, then computes:
//   dL/d(cov2d) → dL/d(cov3d) via T^T chain (T = J·W)
//   dL/d(cov3d) → dL/d(scale) via d(R·S²·R^T)/d(s)
//   dL/d(cov3d) → dL/d(rotation) via d(R)/d(q) analytical formulas
//
// Chain rule for logit/log reparameterization applied.
// Reference: 3DGS (Kerbl 2023), gsplat backward.cu

kernel void computeScaleRotGradients(
    device const float*     params            [[buffer(0)]],  // N × 14
    device const float*     cov2d_grad        [[buffer(1)]],  // N × 3 (dL/dc00, dL/dc01, dL/dc11)
    device atomic_uint*     gradient_buffer   [[buffer(2)]],  // N × 14 (atomic float)
    constant TrainingUniforms& uniforms       [[buffer(3)]],
    uint gid                                  [[thread_position_in_grid]])
{
    if (gid >= uniforms.numGaussians) return;

    uint base = gid * 14;
    float px = params[base+0], py = params[base+1], pz = params[base+2];
    float sx = exp(params[base+7]), sy = exp(params[base+8]), sz = exp(params[base+9]);
    float4 quat = float4(params[base+10], params[base+11], params[base+12], params[base+13]);

    // Load accumulated cov2d gradients
    float dL_c00 = cov2d_grad[gid*3 + 0];
    float dL_c01 = cov2d_grad[gid*3 + 1];
    float dL_c11 = cov2d_grad[gid*3 + 2];

    // Skip if no gradient signal
    if (abs(dL_c00) + abs(dL_c01) + abs(dL_c11) < 1e-12f) return;

    // ── Reconstruct projection matrices (same as preprocess) ──
    float4 cam_pos = uniforms.viewMatrix * float4(px, py, pz, 1.0f);
    float tz = cam_pos.z, tx = cam_pos.x, ty = cam_pos.y;
    if (tz <= NEAR_CLIP) return;

    float inv_tz = 1.0f / tz;
    float inv_tz2 = inv_tz * inv_tz;

    // Jacobian
    float j00 = uniforms.fx * inv_tz;
    float j02 = -uniforms.fx * tx * inv_tz2;
    float j11 = uniforms.fy * inv_tz;
    float j12 = -uniforms.fy * ty * inv_tz2;

    // View matrix 3×3
    float3x3 W;
    W[0] = float3(uniforms.viewMatrix[0][0], uniforms.viewMatrix[1][0], uniforms.viewMatrix[2][0]);
    W[1] = float3(uniforms.viewMatrix[0][1], uniforms.viewMatrix[1][1], uniforms.viewMatrix[2][1]);
    W[2] = float3(uniforms.viewMatrix[0][2], uniforms.viewMatrix[1][2], uniforms.viewMatrix[2][2]);

    // T = J·W (2×3)
    float t00 = j00*W[0][0] + j02*W[2][0], t01 = j00*W[0][1] + j02*W[2][1], t02 = j00*W[0][2] + j02*W[2][2];
    float t10 = j11*W[1][0] + j12*W[2][0], t11 = j11*W[1][1] + j12*W[2][1], t12 = j11*W[1][2] + j12*W[2][2];

    // ── dL/d(cov2d) → dL/d(cov3d) ──
    // cov2d = T · cov3d · T^T
    // For symmetric cov3d stored as [s00,s01,s02,s11,s12,s22]:
    float dL_s00 = dL_c00*t00*t00 + dL_c11*t10*t10 + dL_c01*t00*t10;
    float dL_s01 = dL_c00*2.0f*t00*t01 + dL_c11*2.0f*t10*t11 + dL_c01*(t00*t11 + t01*t10);
    float dL_s02 = dL_c00*2.0f*t00*t02 + dL_c11*2.0f*t10*t12 + dL_c01*(t00*t12 + t02*t10);
    float dL_s11 = dL_c00*t01*t01 + dL_c11*t11*t11 + dL_c01*t01*t11;
    float dL_s12 = dL_c00*2.0f*t01*t02 + dL_c11*2.0f*t11*t12 + dL_c01*(t01*t12 + t02*t11);
    float dL_s22 = dL_c00*t02*t02 + dL_c11*t12*t12 + dL_c01*t02*t12;

    // ── Rotation matrix ──
    float3x3 Rot;
    quat_to_rotation(quat, Rot);

    // ── dL/d(scale) ──
    // cov3d_kl = Σ_i R_ki * R_li * s_i²
    // d(cov3d_kl)/d(s_j) = 2 * s_j * R_kj * R_lj
    float scale_vals[3] = {sx, sy, sz};
    for (int j = 0; j < 3; j++) {
        float s_j = scale_vals[j];
        float ds = 0.0f;
        ds += dL_s00 * 2.0f * s_j * Rot[0][j] * Rot[0][j];
        ds += dL_s01 * 2.0f * s_j * Rot[0][j] * Rot[1][j];
        ds += dL_s02 * 2.0f * s_j * Rot[0][j] * Rot[2][j];
        ds += dL_s11 * 2.0f * s_j * Rot[1][j] * Rot[1][j];
        ds += dL_s12 * 2.0f * s_j * Rot[1][j] * Rot[2][j];
        ds += dL_s22 * 2.0f * s_j * Rot[2][j] * Rot[2][j];

        // Chain rule for log reparameterization: dL/d(log_s) = dL/d(s) × s
        atomic_add_float(&gradient_buffer[base + 7 + j], ds * s_j);
    }

    // ── dL/d(rotation) via dL/d(R) → dL/d(quaternion) ──
    // First compute dL/d(R_mn):
    float dL_dR[9] = {};
    for (int m = 0; m < 3; m++) {
        for (int n = 0; n < 3; n++) {
            float s_n2 = scale_vals[n] * scale_vals[n];
            float d = 0.0f;
            if (m == 0) d += dL_s00 * 2.0f * s_n2 * Rot[0][n];
            if (m == 1) d += dL_s11 * 2.0f * s_n2 * Rot[1][n];
            if (m == 2) d += dL_s22 * 2.0f * s_n2 * Rot[2][n];
            d += dL_s01 * s_n2 * ((m==0 ? Rot[1][n] : 0.0f) + (m==1 ? Rot[0][n] : 0.0f));
            d += dL_s02 * s_n2 * ((m==0 ? Rot[2][n] : 0.0f) + (m==2 ? Rot[0][n] : 0.0f));
            d += dL_s12 * s_n2 * ((m==1 ? Rot[2][n] : 0.0f) + (m==2 ? Rot[1][n] : 0.0f));
            dL_dR[m*3+n] = d;
        }
    }

    // dR/d(quaternion): analytical derivatives
    float qw = quat.x, qx = quat.y, qy = quat.z, qz = quat.w;
    float dL_dqw = 0, dL_dqx = 0, dL_dqy = 0, dL_dqz = 0;

    // R00: dR00/dy=-4y, dR00/dz=-4z
    dL_dqy += dL_dR[0] * (-4.0f*qy);
    dL_dqz += dL_dR[0] * (-4.0f*qz);
    // R01: dR01/dw=-2z, dR01/dx=2y, dR01/dy=2x, dR01/dz=-2w
    dL_dqw += dL_dR[1] * (-2.0f*qz);
    dL_dqx += dL_dR[1] * (2.0f*qy);
    dL_dqy += dL_dR[1] * (2.0f*qx);
    dL_dqz += dL_dR[1] * (-2.0f*qw);
    // R02: dR02/dw=2y, dR02/dx=2z, dR02/dy=2w, dR02/dz=2x
    dL_dqw += dL_dR[2] * (2.0f*qy);
    dL_dqx += dL_dR[2] * (2.0f*qz);
    dL_dqy += dL_dR[2] * (2.0f*qw);
    dL_dqz += dL_dR[2] * (2.0f*qx);
    // R10: dR10/dw=2z, dR10/dx=2y, dR10/dy=2x, dR10/dz=2w
    dL_dqw += dL_dR[3] * (2.0f*qz);
    dL_dqx += dL_dR[3] * (2.0f*qy);
    dL_dqy += dL_dR[3] * (2.0f*qx);
    dL_dqz += dL_dR[3] * (2.0f*qw);
    // R11: dR11/dx=-4x, dR11/dz=-4z
    dL_dqx += dL_dR[4] * (-4.0f*qx);
    dL_dqz += dL_dR[4] * (-4.0f*qz);
    // R12: dR12/dw=-2x, dR12/dx=-2w, dR12/dy=2z, dR12/dz=2y
    dL_dqw += dL_dR[5] * (-2.0f*qx);
    dL_dqx += dL_dR[5] * (-2.0f*qw);
    dL_dqy += dL_dR[5] * (2.0f*qz);
    dL_dqz += dL_dR[5] * (2.0f*qy);
    // R20: dR20/dw=-2y, dR20/dx=2z, dR20/dy=-2w, dR20/dz=2x
    dL_dqw += dL_dR[6] * (-2.0f*qy);
    dL_dqx += dL_dR[6] * (2.0f*qz);
    dL_dqy += dL_dR[6] * (-2.0f*qw);
    dL_dqz += dL_dR[6] * (2.0f*qx);
    // R21: dR21/dw=2x, dR21/dx=2w, dR21/dy=2z, dR21/dz=2y
    dL_dqw += dL_dR[7] * (2.0f*qx);
    dL_dqx += dL_dR[7] * (2.0f*qw);
    dL_dqy += dL_dR[7] * (2.0f*qz);
    dL_dqz += dL_dR[7] * (2.0f*qy);
    // R22: dR22/dx=-4x, dR22/dy=-4y
    dL_dqx += dL_dR[8] * (-4.0f*qx);
    dL_dqy += dL_dR[8] * (-4.0f*qy);

    atomic_add_float(&gradient_buffer[base+10], dL_dqw);
    atomic_add_float(&gradient_buffer[base+11], dL_dqx);
    atomic_add_float(&gradient_buffer[base+12], dL_dqy);
    atomic_add_float(&gradient_buffer[base+13], dL_dqz);
}

kernel void radixSortClearHistogram(
    device atomic_uint*     histogram    [[buffer(0)]],
    uint gid                             [[thread_position_in_grid]])
{
    if (gid < 256) {
        atomic_store_explicit(&histogram[gid], 0u, memory_order_relaxed);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Depth Supervision — Dual Depth Source (DAv2 + LiDAR)
// ═══════════════════════════════════════════════════════════════════════
//
// Kernel A: Partial Pearson reduction (per-threadgroup)
// Kernel B: Final Pearson reduction (single threadgroup)
// Kernel C: Depth gradient computation (dual-path: Pearson + L1)
// Kernel D: Tangent-plane gradient projection (GeoSplat)
//
// Reference: depth_loss.h (CPU Pearson implementation = validation baseline)

// ── Kernel A: depthPearsonReducePartial ──
// Each threadgroup reduces 256 pixels → 7 partial sums.
// 7 outputs per group: [sum_r, sum_d, sum_rr, sum_dd, sum_rd, valid_count, _pad]

kernel void depthPearsonReducePartial(
    device const float*       rendered_depth [[buffer(0)]],   // W×H
    device const float*       ref_depth      [[buffer(1)]],   // refW×refH (DAv2)
    device float*             partial_sums   [[buffer(2)]],   // (num_groups × 7)
    constant DepthConfig&     config         [[buffer(3)]],
    uint gid                                 [[thread_position_in_grid]],
    uint lid                                 [[thread_position_in_threadgroup]],
    uint tgid                                [[threadgroup_position_in_grid]])
{
    uint npix = config.renderWidth * config.renderHeight;

    // Each thread processes one pixel
    float val_r = 0.0f, val_d = 0.0f;
    bool pixel_valid = false;

    if (gid < npix) {
        float rd = rendered_depth[gid];
        if (rd > 0.0f) {
            // Nearest-neighbor resample ref_depth to render resolution
            uint px_x = gid % config.renderWidth;
            uint px_y = gid / config.renderWidth;
            uint rx = min(uint(float(px_x) * float(config.refDepthWidth) / float(config.renderWidth)),
                         config.refDepthWidth - 1u);
            uint ry = min(uint(float(px_y) * float(config.refDepthHeight) / float(config.renderHeight)),
                         config.refDepthHeight - 1u);
            float dd = ref_depth[ry * config.refDepthWidth + rx];
            if (dd > 0.0f) {
                val_r = rd;
                val_d = dd;
                pixel_valid = true;
            }
        }
    }

    // Threadgroup tree reduction (256 threads)
    threadgroup float tg_sum_r[256];
    threadgroup float tg_sum_d[256];
    threadgroup float tg_sum_rr[256];
    threadgroup float tg_sum_dd[256];
    threadgroup float tg_sum_rd[256];
    threadgroup float tg_count[256];

    tg_sum_r[lid]  = pixel_valid ? val_r : 0.0f;
    tg_sum_d[lid]  = pixel_valid ? val_d : 0.0f;
    tg_sum_rr[lid] = pixel_valid ? val_r * val_r : 0.0f;
    tg_sum_dd[lid] = pixel_valid ? val_d * val_d : 0.0f;
    tg_sum_rd[lid] = pixel_valid ? val_r * val_d : 0.0f;
    tg_count[lid]  = pixel_valid ? 1.0f : 0.0f;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Binary tree reduction
    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (lid < stride) {
            tg_sum_r[lid]  += tg_sum_r[lid + stride];
            tg_sum_d[lid]  += tg_sum_d[lid + stride];
            tg_sum_rr[lid] += tg_sum_rr[lid + stride];
            tg_sum_dd[lid] += tg_sum_dd[lid + stride];
            tg_sum_rd[lid] += tg_sum_rd[lid + stride];
            tg_count[lid]  += tg_count[lid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Thread 0 writes partial results
    if (lid == 0) {
        uint base = tgid * 7;
        partial_sums[base + 0] = tg_sum_r[0];
        partial_sums[base + 1] = tg_sum_d[0];
        partial_sums[base + 2] = tg_sum_rr[0];
        partial_sums[base + 3] = tg_sum_dd[0];
        partial_sums[base + 4] = tg_sum_rd[0];
        partial_sums[base + 5] = tg_count[0];
        partial_sums[base + 6] = 0.0f;  // padding
    }
}

// ── Kernel B: depthPearsonReduceFinal ──
// Single threadgroup reduces all partial sums → 8 global statistics.
// Output depth_stats[0..7]:
//   [0] mean_r, [1] mean_d, [2] std_r, [3] std_d,
//   [4] pearson, [5] inv_n_sr_sd, [6] rho_sd_over_sr, [7] valid_count

kernel void depthPearsonReduceFinal(
    device const float*       partial_sums  [[buffer(0)]],   // (num_groups × 7)
    device float*             depth_stats   [[buffer(1)]],   // 8 floats
    constant uint&            num_groups    [[buffer(2)]],
    uint lid                                [[thread_position_in_threadgroup]])
{
    // Each thread accumulates a strided subset of partial results
    float local_sum_r = 0.0f, local_sum_d = 0.0f;
    float local_sum_rr = 0.0f, local_sum_dd = 0.0f, local_sum_rd = 0.0f;
    float local_count = 0.0f;

    for (uint i = lid; i < num_groups; i += 256) {
        uint base = i * 7;
        local_sum_r  += partial_sums[base + 0];
        local_sum_d  += partial_sums[base + 1];
        local_sum_rr += partial_sums[base + 2];
        local_sum_dd += partial_sums[base + 3];
        local_sum_rd += partial_sums[base + 4];
        local_count  += partial_sums[base + 5];
    }

    // Threadgroup reduction
    threadgroup float tg_r[256], tg_d[256], tg_rr[256], tg_dd[256], tg_rd[256], tg_c[256];
    tg_r[lid] = local_sum_r;  tg_d[lid] = local_sum_d;
    tg_rr[lid] = local_sum_rr; tg_dd[lid] = local_sum_dd;
    tg_rd[lid] = local_sum_rd; tg_c[lid] = local_count;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (lid < stride) {
            tg_r[lid]  += tg_r[lid + stride];
            tg_d[lid]  += tg_d[lid + stride];
            tg_rr[lid] += tg_rr[lid + stride];
            tg_dd[lid] += tg_dd[lid + stride];
            tg_rd[lid] += tg_rd[lid + stride];
            tg_c[lid]  += tg_c[lid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Thread 0 computes final statistics
    if (lid == 0) {
        float N = tg_c[0];

        // Safety: too few valid pixels → output all zeros
        if (N < 16.0f) {
            for (uint i = 0; i < 8; i++) depth_stats[i] = 0.0f;
            return;
        }

        float mean_r = tg_r[0] / N;
        float mean_d = tg_d[0] / N;

        // Var = E[X²] - E[X]²  (numerically stable: use sum/N form)
        float var_r = tg_rr[0] / N - mean_r * mean_r;
        float var_d = tg_dd[0] / N - mean_d * mean_d;

        float std_r = sqrt(max(var_r, 1e-12f));
        float std_d = sqrt(max(var_d, 1e-12f));

        // Degenerate case: constant depth → no useful Pearson signal
        if (std_r < 1e-6f || std_d < 1e-6f) {
            for (uint i = 0; i < 8; i++) depth_stats[i] = 0.0f;
            return;
        }

        float cov_rd = tg_rd[0] / N - mean_r * mean_d;
        float pearson = cov_rd / (std_r * std_d);
        pearson = clamp(pearson, -1.0f, 1.0f);

        // NaN safety
        if (!isfinite(pearson)) {
            for (uint i = 0; i < 8; i++) depth_stats[i] = 0.0f;
            return;
        }

        float inv_n_sr_sd = 1.0f / (N * std_r * std_d);
        float rho_sd_over_sr = pearson * std_d / std_r;

        depth_stats[0] = mean_r;
        depth_stats[1] = mean_d;
        depth_stats[2] = std_r;
        depth_stats[3] = std_d;
        depth_stats[4] = pearson;
        depth_stats[5] = inv_n_sr_sd;
        depth_stats[6] = rho_sd_over_sr;
        depth_stats[7] = N;
    }
}

// ── Kernel C: depthGradientCompute (dual-path: DAv2 Pearson + LiDAR L1) ──
// Per-pixel depth gradient with edge-aware modulation (DN-Splatter / DET-GS).
// Path A: Pearson correlation gradient (DAv2 relative depth, 100% experience)
// Path B: L1 metric gradient (LiDAR metric depth, 120% enhancement, Pro only)
// Outputs combined gradient to depth_grad buffer → consumed by backwardRasterize.

kernel void depthGradientCompute(
    device const float*       rendered_depth [[buffer(0)]],   // W×H
    device const float*       ref_depth      [[buffer(1)]],   // refW×refH (DAv2 relative)
    device const float*       depth_stats    [[buffer(2)]],   // 8 floats from reduce
    device const float*       target_image   [[buffer(3)]],   // W×H×3 (for edge detection)
    device float*             depth_grad     [[buffer(4)]],   // W×H output
    constant DepthConfig&     config         [[buffer(5)]],
    device const float*       lidar_depth    [[buffer(6)]],   // lidarW×lidarH (LiDAR metric)
    uint gid                                 [[thread_position_in_grid]])
{
    uint npix = config.renderWidth * config.renderHeight;
    if (gid >= npix) {
        return;
    }

    float rd = rendered_depth[gid];
    if (rd <= 0.0f) {
        depth_grad[gid] = 0.0f;
        return;
    }

    // Load Pearson statistics
    float mean_r       = depth_stats[0];
    float mean_d       = depth_stats[1];
    float inv_n_sr_sd  = depth_stats[5];
    float rho_sd_sr    = depth_stats[6];
    float valid_n      = depth_stats[7];

    uint px_x = gid % config.renderWidth;
    uint px_y = gid / config.renderWidth;

    float grad = 0.0f;

    // ── Path A: DAv2 Pearson gradient (100% experience, all phones) ──
    if (config.hasRelativeDepth > 0 && valid_n >= 16.0f && abs(inv_n_sr_sd) > 1e-12f) {
        uint rx = min(uint(float(px_x) * float(config.refDepthWidth) / float(config.renderWidth)),
                     config.refDepthWidth - 1u);
        uint ry = min(uint(float(px_y) * float(config.refDepthHeight) / float(config.renderHeight)),
                     config.refDepthHeight - 1u);
        float dd = ref_depth[ry * config.refDepthWidth + rx];
        if (dd > 0.0f) {
            float d_pearson_d_ri = inv_n_sr_sd * ((dd - mean_d) - rho_sd_sr * (rd - mean_r));
            grad += -config.depthLambda * d_pearson_d_ri;
        }
    }

    // ── Path B: LiDAR L1 metric gradient (120% enhancement, Pro only) ──
    if (config.hasMetricDepth > 0) {
        uint lx = min(uint(float(px_x) * float(config.lidarWidth) / float(config.renderWidth)),
                     config.lidarWidth - 1u);
        uint ly = min(uint(float(px_y) * float(config.lidarHeight) / float(config.renderHeight)),
                     config.lidarHeight - 1u);
        float ld = lidar_depth[ly * config.lidarWidth + lx];
        if (ld > 0.1f && ld < 8.0f) {
            float diff = rd - ld;
            // L1 gradient: sign(diff) with smooth transition near zero
            float l1_grad = clamp(diff * 10.0f, -1.0f, 1.0f);  // Smooth L1 approximation
            grad += config.lidarLambda * l1_grad;
        }
    }

    // ── Layer 2: Edge-aware modulation (DN-Splatter / DET-GS) ──
    // Reduce depth constraint at image edges to avoid conflicting with photometric detail.
    if (abs(grad) > 1e-10f && config.edgeBeta > 0.0f) {
        // Sobel operator on target image luminance
        float edge_mag = 0.0f;
        if (px_x > 0 && px_x < config.renderWidth - 1 &&
            px_y > 0 && px_y < config.renderHeight - 1) {
            uint w = config.renderWidth;
            // Luminance at 3×3 neighborhood
            float lum_tl = 0.299f * target_image[((px_y-1)*w + px_x-1)*3]
                         + 0.587f * target_image[((px_y-1)*w + px_x-1)*3+1]
                         + 0.114f * target_image[((px_y-1)*w + px_x-1)*3+2];
            float lum_tr = 0.299f * target_image[((px_y-1)*w + px_x+1)*3]
                         + 0.587f * target_image[((px_y-1)*w + px_x+1)*3+1]
                         + 0.114f * target_image[((px_y-1)*w + px_x+1)*3+2];
            float lum_bl = 0.299f * target_image[((px_y+1)*w + px_x-1)*3]
                         + 0.587f * target_image[((px_y+1)*w + px_x-1)*3+1]
                         + 0.114f * target_image[((px_y+1)*w + px_x-1)*3+2];
            float lum_br = 0.299f * target_image[((px_y+1)*w + px_x+1)*3]
                         + 0.587f * target_image[((px_y+1)*w + px_x+1)*3+1]
                         + 0.114f * target_image[((px_y+1)*w + px_x+1)*3+2];
            float lum_ml = 0.299f * target_image[(px_y*w + px_x-1)*3]
                         + 0.587f * target_image[(px_y*w + px_x-1)*3+1]
                         + 0.114f * target_image[(px_y*w + px_x-1)*3+2];
            float lum_mr = 0.299f * target_image[(px_y*w + px_x+1)*3]
                         + 0.587f * target_image[(px_y*w + px_x+1)*3+1]
                         + 0.114f * target_image[(px_y*w + px_x+1)*3+2];
            float lum_tc = 0.299f * target_image[((px_y-1)*w + px_x)*3]
                         + 0.587f * target_image[((px_y-1)*w + px_x)*3+1]
                         + 0.114f * target_image[((px_y-1)*w + px_x)*3+2];
            float lum_bc = 0.299f * target_image[((px_y+1)*w + px_x)*3]
                         + 0.587f * target_image[((px_y+1)*w + px_x)*3+1]
                         + 0.114f * target_image[((px_y+1)*w + px_x)*3+2];

            // Sobel Gx = [-1 0 +1; -2 0 +2; -1 0 +1]
            float gx = -lum_tl + lum_tr - 2.0f*lum_ml + 2.0f*lum_mr - lum_bl + lum_br;
            // Sobel Gy = [-1 -2 -1; 0 0 0; +1 +2 +1]
            float gy = -lum_tl - 2.0f*lum_tc - lum_tr + lum_bl + 2.0f*lum_bc + lum_br;
            edge_mag = sqrt(gx*gx + gy*gy);
        }
        float edge_weight = exp(-config.edgeBeta * edge_mag);
        grad *= edge_weight;
    }

    // Gradient clamp (Layer 6: safety)
    grad = clamp(grad, -config.gradClamp, config.gradClamp);

    depth_grad[gid] = grad;
}

// ── Kernel D: projectGradientsToTangentPlane (GeoSplat) ──
// Projects position gradients onto the tangent plane of each Gaussian.
// Prevents Gaussians from drifting away from their surface (Layer 4).
// Normal is derived from the quaternion rotation (3rd column of R = shortest axis).

kernel void projectGradientsToTangentPlane(
    device const float*   params           [[buffer(0)]],  // N × 14 (read-only)
    device float*         grads            [[buffer(1)]],  // N × 14 (read-write: position grads modified)
    constant uint&        num_gaussians    [[buffer(2)]],
    uint gid                               [[thread_position_in_grid]])
{
    if (gid >= num_gaussians) return;

    uint base = gid * 14;

    // Read quaternion (wxyz convention)
    float qw = params[base + 10];
    float qx = params[base + 11];
    float qy = params[base + 12];
    float qz = params[base + 13];

    // Build rotation matrix 3rd column (normal = R × [0,0,1])
    // R[*][2] = [2(xz+wy), 2(yz-wx), 1-2(xx+yy)]
    float nx = 2.0f * (qx*qz + qw*qy);
    float ny = 2.0f * (qy*qz - qw*qx);
    float nz = 1.0f - 2.0f * (qx*qx + qy*qy);

    // Normalize normal (should already be unit, but safety)
    float n_len = sqrt(nx*nx + ny*ny + nz*nz);
    if (n_len < 1e-8f) return;  // Degenerate quaternion — skip
    float inv_len = 1.0f / n_len;
    nx *= inv_len;
    ny *= inv_len;
    nz *= inv_len;

    // Read position gradients
    float gx = grads[base + 0];
    float gy = grads[base + 1];
    float gz = grads[base + 2];

    // Project to tangent plane: projected = grad - dot(grad, normal) × normal
    float dot_gn = gx*nx + gy*ny + gz*nz;
    grads[base + 0] = gx - dot_gn * nx;
    grads[base + 1] = gy - dot_gn * ny;
    grads[base + 2] = gz - dot_gn * nz;
}
