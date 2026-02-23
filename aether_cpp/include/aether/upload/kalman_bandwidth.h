// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_UPLOAD_KALMAN_BANDWIDTH_H
#define AETHER_UPLOAD_KALMAN_BANDWIDTH_H

#ifdef __cplusplus

#include "aether/core/status.h"

#include <array>
#include <cstdint>

namespace aether {
namespace upload {

enum class BandwidthTrend : std::int32_t {
    kRising = 0,
    kStable = 1,
    kFalling = 2,
};

struct KalmanBandwidthState {
    std::array<double, 4> x{{0.0, 0.0, 0.0, 0.0}};
    std::array<double, 16> p{{
        100.0, 0.0, 0.0, 0.0,
        0.0, 10.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 50.0,
    }};
    double q_base{0.01};
    double r{0.001};

    std::array<double, 10> recent_bps{{0.0}};
    std::int32_t recent_count{0};
    std::int32_t recent_head{0};
    std::int32_t total_samples{0};
};

struct KalmanBandwidthOutput {
    double predicted_bps{0.0};
    double ci_low{0.0};
    double ci_high{0.0};
    BandwidthTrend trend{BandwidthTrend::kStable};
    bool reliable{false};
};

void kalman_bandwidth_reset(KalmanBandwidthState* state);

core::Status kalman_bandwidth_step(
    KalmanBandwidthState* state,
    std::int64_t bytes_transferred,
    double duration_seconds,
    KalmanBandwidthOutput* out);

core::Status kalman_bandwidth_predict(
    const KalmanBandwidthState* state,
    KalmanBandwidthOutput* out);

}  // namespace upload
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_UPLOAD_KALMAN_BANDWIDTH_H
