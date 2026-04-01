// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TRAINING_MVS_INITIALIZER_H
#define AETHER_TRAINING_MVS_INITIALIZER_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "aether/core/status.h"
#include "aether/splat/packed_splats.h"

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// MVS Initializer: Dense point cloud from multi-view stereo
// ═══════════════════════════════════════════════════════════════════════
// PocketGS strategy: Census Transform + plane-sweep stereo with correct
// homography reprojection between views.
//
// Role in initialization pipeline:
//   Primary: DAv2 direct initialization (50K-100K+ points)
//   This module: Geometric verification + supplement when DAv2 insufficient
//   When DAv2 prior available: narrowed depth sweep (±30%, ~24 levels)
//   When no DAv2: full-range plane sweep (128 levels, fallback path)
//
// Runs on CPU as one-time initialization (~10s for 20 frames on A16).

struct MVSConfig {
    std::uint32_t depth_width{640};       // Depth map resolution
    std::uint32_t depth_height{480};
    float min_depth{0.1f};                // Near plane (meters)
    float max_depth{10.0f};               // Far plane (meters)
    std::uint32_t num_depth_levels{128};  // Full-range sweep levels
    std::uint32_t census_window{9};       // Census transform window size
    float consistency_threshold{3.0f};    // Cost filter threshold (×32)
    float initial_scale{0.01f};           // Initial Gaussian scale (fallback)
    float initial_opacity{0.8f};          // Initial opacity (higher for visible color)
    // DAv2 prior integration
    float dav2_prior_range{0.3f};         // ±30% around DAv2 depth
    std::uint32_t dav2_prior_levels{24};  // Levels when using DAv2 prior
};

/// Input frame for MVS.
struct MVSFrame {
    const std::uint8_t* rgba;    // RGBA image data
    std::uint32_t width;
    std::uint32_t height;
    float transform[16];         // Camera-to-world (column-major 4x4)
    float intrinsics[4];         // [fx, fy, cx, cy]
    // ─── Depth prior (optional) ───
    // Historically this slot carried DAv2 relative depth. Imported-video
    // local_preview now frequently hands us metric depth that already went
    // through the native reciprocal-affine conversion, so the primary MVS
    // initializer must accept both forms instead of silently ignoring the
    // metric case.
    const float* dav2_depth{nullptr};  // Relative or metric depth, row-major
    std::uint32_t dav2_w{0};
    std::uint32_t dav2_h{0};
    bool dav2_is_metric{false};        // true = meters, false = relative/inv-depth-like
    float dav2_scale{1.0f};            // Affine: metric = scale * d_pred + shift
    float dav2_shift{0.0f};            // Affine shift (accounts for min-max normalization)
};

/// Census Transform (9x9 window → 64-bit descriptor).
inline std::uint64_t census_transform(const std::uint8_t* gray,
                                       std::uint32_t w, std::uint32_t h,
                                       std::uint32_t x, std::uint32_t y,
                                       std::uint32_t radius) noexcept {
    std::uint64_t descriptor = 0;
    std::uint8_t center = gray[y * w + x];
    std::uint32_t bit = 0;

    for (std::uint32_t dy = 0; dy <= 2 * radius && bit < 64; ++dy) {
        for (std::uint32_t dx = 0; dx <= 2 * radius && bit < 64; ++dx) {
            if (dy == radius && dx == radius) continue;  // skip center
            std::int32_t py = static_cast<std::int32_t>(y) +
                              static_cast<std::int32_t>(dy) -
                              static_cast<std::int32_t>(radius);
            std::int32_t px = static_cast<std::int32_t>(x) +
                              static_cast<std::int32_t>(dx) -
                              static_cast<std::int32_t>(radius);
            if (py >= 0 && py < static_cast<std::int32_t>(h) &&
                px >= 0 && px < static_cast<std::int32_t>(w)) {
                if (gray[py * w + px] < center) {
                    descriptor |= (1ULL << bit);
                }
            }
            bit++;
        }
    }
    return descriptor;
}

/// Hamming distance for Census matching.
inline std::uint32_t hamming_distance(std::uint64_t a, std::uint64_t b) noexcept {
#if defined(__GNUC__) || defined(__clang__)
    return static_cast<std::uint32_t>(__builtin_popcountll(a ^ b));
#else
    std::uint64_t xor_val = a ^ b;
    std::uint32_t count = 0;
    while (xor_val) {
        count += xor_val & 1;
        xor_val >>= 1;
    }
    return count;
#endif
}

/// RGB to grayscale (luminance).
inline void rgb_to_gray(const std::uint8_t* rgba, std::uint32_t w,
                          std::uint32_t h, std::uint8_t* gray) noexcept {
    for (std::uint32_t i = 0; i < w * h; ++i) {
        // BGRA → RGB: Swift passes kCVPixelFormatType_32BGRA
        std::uint32_t r = rgba[i * 4 + 2];  // R is at offset 2
        std::uint32_t g = rgba[i * 4 + 1];  // G is at offset 1
        std::uint32_t b = rgba[i * 4 + 0];  // B is at offset 0
        gray[i] = static_cast<std::uint8_t>((r * 77 + g * 150 + b * 29) >> 8);
    }
}

/// sRGB → linear conversion.
inline float mvs_srgb_to_linear(float s) noexcept {
    return s <= 0.04045f ? s / 12.92f : std::pow((s + 0.055f) / 1.055f, 2.4f);
}

/// Unproject a depth pixel to world-space point in the repo's ARKit camera
/// convention: image Y grows down, camera Y grows up, visible points lie at
/// negative camera Z, and cam2world column 2 stores back (= -forward).
inline void unproject_pixel(std::uint32_t x, std::uint32_t y, float depth,
                             const float intrinsics[4],
                             const float transform[16],
                             float world_pos[3]) noexcept {
    // Camera-space point
    float cx = (static_cast<float>(x) - intrinsics[2]) / intrinsics[0] * depth;
    float cy = -(static_cast<float>(y) - intrinsics[3]) / intrinsics[1] * depth;
    float cz = -depth;

    // Transform to world (column-major 4x4)
    world_pos[0] = transform[0] * cx + transform[4] * cy +
                   transform[8] * cz + transform[12];
    world_pos[1] = transform[1] * cx + transform[5] * cy +
                   transform[9] * cz + transform[13];
    world_pos[2] = transform[2] * cx + transform[6] * cy +
                   transform[10] * cz + transform[14];
}

/// Reproject a reference pixel (at depth hypothesis) to a source frame.
///
/// Plane-sweep stereo reprojection:
///   1. Backproject ref pixel to camera space: X_ref = K_ref⁻¹ × [u,v,1] × d
///   2. Transform to world: X_world = T_ref × X_ref
///   3. Transform to source camera: X_src = R_src^T × (X_world - t_src)
///   4. Project to source image: [u',v'] = K_src × X_src / z_src
///
/// @return false if point is behind source camera or outside image bounds
inline bool reproject_to_source(
    float ref_x, float ref_y, float depth,
    const float ref_intr[4], const float ref_T[16],
    const float src_intr[4], const float src_T[16],
    std::uint32_t src_w, std::uint32_t src_h,
    std::uint32_t border,
    float& out_sx, float& out_sy) noexcept
{
    // Step 1: Backproject to ref camera space
    float cx = (ref_x - ref_intr[2]) / ref_intr[0] * depth;
    float cy = -(ref_y - ref_intr[3]) / ref_intr[1] * depth;
    float cz = -depth;

    // Step 2: Ref camera → world (column-major 4x4)
    float wx = ref_T[0]*cx + ref_T[4]*cy + ref_T[8]*cz  + ref_T[12];
    float wy = ref_T[1]*cx + ref_T[5]*cy + ref_T[9]*cz  + ref_T[13];
    float wz = ref_T[2]*cx + ref_T[6]*cy + ref_T[10]*cz + ref_T[14];

    // Step 3: World → source camera via R_src^T × (X_world - t_src)
    // Column-major layout: rotation cols = T[0..2], T[4..6], T[8..10]
    // R^T rows = those same vectors read as rows
    float dwx = wx - src_T[12];
    float dwy = wy - src_T[13];
    float dwz = wz - src_T[14];
    float scx = src_T[0]*dwx + src_T[1]*dwy + src_T[2]*dwz;
    float scy = src_T[4]*dwx + src_T[5]*dwy + src_T[6]*dwz;   // camera Y-up
    float scz = -(src_T[8]*dwx + src_T[9]*dwy + src_T[10]*dwz); // positive depth

    // Behind source camera
    if (scz < 0.01f) return false;

    // Step 4: Project to source image
    float inv_z = 1.0f / scz;
    out_sx = src_intr[0] * scx * inv_z + src_intr[2];
    out_sy = src_intr[1] * (-scy) * inv_z + src_intr[3];

    // Bounds check (with border margin for Census window)
    float fb = static_cast<float>(border);
    if (out_sx < fb || out_sx >= static_cast<float>(src_w) - fb ||
        out_sy < fb || out_sy >= static_cast<float>(src_h) - fb) {
        return false;
    }

    return true;
}

/// Initialize dense Gaussians from multi-view frames.
///
/// Corrected plane-sweep stereo algorithm:
/// 1. Pre-compute all grayscale images (once, outside sweep loop)
/// 2. For each ref pixel: determine depth sweep range
///    - DAv2 prior available: ±30% around prior, ~24 levels (6× faster)
///    - No prior: full 128 levels
/// 3. For each depth hypothesis:
///    a. Backproject ref pixel to 3D via ref camera intrinsics + transform
///    b. Reproject to each source frame via world→source projection
///    c. Census match at correctly reprojected source location
/// 4. Best depth by minimum aggregated cost
/// 5. Consistency filtering
/// 6. Unproject surviving pixels to 3D Gaussians with sRGB→linear color
/// 7. Adaptive scale post-pass (density-based)
inline core::Status mvs_initialize(
    const MVSFrame* frames,
    std::size_t frame_count,
    const MVSConfig& config,
    std::vector<splat::GaussianParams>& out_points) noexcept
{
    out_points.clear();

    if (frame_count < 3) return core::Status::kInvalidArgument;

    // Use middle frame as reference
    std::size_t ref_idx = frame_count / 2;
    const MVSFrame& ref = frames[ref_idx];

    std::uint32_t dw = config.depth_width;
    std::uint32_t dh = config.depth_height;

    // Downscale reference to depth resolution
    float scale_x = static_cast<float>(ref.width) / dw;
    float scale_y = static_cast<float>(ref.height) / dh;

    // Scaled intrinsics for depth resolution (used for final unprojection)
    float ref_scaled_intr[4] = {
        ref.intrinsics[0] / scale_x,
        ref.intrinsics[1] / scale_y,
        ref.intrinsics[2] / scale_x,
        ref.intrinsics[3] / scale_y
    };

    // ─── Pre-compute ALL grayscale images ONCE ───
    // Critical fix: old code allocated src_gray INSIDE the depth×source loop
    // = O(D × S × W × H) allocations. Now: O(F × W × H) total, done once.
    std::vector<std::vector<std::uint8_t>> gray_images(frame_count);
    for (std::size_t i = 0; i < frame_count; ++i) {
        gray_images[i].resize(frames[i].width * frames[i].height);
        rgb_to_gray(frames[i].rgba, frames[i].width, frames[i].height,
                     gray_images[i].data());
    }

    // Full-range depth levels (uniform in inverse depth for uniform disparity)
    std::vector<float> full_depth_levels(config.num_depth_levels);
    float inv_min = 1.0f / config.max_depth;
    float inv_max = 1.0f / config.min_depth;
    for (std::uint32_t d = 0; d < config.num_depth_levels; ++d) {
        float t = static_cast<float>(d) / (config.num_depth_levels - 1);
        full_depth_levels[d] = 1.0f / (inv_min + t * (inv_max - inv_min));
    }

    // Best depth per pixel (in depth-resolution grid)
    std::vector<float> best_depth(dw * dh, 0.0f);
    std::vector<float> best_cost(dw * dh, 1e9f);

    // Select source frames (nearest temporal neighbors to reference)
    std::size_t src_indices[4];
    std::size_t num_src = 0;
    if (ref_idx > 0) src_indices[num_src++] = ref_idx - 1;
    if (ref_idx + 1 < frame_count) src_indices[num_src++] = ref_idx + 1;
    if (ref_idx > 2) src_indices[num_src++] = ref_idx - 2;
    if (ref_idx + 2 < frame_count) src_indices[num_src++] = ref_idx + 2;

    if (num_src == 0) return core::Status::kInvalidArgument;

    // Check if DAv2 prior is available for the reference frame
    bool has_dav2_prior = (ref.dav2_depth != nullptr &&
                           ref.dav2_w > 0 && ref.dav2_h > 0);
    float dav2_to_depth_x = has_dav2_prior
        ? static_cast<float>(ref.dav2_w) / dw : 0.0f;
    float dav2_to_depth_y = has_dav2_prior
        ? static_cast<float>(ref.dav2_h) / dh : 0.0f;

    std::uint32_t dav2_prior_pixels = 0;
    std::uint32_t full_sweep_pixels = 0;

    // ─── Core plane-sweep loop (pixel-first for DAv2 prior adaptation) ───
    std::uint32_t census_r = config.census_window / 2;

    // Temp buffer for per-pixel depth levels when using DAv2 prior
    std::vector<float> pixel_levels;
    pixel_levels.reserve(config.num_depth_levels);

    for (std::uint32_t y = census_r; y < dh - census_r; ++y) {
        for (std::uint32_t x = census_r; x < dw - census_r; ++x) {
            std::size_t pidx = y * dw + x;

            // Reference pixel in full-resolution coordinates (for Census)
            std::uint32_t rx = static_cast<std::uint32_t>(x * scale_x);
            std::uint32_t ry = static_cast<std::uint32_t>(y * scale_y);
            if (rx >= ref.width) rx = ref.width - 1;
            if (ry >= ref.height) ry = ref.height - 1;

            // Bounds check for Census window in full-res
            if (rx < census_r || rx >= ref.width - census_r ||
                ry < census_r || ry >= ref.height - census_r) {
                continue;
            }

            std::uint64_t ref_census = census_transform(
                gray_images[ref_idx].data(), ref.width, ref.height,
                rx, ry, census_r);

            // ─── Determine depth levels for this pixel ───
            const float* levels_ptr = full_depth_levels.data();
            std::uint32_t n_levels = config.num_depth_levels;

            pixel_levels.clear();

            if (has_dav2_prior) {
                // Look up DAv2 depth at this pixel's position
                std::uint32_t ddx = static_cast<std::uint32_t>(x * dav2_to_depth_x);
                std::uint32_t ddy = static_cast<std::uint32_t>(y * dav2_to_depth_y);
                if (ddx >= ref.dav2_w) ddx = ref.dav2_w - 1;
                if (ddy >= ref.dav2_h) ddy = ref.dav2_h - 1;
                float prior_depth = 0.0f;
                if (ref.dav2_is_metric) {
                    prior_depth = ref.dav2_depth[ddy * ref.dav2_w + ddx];
                } else {
                    float rel_d = ref.dav2_depth[ddy * ref.dav2_w + ddx];
                    if (rel_d > 0.01f && rel_d < 0.99f) {
                        // Convert to metric prior depth (reciprocal affine in inv-depth space)
                        // 1/depth = scale * d + shift → depth = 1/(scale*d + shift)
                        float inv_d = rel_d * ref.dav2_scale + ref.dav2_shift;
                        prior_depth = (inv_d > 0.001f) ? (1.0f / inv_d) : 0.0f;
                    }
                }

                if (std::isfinite(prior_depth) &&
                    prior_depth >= config.min_depth &&
                    prior_depth <= config.max_depth) {
                    // Narrow sweep: ±range around prior
                    float d_lo = prior_depth * (1.0f - config.dav2_prior_range);
                    float d_hi = prior_depth * (1.0f + config.dav2_prior_range);
                    d_lo = std::max(d_lo, config.min_depth);
                    d_hi = std::min(d_hi, config.max_depth);

                    std::uint32_t nl = config.dav2_prior_levels;
                    pixel_levels.resize(nl);
                    for (std::uint32_t d = 0; d < nl; ++d) {
                        float t = static_cast<float>(d) / (nl - 1);
                        pixel_levels[d] = d_lo + t * (d_hi - d_lo);
                    }
                    levels_ptr = pixel_levels.data();
                    n_levels = nl;
                    dav2_prior_pixels++;
                }
            }

            if (pixel_levels.empty()) {
                // No DAv2 prior for this pixel → use full-range sweep
                levels_ptr = full_depth_levels.data();
                n_levels = config.num_depth_levels;
                full_sweep_pixels++;
            }

            // ─── Sweep depth levels ───
            for (std::uint32_t di = 0; di < n_levels; ++di) {
                float depth = levels_ptr[di];

                // Average matching cost across source views
                float total_cost = 0.0f;
                std::uint32_t valid_sources = 0;

                for (std::size_t s = 0; s < num_src; ++s) {
                    const MVSFrame& src = frames[src_indices[s]];

                    // ─── Correct reprojection: ref pixel → 3D → source pixel ───
                    // Uses full-res ref intrinsics + (rx,ry) for backprojection,
                    // and full-res src intrinsics for forward projection.
                    float proj_sx, proj_sy;
                    bool visible = reproject_to_source(
                        static_cast<float>(rx), static_cast<float>(ry), depth,
                        ref.intrinsics, ref.transform,
                        src.intrinsics, src.transform,
                        src.width, src.height,
                        census_r,
                        proj_sx, proj_sy);

                    if (!visible) continue;

                    // Census match at reprojected location (nearest pixel)
                    std::uint32_t sx = static_cast<std::uint32_t>(proj_sx + 0.5f);
                    std::uint32_t sy = static_cast<std::uint32_t>(proj_sy + 0.5f);

                    std::uint64_t src_census = census_transform(
                        gray_images[src_indices[s]].data(),
                        src.width, src.height, sx, sy, census_r);

                    total_cost += static_cast<float>(
                        hamming_distance(ref_census, src_census));
                    valid_sources++;
                }

                if (valid_sources == 0) continue;

                float avg_cost = total_cost / static_cast<float>(valid_sources);
                if (avg_cost < best_cost[pidx]) {
                    best_cost[pidx] = avg_cost;
                    best_depth[pidx] = depth;
                }
            }
        }
    }

    std::fprintf(stderr, "[Aether3D] MVS sweep: dav2_prior=%u full_sweep=%u pixels\n",
                 dav2_prior_pixels, full_sweep_pixels);

    // ─── Unproject to 3D Gaussians with sRGB → linear color ───
    out_points.reserve(dw * dh / 4);

    for (std::uint32_t y = census_r; y < dh - census_r; ++y) {
        for (std::uint32_t x = census_r; x < dw - census_r; ++x) {
            std::size_t pidx = y * dw + x;
            float depth = best_depth[pidx];
            float cost = best_cost[pidx];

            // Filter by consistency threshold
            if (depth <= 0.0f || cost > config.consistency_threshold * 32.0f) {
                continue;
            }

            // Unproject to world (depth-resolution coordinates + scaled intrinsics)
            splat::GaussianParams g{};
            unproject_pixel(x, y, depth, ref_scaled_intr, ref.transform, g.position);

            // Color from reference image (sRGB → linear)
            std::uint32_t rx = static_cast<std::uint32_t>(x * scale_x);
            std::uint32_t ry = static_cast<std::uint32_t>(y * scale_y);
            if (rx >= ref.width) rx = ref.width - 1;
            if (ry >= ref.height) ry = ref.height - 1;
            std::size_t cidx = (static_cast<std::size_t>(ry) * ref.width + rx) * 4;
            // BGRA → RGB: Swift passes kCVPixelFormatType_32BGRA
            g.color[0] = mvs_srgb_to_linear(ref.rgba[cidx + 2] / 255.0f);  // R
            g.color[1] = mvs_srgb_to_linear(ref.rgba[cidx + 1] / 255.0f);  // G
            g.color[2] = mvs_srgb_to_linear(ref.rgba[cidx + 0] / 255.0f);  // B

            g.opacity = config.initial_opacity;
            g.scale[0] = g.scale[1] = g.scale[2] = config.initial_scale;
            g.rotation[0] = 1.0f;  // Identity quaternion
            g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;

            out_points.push_back(g);
        }
    }

    if (out_points.empty()) return core::Status::kResourceExhausted;

    std::fprintf(stderr, "[Aether3D] MVS init: %zu points from %zu frames\n",
                 out_points.size(), frame_count);

    // ─── Post-pass: adaptive scale based on actual point cloud density ───
    // Fixed initial_scale fails when the scene extent varies widely.
    // Compute bounding sphere, then set scale = R × 2 / √N so Gaussians
    // overlap properly at the auto-fit camera distance.
    {
        const std::size_t N = out_points.size();
        double cx2 = 0, cy2 = 0, cz2 = 0;
        for (const auto& p : out_points) {
            cx2 += p.position[0];
            cy2 += p.position[1];
            cz2 += p.position[2];
        }
        double inv = 1.0 / static_cast<double>(N);
        float center_x = static_cast<float>(cx2 * inv);
        float center_y = static_cast<float>(cy2 * inv);
        float center_z = static_cast<float>(cz2 * inv);

        float max_d2 = 0.0f;
        for (const auto& p : out_points) {
            float dx2 = p.position[0] - center_x;
            float dy2 = p.position[1] - center_y;
            float dz2 = p.position[2] - center_z;
            float d2 = dx2 * dx2 + dy2 * dy2 + dz2 * dz2;
            if (d2 > max_d2) max_d2 = d2;
        }
        float radius = std::sqrt(max_d2);
        // Use cube root for 3D point cloud density (not sqrt which is 2D)
        // Scale ≈ mean inter-point spacing / 3 for sharp initial Gaussians
        float cbrt_n = std::cbrt(static_cast<float>(N));
        float adaptive = std::max(radius / (cbrt_n * 3.0f), 0.002f);
        adaptive = std::min(adaptive, std::max(radius * 0.05f, 0.005f));
        if (radius < 1e-4f) adaptive = config.initial_scale;

        for (auto& p : out_points) {
            p.scale[0] = p.scale[1] = p.scale[2] = adaptive;
        }

        std::fprintf(stderr, "[Aether3D] MVS init: adaptive_scale=%.4f "
                     "(radius=%.2f, N=%zu)\n", adaptive, radius, N);
    }

    return core::Status::kOk;
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_MVS_INITIALIZER_H
