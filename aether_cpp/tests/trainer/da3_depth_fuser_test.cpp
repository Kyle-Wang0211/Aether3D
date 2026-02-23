// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/trainer/da3_depth_fuser.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    aether::trainer::DA3DepthSample unknown{};
    unknown.depth_from_vision = 2.0f;
    unknown.depth_from_tsdf = 2.4f;
    unknown.sigma2_vision = 0.05f;
    unknown.sigma2_tsdf = 0.05f;
    unknown.tri_tet_class = aether::trainer::TriTetClass::kUnknown;

    aether::trainer::DA3DepthSample measured = unknown;
    measured.tri_tet_class = aether::trainer::TriTetClass::kMeasured;

    float confidence_unknown = 0.0f;
    const float fused_unknown = aether::trainer::fuse_da3_depth(unknown, &confidence_unknown);
    float confidence_measured = 0.0f;
    const float fused_measured = aether::trainer::fuse_da3_depth(measured, &confidence_measured);

    if (!(confidence_unknown >= 0.0f && confidence_unknown <= 1.0f)) {
        std::fprintf(stderr, "confidence_unknown must remain in [0, 1]\n");
        failed++;
    }
    if (!(confidence_measured >= 0.0f && confidence_measured <= 1.0f)) {
        std::fprintf(stderr, "confidence_measured must remain in [0, 1]\n");
        failed++;
    }
    if (!(std::fabs(fused_measured - measured.depth_from_tsdf) <
          std::fabs(fused_unknown - measured.depth_from_tsdf))) {
        std::fprintf(stderr, "measured class should bias fusion toward tsdf depth\n");
        failed++;
    }

    return failed;
}
