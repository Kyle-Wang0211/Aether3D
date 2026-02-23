// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_PATCH_DISPLAY_KERNEL_H
#define AETHER_EVIDENCE_PATCH_DISPLAY_KERNEL_H

#ifdef __cplusplus

#include <cstdint>

namespace aether {
namespace evidence {

struct PatchDisplayKernelConfig {
    double patch_display_alpha{0.2};
    double patch_display_locked_acceleration{1.5};
    double color_evidence_local_weight{0.7};
    double color_evidence_global_weight{0.3};

    // Ghost state warm-start: when a patch has been evicted and re-observed,
    // display resumes from the ghost high-water mark instead of zero.
    // Inspired by Voxblox two-layer persistence + OCSplats observation
    // completeness metric.  Re-observed patches recover at 2x speed.
    double ghost_recovery_acceleration{2.0};
};

struct PatchDisplayStepResult {
    double display{0.0};
    double ema{0.0};
    double color_evidence{0.0};
    bool used_ghost_warmstart{false};
};

PatchDisplayKernelConfig default_patch_display_kernel_config();

PatchDisplayStepResult patch_display_step(
    double previous_display,
    double previous_ema,
    std::int32_t observation_count,
    double target,
    bool is_locked,
    const PatchDisplayKernelConfig& config,
    double ghost_display_high_water = 0.0);

double patch_color_evidence(
    double local_display,
    double global_display,
    const PatchDisplayKernelConfig& config);

}  // namespace evidence
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_EVIDENCE_PATCH_DISPLAY_KERNEL_H
