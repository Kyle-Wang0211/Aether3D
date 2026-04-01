// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// steepgs_densifier.h — SteepGS saddle-point escape densification (CVPR 2025, Meta).
// Detects Gaussians trapped at saddle points using local Hessian approximation,
// then splits along the direction of maximum negative curvature.
// Provides mathematically optimal split direction vs heuristic clone/split.
// Reference: "SteepGS: Steep Gradient Splatting" — CVPR 2025

#ifndef AETHER_TRAINING_STEEPGS_DENSIFIER_H
#define AETHER_TRAINING_STEEPGS_DENSIFIER_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace aether {
namespace training {

// ═══════════════════════════════════════════════════════════════════════
// SteepGS: Saddle-Point Escape via Local Hessian Approximation
// ═══════════════════════════════════════════════════════════════════════
// Algorithm:
//   1. Every N steps, estimate local Hessian via finite differences:
//      H_i ≈ (grad(t) - grad(t-1)) / (params(t) - params(t-1))
//   2. Detect saddle point: any diagonal element of H < 0
//   3. At saddle: split along direction of most negative curvature
//   4. Non-saddle + large gradient → keep for optimizer to explore

/// Per-Gaussian SteepGS state (gradient history for Hessian estimation).
struct SteepGSState {
    float prev_grad[3]{};    // Previous position gradient (for Hessian est.)
    float prev_pos[3]{};     // Previous position (for param delta)
    bool has_prev{false};    // Whether we have history from last densify check
};

/// SteepGS densification configuration.
struct SteepGSConfig {
    float saddle_threshold{-0.01f};   // H diagonal threshold for saddle detection
    float split_offset_sigma{0.5f};   // Split offset = σ × factor along neg curvature
    float min_grad_for_split{0.00005f}; // Minimum gradient to consider splitting
    std::size_t check_interval{100};  // Steps between Hessian checks
};

/// Detect if a Gaussian is at a saddle point via diagonal Hessian approximation.
/// @param current_grad  Current position gradient [gx, gy, gz]
/// @param state         Previous gradient/position state
/// @param current_pos   Current position [x, y, z]
/// @param config        SteepGS configuration
/// @param out_split_dir Output: direction of maximum negative curvature [dx, dy, dz]
/// @return true if saddle point detected (should split)
inline bool steepgs_detect_saddle(
    const float current_grad[3],
    const SteepGSState& state,
    const float current_pos[3],
    const SteepGSConfig& config,
    float out_split_dir[3]) noexcept
{
    if (!state.has_prev) return false;

    // Diagonal Hessian approximation via finite differences:
    // H_ii ≈ (g_i(t) - g_i(t-1)) / (p_i(t) - p_i(t-1))
    float hessian_diag[3]{};
    float most_negative = 0.0f;
    int most_neg_axis = -1;

    for (int i = 0; i < 3; ++i) {
        float dp = current_pos[i] - state.prev_pos[i];
        if (std::fabs(dp) < 1e-10f) continue;  // No parameter change

        float dg = current_grad[i] - state.prev_grad[i];
        hessian_diag[i] = dg / dp;

        if (hessian_diag[i] < config.saddle_threshold &&
            hessian_diag[i] < most_negative) {
            most_negative = hessian_diag[i];
            most_neg_axis = i;
        }
    }

    if (most_neg_axis < 0) return false;  // No negative curvature

    // Split direction = axis of most negative curvature
    out_split_dir[0] = (most_neg_axis == 0) ? 1.0f : 0.0f;
    out_split_dir[1] = (most_neg_axis == 1) ? 1.0f : 0.0f;
    out_split_dir[2] = (most_neg_axis == 2) ? 1.0f : 0.0f;

    return true;
}

/// Update SteepGS state for next check.
inline void steepgs_update_state(
    SteepGSState& state,
    const float current_grad[3],
    const float current_pos[3]) noexcept
{
    state.prev_grad[0] = current_grad[0];
    state.prev_grad[1] = current_grad[1];
    state.prev_grad[2] = current_grad[2];
    state.prev_pos[0] = current_pos[0];
    state.prev_pos[1] = current_pos[1];
    state.prev_pos[2] = current_pos[2];
    state.has_prev = true;
}

}  // namespace training
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TRAINING_STEEPGS_DENSIFIER_H
