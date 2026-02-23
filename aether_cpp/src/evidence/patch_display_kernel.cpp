// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/patch_display_kernel.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace evidence {
namespace {

inline double clamp01(double value) {
    if (!std::isfinite(value)) {
        return 0.0;
    }
    return std::max(0.0, std::min(1.0, value));
}

}  // namespace

PatchDisplayKernelConfig default_patch_display_kernel_config() {
    return PatchDisplayKernelConfig{};
}

PatchDisplayStepResult patch_display_step(
    double previous_display,
    double previous_ema,
    std::int32_t observation_count,
    double target,
    bool is_locked,
    const PatchDisplayKernelConfig& config,
    double ghost_display_high_water) {
    const double alpha = clamp01(config.patch_display_alpha);
    const double ghost_hw = clamp01(ghost_display_high_water);

    // Ghost state warm-start: if previous_display is zero but ghost high-water
    // exists, this patch was evicted and re-observed.  Resume from the ghost
    // floor so the user never sees visual regression — the patch picks up from
    // where it left off, matching the Voxblox two-layer persistence pattern.
    const bool warmstart = (previous_display <= 0.0 && ghost_hw > 0.0);
    const double effective_prev_display = warmstart ? ghost_hw : clamp01(previous_display);
    const double effective_prev_ema = warmstart ? ghost_hw : clamp01(previous_ema);

    const double clamped_target = clamp01(target);
    const double ema = alpha * clamped_target + (1.0 - alpha) * effective_prev_ema;

    // Core monotonic ratchet: display never decreases.
    double display = std::max(effective_prev_display, ema);

    if (is_locked) {
        const double accel = std::max(1.0, config.patch_display_locked_acceleration);
        const double growth_delta = ema - effective_prev_display;
        display = std::max(effective_prev_display, std::min(1.0, effective_prev_display + growth_delta * accel));
    }

    // Ghost recovery acceleration: re-observed patches that were previously
    // evicted converge faster (2x default).  Inspired by OCSplats observation
    // completeness — patches with prior observation history are more reliable.
    if (warmstart && observation_count > 0) {
        const double recovery_accel = std::max(1.0, config.ghost_recovery_acceleration);
        const double growth = display - effective_prev_display;
        if (growth > 0.0) {
            display = std::min(1.0, effective_prev_display + growth * recovery_accel);
        }
    }

    PatchDisplayStepResult out{};
    out.display = clamp01(display);
    out.ema = ema;
    out.color_evidence = patch_color_evidence(out.display, out.display, config);
    out.used_ghost_warmstart = warmstart;
    return out;
}

double patch_color_evidence(
    double local_display,
    double global_display,
    const PatchDisplayKernelConfig& config) {
    const double local = clamp01(local_display);
    const double global = clamp01(global_display);

    const double lw = std::max(0.0, config.color_evidence_local_weight);
    const double gw = std::max(0.0, config.color_evidence_global_weight);
    const double sum = lw + gw;
    if (sum <= 1e-12) {
        return 0.0;
    }

    return clamp01((local * lw + global * gw) / sum);
}

}  // namespace evidence
}  // namespace aether
