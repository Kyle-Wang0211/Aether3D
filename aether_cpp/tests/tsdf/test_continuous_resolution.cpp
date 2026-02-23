// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/adaptive_resolution.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;
    using namespace aether::tsdf;

    const ContinuousResolutionConfig cfg = default_continuous_resolution_config();
    const float near_hi = continuous_voxel_size(0.3f, 0.95f, false, cfg);
    const float far_lo = continuous_voxel_size(4.5f, 0.0f, false, cfg);
    if (!(near_hi < far_lo)) {
        std::fprintf(stderr, "continuous_voxel_size depth/display ordering mismatch\n");
        failed++;
    }

    const float boundary = continuous_voxel_size(0.8f, 0.7f, true, cfg);
    const float non_boundary = continuous_voxel_size(0.8f, 0.7f, false, cfg);
    if (!(boundary < non_boundary)) {
        std::fprintf(stderr, "boundary refinement not applied\n");
        failed++;
    }

    const float opacity_s5 = continuous_fill_opacity(0.88f);
    const float opacity_s1 = continuous_fill_opacity(0.10f);
    if (!(opacity_s5 > 0.95f && opacity_s1 < 0.10f)) {
        std::fprintf(stderr, "continuous_fill_opacity S0-S5 alignment mismatch\n");
        failed++;
    }

    return failed;
}
