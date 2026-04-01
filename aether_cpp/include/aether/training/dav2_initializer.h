// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TRAINING_DAV2_INITIALIZER_H
#define AETHER_TRAINING_DAV2_INITIALIZER_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <unordered_set>
#include <vector>

#include "aether/core/status.h"
#include "aether/pipeline/streaming_pipeline.h"
#include "aether/splat/packed_splats.h"

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// DAv2 Initializer: Dense point cloud from multi-frame monocular depth
// ═══════════════════════════════════════════════════════════════════════
// Converts monocular depth priors → metric 3D Gaussians via:
//   1. If needed, scale alignment: ARKit metric poses → relative→metric scale
//   2. Backprojection in the repo's ARKit convention:
//      x = (u-cx)/fx * depth, y = -(v-cy)/fy * depth, z = -depth
//      then camera → world through the column-major camera-to-world matrix
//   3. Spatial hash dedup: O(1) per point, prevents overlap
//   4. Color sampling: RGBA → sRGB→linear
//
// Designed for iPhone 12 (A14, no LiDAR): DAv2 is the ONLY dense depth.
// Produces 50K-100K+ initial Gaussians vs 200-500 from buggy MVS.

struct DAv2Config {
    float min_depth{0.1f};               // Metric depth lower bound (m)
    float max_depth{10.0f};              // Metric depth upper bound (m)
    float spatial_hash_cell{0.02f};      // Dedup grid cell size (m)
    float outlier_depth_sigma{2.5f};     // Depth outlier threshold (σ)
    float initial_scale{0.01f};          // Gaussian initial scale (fallback)
    float initial_opacity{0.7f};         // Higher than MVS (0.5) — DAv2 is denser
    std::uint32_t subsample_step{2};     // Skip pixels for density control (1=all, 2=every other)
    std::size_t max_points{200000};      // Cap total points
};

/// Estimate metric scale from multi-frame relative / disparity-like depth priors.
///
/// Strategy: ARKit poses are metric (meters). For two frames i,j:
///   baseline = ||t_i - t_j|| (meters)
///   For overlapping pixels: metric_depth ∝ baseline / disparity
///   scale = median(baselines / mean_relative_depth_diffs)
///
/// Falls back to scale=2.0 (typical indoor scene) if <2 frames.
inline float estimate_metric_scale(
    const pipeline::SelectedFrame* const* frames,
    std::size_t frame_count) noexcept
{
    if (frame_count < 2) return 2.0f;  // Fallback: assume ~2m mean depth

    // Collect pairwise scale estimates from consecutive frame pairs
    std::vector<float> scale_estimates;
    scale_estimates.reserve(frame_count - 1);

    for (std::size_t i = 0; i + 1 < frame_count; ++i) {
        const auto& f0 = *frames[i];
        const auto& f1 = *frames[i + 1];

        if (f0.ne_depth.empty() || f1.ne_depth.empty()) continue;
        if (f0.ne_depth_is_metric || f1.ne_depth_is_metric) continue;

        // Camera positions from transform column 3 (translation)
        float t0x = f0.transform[12], t0y = f0.transform[13], t0z = f0.transform[14];
        float t1x = f1.transform[12], t1y = f1.transform[13], t1z = f1.transform[14];

        float dx = t1x - t0x, dy = t1y - t0y, dz = t1z - t0z;
        float baseline = std::sqrt(dx * dx + dy * dy + dz * dz);

        // Skip near-zero baseline (same position)
        if (baseline < 0.005f) continue;

        // Compute mean relative depth for both frames
        auto mean_depth = [](const std::vector<float>& depth) -> float {
            double sum = 0.0;
            std::size_t count = 0;
            for (float d : depth) {
                if (d > 0.01f && d < 0.99f) {
                    sum += d;
                    count++;
                }
            }
            return count > 0 ? static_cast<float>(sum / count) : 0.5f;
        };

        float mean0 = mean_depth(f0.ne_depth);
        float mean1 = mean_depth(f1.ne_depth);
        float mean_rel = (mean0 + mean1) * 0.5f;

        // Scale = baseline / (mean_relative_depth × some_reference)
        // For DAv2: relative depth is inverse-depth-like, so:
        //   metric_depth = scale / relative_depth
        //   At mean depth: scale = baseline × mean_relative_depth / baseline_parallax_ratio
        // Simplified: scale ≈ baseline / (1.0 - mean_rel) for inverse depth
        // Or more robustly: assume mean scene depth ≈ baseline × focal / mean_disparity
        //
        // Simplified heuristic: scale makes mean relative depth → ~1-3m
        if (mean_rel > 0.01f) {
            // scale × mean_rel = expected metric mean depth
            // expected metric mean depth ≈ baseline × 5-15 (typical for scanning motion)
            // We use a conservative estimate
            float expected_depth = std::max(baseline * 10.0f, 0.5f);
            float scale = expected_depth / mean_rel;
            if (scale > 0.1f && scale < 100.0f) {
                scale_estimates.push_back(scale);
            }
        }
    }

    if (scale_estimates.empty()) return 2.0f;

    // Use median for robustness against outliers
    std::sort(scale_estimates.begin(), scale_estimates.end());
    return scale_estimates[scale_estimates.size() / 2];
}

/// sRGB → linear conversion (matches packed_splats.h conventions).
inline float srgb_to_linear(float s) noexcept {
    return s <= 0.04045f ? s / 12.92f : std::pow((s + 0.055f) / 1.055f, 2.4f);
}

/// Spatial hash key for dedup (Niessner-style prime hash).
inline std::int64_t dav2_spatial_key(float x, float y, float z,
                                      float cell_size) noexcept {
    auto ix = static_cast<std::int32_t>(std::floor(x / cell_size));
    auto iy = static_cast<std::int32_t>(std::floor(y / cell_size));
    auto iz = static_cast<std::int32_t>(std::floor(z / cell_size));
    return static_cast<std::int64_t>(ix) * 73856093LL
         ^ static_cast<std::int64_t>(iy) * 19349669LL
         ^ static_cast<std::int64_t>(iz) * 83492791LL;
}

/// Initialize dense Gaussians from multi-frame monocular depth prior.
///
/// Algorithm:
/// 1. Estimate metric scale from ARKit poses + relative depth (only if needed)
/// 2. For each frame with ne_depth:
///    a. Convert prior → metric depth
///    b. Backproject each pixel to 3D world coordinates
///    c. Spatial hash dedup (skip if cell already occupied)
///    d. Sample color from RGBA, convert sRGB → linear
/// 3. Adaptive Gaussian scale based on point cloud density
///
/// @param frames       Array of pointers to selected frames (zero-copy)
/// @param frame_count  Number of frames
/// @param config       DAv2 initialization configuration
/// @param out_points   Output: Gaussian parameters
/// @return kOk on success, kInvalidArgument if no depth data
inline core::Status dav2_initialize(
    const pipeline::SelectedFrame* const* frames,
    std::size_t frame_count,
    const DAv2Config& config,
    std::vector<splat::GaussianParams>& out_points) noexcept
{
    out_points.clear();

    // Count frames with depth
    std::size_t depth_frame_count = 0;
    for (std::size_t i = 0; i < frame_count; ++i) {
        if (!frames[i]->ne_depth.empty()) depth_frame_count++;
    }
    if (depth_frame_count == 0) return core::Status::kInvalidArgument;

    std::size_t metric_depth_frame_count = 0;
    std::size_t relative_depth_frame_count = 0;
    for (std::size_t i = 0; i < frame_count; ++i) {
        if (frames[i]->ne_depth.empty()) continue;
        if (frames[i]->ne_depth_is_metric) {
            metric_depth_frame_count++;
        } else {
            relative_depth_frame_count++;
        }
    }

    // Step 1: Estimate metric scale in INVERSE-DEPTH space for relative priors.
    // Some local-preview paths now feed metric depth directly; those bypass this
    // conversion and are used as-is below. Relative DAv2-style priors still use
    // the old reciprocal affine fallback when no online calibration is available.
    float metric_scale, metric_shift;
    {
        float old_scale_est = estimate_metric_scale(frames, frame_count);
        float z_near_est = std::max(0.3f, old_scale_est * 0.15f);
        float z_far_est  = std::min(8.0f, old_scale_est * 2.5f);
        if (z_far_est <= z_near_est) z_far_est = z_near_est * 5.0f;

        float inv_near = 1.0f / z_near_est;
        float inv_far  = 1.0f / z_far_est;
        metric_scale = inv_near - inv_far;
        metric_shift = inv_far;
    }
    std::fprintf(stderr, "[Aether3D] DAv2 init: inv-depth scale=%.3f shift=%.3f "
                 "(z_range=[%.2f, %.2f]m) from %zu depth frames "
                 "(metric=%zu relative=%zu)\n",
                 metric_scale, metric_shift,
                 1.0f / (metric_scale + metric_shift), 1.0f / metric_shift,
                 depth_frame_count, metric_depth_frame_count,
                 relative_depth_frame_count);

    // Step 2: Backproject all frames
    std::unordered_set<std::int64_t> occupied;
    out_points.reserve(config.max_points);

    for (std::size_t fi = 0; fi < frame_count; ++fi) {
        const auto& frame = *frames[fi];
        if (frame.ne_depth.empty()) continue;

        const float fx = frame.intrinsics[0];
        const float fy = frame.intrinsics[1];
        const float cx = frame.intrinsics[2];
        const float cy = frame.intrinsics[3];

        if (fx < 1.0f || fy < 1.0f) continue;  // Invalid intrinsics

        // Scale intrinsics from image resolution to depth map resolution
        const float scale_x = static_cast<float>(frame.width) / frame.ne_depth_w;
        const float scale_y = static_cast<float>(frame.height) / frame.ne_depth_h;
        const float dfx = fx / scale_x;
        const float dfy = fy / scale_y;
        const float dcx = cx / scale_x;
        const float dcy = cy / scale_y;

        const std::uint32_t dw = frame.ne_depth_w;
        const std::uint32_t dh = frame.ne_depth_h;
        const std::uint32_t step = config.subsample_step;

        for (std::uint32_t y = 0; y < dh; y += step) {
            for (std::uint32_t x = 0; x < dw; x += step) {
                if (out_points.size() >= config.max_points) goto done;

                float prior_depth = frame.ne_depth[y * dw + x];
                if (!std::isfinite(prior_depth) || prior_depth <= 0.0f) continue;

                float depth = 0.0f;
                if (frame.ne_depth_is_metric) {
                    // Metric prior path: values are already absolute depth in meters.
                    depth = prior_depth;
                } else {
                    if (prior_depth > 0.99f) continue;

                    // Relative → metric depth via RECIPROCAL AFFINE in inverse-depth space:
                    //   1/depth = scale * d_pred + shift  (affine in inverse-depth)
                    //   depth = 1 / (scale * d_pred + shift)
                    // DAv2 relative priors are disparity-like values (larger = closer).
                    float inv_depth = metric_scale * prior_depth + metric_shift;
                    if (inv_depth < 0.001f) continue;  // Invalid inverse depth
                    depth = 1.0f / inv_depth;
                }

                // Clamp to valid range
                if (depth < config.min_depth || depth > config.max_depth) continue;

                // Backproject to camera space in the same ARKit convention used
                // by TSDF/pipeline_coordinator: image Y points down, camera Y
                // points up, and visible points lie at negative camera Z.
                float cam_x = (static_cast<float>(x) - dcx) / dfx * depth;
                float cam_y = -(static_cast<float>(y) - dcy) / dfy * depth;
                float cam_z = -depth;

                // Transform to world (column-major 4x4)
                const float* T = frame.transform;
                float wx = T[0]*cam_x + T[4]*cam_y + T[8]*cam_z  + T[12];
                float wy = T[1]*cam_x + T[5]*cam_y + T[9]*cam_z  + T[13];
                float wz = T[2]*cam_x + T[6]*cam_y + T[10]*cam_z + T[14];

                // Spatial hash dedup
                auto key = dav2_spatial_key(wx, wy, wz, config.spatial_hash_cell);
                if (occupied.count(key)) continue;
                occupied.insert(key);

                // Sample color from RGBA (nearest pixel at image resolution)
                std::uint32_t img_x = static_cast<std::uint32_t>(x * scale_x);
                std::uint32_t img_y = static_cast<std::uint32_t>(y * scale_y);
                if (img_x >= frame.width) img_x = frame.width - 1;
                if (img_y >= frame.height) img_y = frame.height - 1;
                std::size_t cidx = (static_cast<std::size_t>(img_y) * frame.width + img_x) * 4;

                splat::GaussianParams g{};
                g.position[0] = wx;
                g.position[1] = wy;
                g.position[2] = wz;
                // BGRA → RGB: Swift passes kCVPixelFormatType_32BGRA
                g.color[0] = srgb_to_linear(frame.rgba[cidx + 2] / 255.0f);  // R
                g.color[1] = srgb_to_linear(frame.rgba[cidx + 1] / 255.0f);  // G
                g.color[2] = srgb_to_linear(frame.rgba[cidx + 0] / 255.0f);  // B
                g.opacity = config.initial_opacity;
                g.scale[0] = g.scale[1] = g.scale[2] = config.initial_scale;
                g.rotation[0] = 1.0f;  // Identity quaternion
                g.rotation[1] = g.rotation[2] = g.rotation[3] = 0.0f;

                out_points.push_back(g);
            }
        }
    }
done:

    if (out_points.empty()) return core::Status::kResourceExhausted;

    std::fprintf(stderr, "[Aether3D] DAv2 init: %zu points from %zu depth frames "
                 "(dedup cells: %zu)\n",
                 out_points.size(), depth_frame_count, occupied.size());

    // Step 3: Adaptive scale based on point cloud density
    // Same algorithm as mvs_initializer.h post-pass.
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
            float dx = p.position[0] - center_x;
            float dy = p.position[1] - center_y;
            float dz = p.position[2] - center_z;
            float d2 = dx * dx + dy * dy + dz * dz;
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

        std::fprintf(stderr, "[Aether3D] DAv2 init: adaptive_scale=%.4f "
                     "(radius=%.2f, N=%zu)\n", adaptive, radius, N);
    }

    return core::Status::kOk;
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_DAV2_INITIALIZER_H
