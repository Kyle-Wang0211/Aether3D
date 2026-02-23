// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/upload/kalman_bandwidth.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace aether {
namespace upload {
namespace {

std::array<double, 16> identity4() {
    return std::array<double, 16>{{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }};
}

inline double measured_bps(std::int64_t bytes, double duration_s) {
    if (!(duration_s > 0.0) || !std::isfinite(duration_s)) {
        return 0.0;
    }
    const double bps = (static_cast<double>(bytes) * 8.0) / duration_s;
    if (std::isfinite(bps)) {
        return bps;
    }
    return (bps < 0.0) ? -std::numeric_limits<double>::max() : std::numeric_limits<double>::max();
}

inline std::size_t idx(std::size_t r, std::size_t c) {
    return r * 4u + c;
}

std::array<double, 16> mat4_mul(
    const std::array<double, 16>& a,
    const std::array<double, 16>& b) {
    std::array<double, 16> out{{0.0}};
    for (std::size_t r = 0u; r < 4u; ++r) {
        for (std::size_t c = 0u; c < 4u; ++c) {
            double sum = 0.0;
            for (std::size_t k = 0u; k < 4u; ++k) {
                sum += a[idx(r, k)] * b[idx(k, c)];
            }
            out[idx(r, c)] = sum;
        }
    }
    return out;
}

std::array<double, 16> mat4_transpose(const std::array<double, 16>& m) {
    std::array<double, 16> out{{0.0}};
    for (std::size_t r = 0u; r < 4u; ++r) {
        for (std::size_t c = 0u; c < 4u; ++c) {
            out[idx(r, c)] = m[idx(c, r)];
        }
    }
    return out;
}

std::array<double, 4> mat4_vec4_mul(
    const std::array<double, 16>& m,
    const std::array<double, 4>& v) {
    std::array<double, 4> out{{0.0}};
    for (std::size_t r = 0u; r < 4u; ++r) {
        out[r] = m[idx(r, 0u)] * v[0] +
            m[idx(r, 1u)] * v[1] +
            m[idx(r, 2u)] * v[2] +
            m[idx(r, 3u)] * v[3];
    }
    return out;
}

BandwidthTrend trend_from_delta(double delta) {
    if (delta > 0.1) {
        return BandwidthTrend::kRising;
    }
    if (delta < -0.1) {
        return BandwidthTrend::kFalling;
    }
    return BandwidthTrend::kStable;
}

void emit_prediction(const KalmanBandwidthState& state, KalmanBandwidthOutput* out) {
    if (out == nullptr) {
        return;
    }
    const double predicted = state.x[0];
    const double variance = std::max(0.0, state.p[idx(0u, 0u)]);
    const double stddev = std::sqrt(variance);
    const double ci = 1.96 * stddev;

    out->predicted_bps = predicted;
    out->ci_low = std::max(0.0, predicted - ci);
    out->ci_high = predicted + ci;

    if (state.recent_count >= 4) {
        const int split = state.recent_count / 2;
        double first_mean = 0.0;
        double second_mean = 0.0;
        for (int i = 0; i < split; ++i) {
            const int pos = (state.recent_head - state.recent_count + i + 10) % 10;
            first_mean += state.recent_bps[static_cast<std::size_t>(pos)];
        }
        for (int i = split; i < state.recent_count; ++i) {
            const int pos = (state.recent_head - state.recent_count + i + 10) % 10;
            second_mean += state.recent_bps[static_cast<std::size_t>(pos)];
        }
        first_mean /= static_cast<double>(std::max(1, split));
        second_mean /= static_cast<double>(std::max(1, state.recent_count - split));
        const double baseline = std::max(1.0, std::fabs(first_mean));
        const double ratio_change = (second_mean - first_mean) / baseline;
        if (ratio_change > 0.08) {
            out->trend = BandwidthTrend::kRising;
        } else if (ratio_change < -0.08) {
            out->trend = BandwidthTrend::kFalling;
        } else {
            out->trend = BandwidthTrend::kStable;
        }
    } else {
        out->trend = trend_from_delta(state.x[1]);
    }

    const double trace =
        state.p[idx(0u, 0u)] + state.p[idx(1u, 1u)] + state.p[idx(2u, 2u)] + state.p[idx(3u, 3u)];
    out->reliable = trace < 5.0;
}

}  // namespace

void kalman_bandwidth_reset(KalmanBandwidthState* state) {
    if (state == nullptr) {
        return;
    }
    *state = KalmanBandwidthState{};
}

core::Status kalman_bandwidth_step(
    KalmanBandwidthState* state,
    std::int64_t bytes_transferred,
    double duration_seconds,
    KalmanBandwidthOutput* out) {
    if (state == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (!(duration_seconds > 0.0) || !std::isfinite(duration_seconds)) {
        emit_prediction(*state, out);
        return core::Status::kOk;
    }

    const double measurement = measured_bps(bytes_transferred, duration_seconds);

    // Auto-reset if state is corrupted (NaN/Inf injection)
    {
        bool corrupted = false;
        for (double v : state->x) { if (!std::isfinite(v)) { corrupted = true; break; } }
        if (!corrupted) {
            for (double v : state->p) { if (!std::isfinite(v)) { corrupted = true; break; } }
        }
        if (corrupted) {
            *state = KalmanBandwidthState{};
        }
    }

    // Update rolling history for dynamic R.
    state->recent_bps[static_cast<std::size_t>(state->recent_head)] = measurement;
    state->recent_head = (state->recent_head + 1) % 10;
    state->recent_count = std::min(10, state->recent_count + 1);

    if (state->recent_count >= 2) {
        double mean = 0.0;
        for (int i = 0; i < state->recent_count; ++i) {
            const int pos = (state->recent_head - state->recent_count + i + 10) % 10;
            mean += state->recent_bps[static_cast<std::size_t>(pos)];
        }
        mean /= static_cast<double>(state->recent_count);

        double var = 0.0;
        for (int i = 0; i < state->recent_count; ++i) {
            const int pos = (state->recent_head - state->recent_count + i + 10) % 10;
            const double d = state->recent_bps[static_cast<std::size_t>(pos)] - mean;
            var += d * d;
        }
        var /= static_cast<double>(state->recent_count);
        if (std::isfinite(var)) {
            state->r = std::max(0.001, var);
        }
    }

    const std::array<double, 16> f{{
        1.0, 1.0, 0.5, 0.0,
        0.0, 1.0, 1.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }};
    std::array<double, 16> q{{
        state->q_base, 0.0, 0.0, 0.0,
        0.0, state->q_base, 0.0, 0.0,
        0.0, 0.0, state->q_base, 0.0,
        0.0, 0.0, 0.0, state->q_base,
    }};

    // Predict: x=F*x, P=F*P*F^T + Q
    state->x = mat4_vec4_mul(f, state->x);
    const std::array<double, 16> fp = mat4_mul(f, state->p);
    const std::array<double, 16> fpf = mat4_mul(fp, mat4_transpose(f));
    for (std::size_t i = 0u; i < 16u; ++i) {
        state->p[i] = fpf[i] + q[i];
    }

    // Update for H=[1,0,0,0].
    const double innovation = measurement - state->x[0];
    const double s = state->p[idx(0u, 0u)] + state->r;
    if (!(s > 0.0) || !std::isfinite(s)) {
        emit_prediction(*state, out);
        return core::Status::kOk;
    }

    std::array<double, 4> k{{
        state->p[idx(0u, 0u)] / s,
        state->p[idx(1u, 0u)] / s,
        state->p[idx(2u, 0u)] / s,
        state->p[idx(3u, 0u)] / s,
    }};

    const double mahalanobis = std::fabs(innovation) / std::sqrt(s);
    const double gain_scale = (mahalanobis > 2.5) ? 0.5 : 1.0;
    for (double& kv : k) {
        kv *= gain_scale;
    }

    for (std::size_t i = 0u; i < 4u; ++i) {
        state->x[i] += k[i] * innovation;
    }

    const std::array<double, 16> i4 = identity4();
    std::array<double, 16> kh = {{0.0}};
    for (std::size_t r = 0u; r < 4u; ++r) {
        kh[idx(r, 0u)] = k[r];
    }

    std::array<double, 16> ikh = {{0.0}};
    for (std::size_t i = 0u; i < 16u; ++i) {
        ikh[i] = i4[i] - kh[i];
    }
    // Joseph form: P = (I-KH)*P*(I-KH)^T + K*R*K^T for numerical stability
    auto ikh_p = mat4_mul(ikh, state->p);
    auto ikh_t = mat4_transpose(ikh);
    state->p = mat4_mul(ikh_p, ikh_t);
    // Add K*R*K^T term
    for (std::size_t r = 0u; r < 4u; ++r) {
        for (std::size_t c = 0u; c < 4u; ++c) {
            state->p[idx(r, c)] += k[r] * state->r * k[c];
        }
    }

    // Force symmetry
    for (std::size_t r = 0u; r < 4u; ++r) {
        for (std::size_t c = r + 1u; c < 4u; ++c) {
            double avg = 0.5 * (state->p[idx(r, c)] + state->p[idx(c, r)]);
            state->p[idx(r, c)] = avg;
            state->p[idx(c, r)] = avg;
        }
    }

    // Guard: if any state or covariance is non-finite, auto-reset
    bool corrupted = false;
    for (double v : state->x) { if (!std::isfinite(v)) { corrupted = true; break; } }
    if (!corrupted) {
        for (double v : state->p) { if (!std::isfinite(v)) { corrupted = true; break; } }
    }
    if (corrupted) {
        *state = KalmanBandwidthState{};
        state->x[0] = measurement;
    }

    state->total_samples += 1;
    emit_prediction(*state, out);
    return core::Status::kOk;
}

core::Status kalman_bandwidth_predict(
    const KalmanBandwidthState* state,
    KalmanBandwidthOutput* out) {
    if (state == nullptr || out == nullptr) {
        return core::Status::kInvalidArgument;
    }
    emit_prediction(*state, out);
    return core::Status::kOk;
}

}  // namespace upload
}  // namespace aether
