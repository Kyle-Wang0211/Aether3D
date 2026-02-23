// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TSDF_SOLVER_WATCHDOG_H
#define AETHER_TSDF_SOLVER_WATCHDOG_H

#ifdef __cplusplus

#include <algorithm>
#include <cmath>
#include <limits>

namespace aether {
namespace tsdf {

struct SolverWatchdogConfig {
    float max_diag_ratio{1e3f};
    int max_residual_rise_streak{2};
    float residual_rise_ratio{1.01f};
};

struct SolverWatchdogState {
    float last_residual{std::numeric_limits<float>::infinity()};
    float last_diag_ratio{1.0f};
    int residual_rise_streak{0};
    bool tripped{false};
};

inline void solver_watchdog_reset(SolverWatchdogState* state) {
    if (state == nullptr) {
        return;
    }
    *state = SolverWatchdogState{};
}

inline bool solver_watchdog_observe(
    float diag_min,
    float diag_max,
    float residual,
    const SolverWatchdogConfig& config,
    SolverWatchdogState* state) {
    if (state == nullptr) {
        return false;
    }
    if (!std::isfinite(diag_min) || !std::isfinite(diag_max) ||
        !std::isfinite(residual) || diag_min <= 0.0f || diag_max <= 0.0f) {
        state->tripped = true;
        return false;
    }

    const float ratio = diag_max / std::max(diag_min, 1e-12f);
    state->last_diag_ratio = ratio;
    if (ratio > std::max(1.0f, config.max_diag_ratio)) {
        state->tripped = true;
        return false;
    }

    if (std::isfinite(state->last_residual) &&
        residual > state->last_residual * std::max(1.0f, config.residual_rise_ratio)) {
        state->residual_rise_streak += 1;
        if (state->residual_rise_streak >= std::max(1, config.max_residual_rise_streak)) {
            state->tripped = true;
            return false;
        }
    } else {
        state->residual_rise_streak = 0;
    }
    state->last_residual = residual;
    return true;
}

}  // namespace tsdf
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_TSDF_SOLVER_WATCHDOG_H
