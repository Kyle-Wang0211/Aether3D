// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_PATCH_DISPLAY_KERNEL_H
#define AETHER_EVIDENCE_PATCH_DISPLAY_KERNEL_H

namespace aether {
namespace evidence {

struct PatchDisplayKernelConfig {
    double patch_display_alpha{0.12};
    double patch_display_locked_acceleration{1.5};
    double color_evidence_local_weight{0.7};
    double color_evidence_global_weight{0.3};
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_PATCH_DISPLAY_KERNEL_H
