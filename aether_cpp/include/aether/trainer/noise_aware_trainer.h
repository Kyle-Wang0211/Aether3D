// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CPP_TRAINER_NOISE_AWARE_TRAINER_H
#define AETHER_CPP_TRAINER_NOISE_AWARE_TRAINER_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>

#include "aether/core/status.h"

namespace aether {
namespace trainer {

enum class TriTetClass : std::uint8_t {
    kUnknown = 0,
    kEstimated = 1,
    kMeasured = 2,
};

struct NoiseAwareSample {
    float photometric_residual;
    float depth_residual;
    float sigma2;
    float confidence;
    TriTetClass tri_tet_class;
};

struct NoiseAwareAccumulator {
    double weighted_residual_sum;
    double weight_sum;
    double tri_tet_bias_sum;
    std::size_t sample_count;
};

float tri_tet_reliability(TriTetClass tri_tet_class);
float compute_noise_aware_weight(const NoiseAwareSample& sample);
core::Status accumulate_noise_aware_batch(
    const NoiseAwareSample* samples,
    std::size_t count,
    NoiseAwareAccumulator* accumulator);
float finalize_noise_aware_loss(const NoiseAwareAccumulator& accumulator);

}  // namespace trainer
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CPP_TRAINER_NOISE_AWARE_TRAINER_H
