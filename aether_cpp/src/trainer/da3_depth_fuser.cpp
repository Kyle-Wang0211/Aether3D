// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/trainer/da3_depth_fuser.h"

namespace aether {
namespace trainer {

float fuse_da3_depth(const DA3DepthSample& sample, float* confidence_out) {
    const float sigma2_vision = sample.sigma2_vision <= 1e-6f ? 1e-6f : sample.sigma2_vision;
    const float sigma2_tsdf = sample.sigma2_tsdf <= 1e-6f ? 1e-6f : sample.sigma2_tsdf;
    const float w_vision = 1.0f / sigma2_vision;
    float w_tsdf = 1.0f / sigma2_tsdf;

    const float tri_tet_gain = tri_tet_reliability(sample.tri_tet_class);
    w_tsdf *= (0.5f + 0.5f * tri_tet_gain);

    const float denom = w_vision + w_tsdf;
    const float fused = (w_vision * sample.depth_from_vision + w_tsdf * sample.depth_from_tsdf) / denom;

    if (confidence_out != nullptr) {
        float confidence = denom / (1.0f + denom);
        if (confidence < 0.0f) {
            confidence = 0.0f;
        } else if (confidence > 1.0f) {
            confidence = 1.0f;
        }
        *confidence_out = confidence;
    }
    return fused;
}

}  // namespace trainer
}  // namespace aether
