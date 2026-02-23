// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TRAINER_DA3_DEPTH_FUSER_H
#define AETHER_CPP_TRAINER_DA3_DEPTH_FUSER_H

#ifdef __cplusplus

#include "aether/trainer/noise_aware_trainer.h"

namespace aether {
namespace trainer {

struct DA3DepthSample {
    float depth_from_vision;
    float depth_from_tsdf;
    float sigma2_vision;
    float sigma2_tsdf;
    TriTetClass tri_tet_class;
};

float fuse_da3_depth(const DA3DepthSample& sample, float* confidence_out);

}  // namespace trainer
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_TRAINER_DA3_DEPTH_FUSER_H
