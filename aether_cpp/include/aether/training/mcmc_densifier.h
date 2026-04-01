// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// mcmc_densifier.h — MCMC + Importance Relocation densifier (Self-Research Hybrid).
// Combines:
//   - 3DGS-MCMC (NeurIPS 2024): SGLD noise injection for exploration
//   - Mini-Splatting: Importance-based birth/death
//   - Per-pixel error: Relocation to high-error regions
//
// Self-research: fusion of these three techniques with annealing schedule.

#ifndef AETHER_TRAINING_MCMC_DENSIFIER_H
#define AETHER_TRAINING_MCMC_DENSIFIER_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <random>
#include <vector>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// MCMC + Importance Relocation Densifier
// ═══════════════════════════════════════════════════════════════════════

/// MCMC densifier configuration.
struct MCMCConfig {
    // SGLD noise injection
    float noise_lr{0.01f};           // Base noise learning rate
    float temperature_init{1.0f};     // Initial temperature
    float temperature_final{0.01f};   // Final temperature (annealing)

    // Importance-based birth/death
    float death_importance_percentile{0.1f}; // Kill bottom 10% by importance
    float birth_error_threshold{0.1f};       // Spawn if pixel error > threshold

    // Relocation
    std::uint32_t relocation_budget{100};    // Max new Gaussians per step
    float relocation_depth_margin{0.1f};     // Depth margin for back-projection

    // Total primitive budget
    std::uint32_t max_primitives{300000};
};

/// Per-Gaussian importance score (for birth/death decisions).
/// importance = pixel_contribution × opacity / mean_scale
inline float compute_importance(float pixel_contribution,
                                float opacity,
                                const float scale[3]) noexcept {
    float mean_scale = (scale[0] + scale[1] + scale[2]) / 3.0f;
    if (mean_scale < 1e-8f) mean_scale = 1e-8f;
    return pixel_contribution * opacity / mean_scale;
}

/// Compute annealed temperature for SGLD noise.
/// T(t) = T_init × (T_final / T_init)^(t / max_steps)
inline float annealed_temperature(
    float t_init, float t_final,
    std::size_t step, std::size_t max_steps) noexcept
{
    if (max_steps == 0) return t_init;
    float t = static_cast<float>(step) / static_cast<float>(max_steps);
    return t_init * std::exp(t * std::log(t_final / t_init));
}

/// Inject SGLD noise into position parameters.
/// pos += sqrt(2 × lr × T(t)) × N(0,1)
/// This enables exploration of the loss landscape (global optimization).
inline void inject_sgld_noise(
    float pos[3],
    float lr, float temperature,
    std::mt19937& rng) noexcept
{
    float noise_scale = std::sqrt(2.0f * lr * temperature);
    std::normal_distribution<float> normal(0.0f, 1.0f);

    pos[0] += noise_scale * normal(rng);
    pos[1] += noise_scale * normal(rng);
    pos[2] += noise_scale * normal(rng);
}

/// Find death candidates: Gaussians with lowest importance scores.
/// @param importance   Per-Gaussian importance scores
/// @param count        Number of Gaussians
/// @param percentile   Fraction to kill (e.g., 0.1 = bottom 10%)
/// @param out_deaths   Output: indices of Gaussians to kill
inline void find_death_candidates(
    const float* importance,
    std::size_t count,
    float percentile,
    std::vector<std::size_t>& out_deaths) noexcept
{
    if (count == 0) return;

    // Find the percentile threshold
    std::vector<float> sorted_imp(importance, importance + count);
    std::sort(sorted_imp.begin(), sorted_imp.end());

    std::size_t threshold_idx = static_cast<std::size_t>(percentile * count);
    if (threshold_idx >= count) threshold_idx = count - 1;
    float threshold = sorted_imp[threshold_idx];

    // Cap deaths to exactly percentile fraction.
    // Bug fix: when many Gaussians have importance=0, threshold=0, and the
    // original condition (importance[i] <= 0) kills ALL zero-importance
    // Gaussians (can be 95%+ of population), not just the intended 5%.
    // Fix: collect candidates in index order, then cap at max_to_kill.
    const std::size_t max_to_kill = static_cast<std::size_t>(percentile * count);
    out_deaths.clear();
    out_deaths.reserve(max_to_kill);
    for (std::size_t i = 0; i < count && out_deaths.size() < max_to_kill; ++i) {
        if (importance[i] <= threshold) {
            out_deaths.push_back(i);
        }
    }
}

/// Back-project a high-error pixel to 3D for Gaussian relocation.
/// @param px, py       Pixel coordinates
/// @param depth        Rendered depth at pixel (from depth buffer)
/// @param inv_view     Inverse view matrix (4×4, column-major)
/// @param fx, fy, cx, cy Camera intrinsics
/// @param out_pos      Output: 3D world-space position
/// @return true if valid position computed
inline bool backproject_pixel(
    float px, float py, float depth,
    const float inv_view[16],
    float fx, float fy, float cx, float cy,
    float out_pos[3]) noexcept
{
    if (depth <= 0.0f || fx == 0.0f || fy == 0.0f) return false;

    // Keep densifier birth points in the same ARKit camera convention used
    // by TSDF, DAv2 init, MVS init, and pipeline_coordinator:
    // image Y points down, camera Y points up, and visible points lie at
    // negative camera Z.
    float cam_x = (px - cx) * depth / fx;
    float cam_y = -(py - cy) * depth / fy;
    float cam_z = -depth;

    // Transform to world space via inverse view matrix
    out_pos[0] = inv_view[0]*cam_x + inv_view[4]*cam_y + inv_view[8]*cam_z  + inv_view[12];
    out_pos[1] = inv_view[1]*cam_x + inv_view[5]*cam_y + inv_view[9]*cam_z  + inv_view[13];
    out_pos[2] = inv_view[2]*cam_x + inv_view[6]*cam_y + inv_view[10]*cam_z + inv_view[14];

    return true;
}

/// Find high-error pixels for Gaussian relocation/birth.
/// @param error_map    Per-pixel L1 error (W×H)
/// @param rendered_depth Per-pixel depth (W×H)
/// @param width, height Image dimensions
/// @param threshold    Minimum error to consider
/// @param budget       Maximum number of candidates
/// @param out_px, out_py Output pixel coordinates
/// @param out_depth    Output depth at selected pixels
/// @return Number of candidates found
inline std::uint32_t find_high_error_pixels(
    const float* error_map,
    const float* rendered_depth,
    std::uint32_t width, std::uint32_t height,
    float threshold,
    std::uint32_t budget,
    std::vector<float>& out_px,
    std::vector<float>& out_py,
    std::vector<float>& out_depth) noexcept
{
    if (!error_map || !rendered_depth) return 0;

    // Collect all candidates above threshold
    struct Candidate {
        float px, py, depth, error;
    };
    std::vector<Candidate> candidates;

    for (std::uint32_t y = 0; y < height; ++y) {
        for (std::uint32_t x = 0; x < width; ++x) {
            std::size_t idx = y * width + x;
            float err = error_map[idx];
            float dep = rendered_depth[idx];
            if (err > threshold && dep > 0.0f) {
                candidates.push_back({static_cast<float>(x), static_cast<float>(y), dep, err});
            }
        }
    }

    // Sort by error (descending) and take top N
    std::sort(candidates.begin(), candidates.end(),
              [](const Candidate& a, const Candidate& b) { return a.error > b.error; });

    std::uint32_t count = std::min(budget, static_cast<std::uint32_t>(candidates.size()));
    out_px.resize(count);
    out_py.resize(count);
    out_depth.resize(count);

    for (std::uint32_t i = 0; i < count; ++i) {
        out_px[i] = candidates[i].px;
        out_py[i] = candidates[i].py;
        out_depth[i] = candidates[i].depth;
    }

    return count;
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_MCMC_DENSIFIER_H
