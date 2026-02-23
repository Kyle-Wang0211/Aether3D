// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/trainer/noise_aware_trainer.h"

#include <cstdio>

int main() {
    int failed = 0;
    aether::trainer::NoiseAwareSample measured{};
    measured.photometric_residual = 0.2f;
    measured.depth_residual = 0.1f;
    measured.sigma2 = 0.01f;
    measured.confidence = 0.95f;
    measured.tri_tet_class = aether::trainer::TriTetClass::kMeasured;

    aether::trainer::NoiseAwareSample unknown = measured;
    unknown.tri_tet_class = aether::trainer::TriTetClass::kUnknown;

    const float measured_weight = aether::trainer::compute_noise_aware_weight(measured);
    const float unknown_weight = aether::trainer::compute_noise_aware_weight(unknown);
    if (!(measured_weight > unknown_weight)) {
        std::fprintf(stderr, "measured weight should dominate unknown weight\n");
        failed++;
    }

    aether::trainer::NoiseAwareSample batch[2] = {measured, unknown};
    aether::trainer::NoiseAwareAccumulator acc{};
    acc.weighted_residual_sum = 0.0;
    acc.weight_sum = 0.0;
    acc.tri_tet_bias_sum = 0.0;
    acc.sample_count = 0;
    const auto status = aether::trainer::accumulate_noise_aware_batch(batch, 2, &acc);
    if (status != aether::core::Status::kOk) {
        std::fprintf(stderr, "accumulate_noise_aware_batch returned non-ok status\n");
        failed++;
    }
    const float loss = aether::trainer::finalize_noise_aware_loss(acc);
    if (!(loss > 0.0f)) {
        std::fprintf(stderr, "finalized noise-aware loss must stay positive\n");
        failed++;
    }

    return failed;
}
