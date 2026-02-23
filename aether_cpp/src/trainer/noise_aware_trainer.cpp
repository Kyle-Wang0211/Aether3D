// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/trainer/noise_aware_trainer.h"

#include <cmath>

namespace {

inline float clamp01(float value) {
    if (value < 0.0f) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

}  // namespace

namespace aether {
namespace trainer {

float tri_tet_reliability(TriTetClass tri_tet_class) {
    switch (tri_tet_class) {
        case TriTetClass::kMeasured:
            return 1.0f;
        case TriTetClass::kEstimated:
            return 0.75f;
        case TriTetClass::kUnknown:
        default:
            return 0.4f;
    }
}

float compute_noise_aware_weight(const NoiseAwareSample& sample) {
    const float safe_sigma2 = sample.sigma2 <= 1e-6f ? 1e-6f : sample.sigma2;
    const float confidence = clamp01(sample.confidence);
    const float reliability = tri_tet_reliability(sample.tri_tet_class);
    return confidence * reliability / (1.0f + safe_sigma2);
}

core::Status accumulate_noise_aware_batch(
    const NoiseAwareSample* samples,
    std::size_t count,
    NoiseAwareAccumulator* accumulator) {
    if (accumulator == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (count > 0 && samples == nullptr) {
        return core::Status::kInvalidArgument;
    }

    for (std::size_t i = 0; i < count; ++i) {
        const float weight = compute_noise_aware_weight(samples[i]);
        const float residual = std::sqrt(
            samples[i].photometric_residual * samples[i].photometric_residual +
            samples[i].depth_residual * samples[i].depth_residual);
        accumulator->weighted_residual_sum += static_cast<double>(weight * residual);
        accumulator->weight_sum += static_cast<double>(weight);
        accumulator->tri_tet_bias_sum += static_cast<double>(tri_tet_reliability(samples[i].tri_tet_class));
        accumulator->sample_count += 1;
    }
    return core::Status::kOk;
}

float finalize_noise_aware_loss(const NoiseAwareAccumulator& accumulator) {
    if (accumulator.weight_sum <= 0.0) {
        return 0.0f;
    }
    const double loss = accumulator.weighted_residual_sum / accumulator.weight_sum;
    return static_cast<float>(loss);
}

}  // namespace trainer
}  // namespace aether
