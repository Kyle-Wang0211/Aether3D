// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/upload/kalman_bandwidth.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

static bool near(double a, double b, double eps = 1e-3) {
    return std::fabs(a - b) <= eps;
}

// ---------------------------------------------------------------------------
// Null safety
// ---------------------------------------------------------------------------

static void test_null_state() {
    aether::upload::KalmanBandwidthOutput out{};
    CHECK(aether::upload::kalman_bandwidth_step(nullptr, 1000, 1.0, &out) ==
          aether::core::Status::kInvalidArgument);
}

static void test_null_predict_state() {
    aether::upload::KalmanBandwidthOutput out{};
    CHECK(aether::upload::kalman_bandwidth_predict(nullptr, &out) ==
          aether::core::Status::kInvalidArgument);
}

static void test_null_predict_output() {
    aether::upload::KalmanBandwidthState state{};
    CHECK(aether::upload::kalman_bandwidth_predict(&state, nullptr) ==
          aether::core::Status::kInvalidArgument);
}

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

static void test_reset_null() {
    aether::upload::kalman_bandwidth_reset(nullptr);  // Should not crash
}

static void test_reset_clears_state() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    aether::upload::kalman_bandwidth_step(&state, 1000000, 1.0, &out);
    CHECK(state.total_samples == 1);
    aether::upload::kalman_bandwidth_reset(&state);
    CHECK(state.total_samples == 0);
    CHECK(state.recent_count == 0);
}

// ---------------------------------------------------------------------------
// Basic step and predict
// ---------------------------------------------------------------------------

static void test_single_step() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    // 1MB in 1 second = 8 Mbps
    CHECK(aether::upload::kalman_bandwidth_step(&state, 1000000, 1.0, &out) ==
          aether::core::Status::kOk);
    CHECK(out.predicted_bps > 0.0);
    CHECK(std::isfinite(out.predicted_bps));
    CHECK(out.ci_low >= 0.0);
    CHECK(out.ci_high >= out.ci_low);
}

static void test_convergence_to_steady_state() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    // Feed 10 identical measurements: 1MB in 0.1s = 80 Mbps
    const double expected_bps = 80000000.0;  // 80 Mbps
    for (int i = 0; i < 10; ++i) {
        CHECK(aether::upload::kalman_bandwidth_step(&state, 10000000, 1.0, &out) ==
              aether::core::Status::kOk);
    }
    // After 10 identical samples, prediction should be close to measurement
    CHECK(std::fabs(out.predicted_bps - expected_bps) / expected_bps < 0.05);
    CHECK(out.trend == aether::upload::BandwidthTrend::kStable);
}

static void test_zero_duration_skips() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    CHECK(aether::upload::kalman_bandwidth_step(&state, 1000, 0.0, &out) ==
          aether::core::Status::kOk);
    CHECK(state.total_samples == 0);  // Should not increment
}

static void test_negative_duration_skips() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    CHECK(aether::upload::kalman_bandwidth_step(&state, 1000, -1.0, &out) ==
          aether::core::Status::kOk);
    CHECK(state.total_samples == 0);
}

static void test_nan_duration_skips() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    CHECK(aether::upload::kalman_bandwidth_step(
              &state, 1000,
              std::numeric_limits<double>::quiet_NaN(), &out) ==
          aether::core::Status::kOk);
    CHECK(state.total_samples == 0);
}

// ---------------------------------------------------------------------------
// Joseph form stability tests
// ---------------------------------------------------------------------------

static void test_covariance_stays_positive() {
    // After many steps, diagonal of P must remain positive
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    for (int i = 0; i < 100; ++i) {
        const std::int64_t bytes = static_cast<std::int64_t>(100000 + (i % 7) * 10000);
        aether::upload::kalman_bandwidth_step(&state, bytes, 0.1, &out);
    }
    // Check P diagonal
    CHECK(state.p[0] > 0.0);   // p[0,0]
    CHECK(state.p[5] > 0.0);   // p[1,1]
    CHECK(state.p[10] > 0.0);  // p[2,2]
    CHECK(state.p[15] > 0.0);  // p[3,3]
}

static void test_covariance_symmetric() {
    // After many steps, P must be symmetric
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    for (int i = 0; i < 50; ++i) {
        aether::upload::kalman_bandwidth_step(&state, 500000 + i * 1000, 0.5, &out);
    }
    for (int r = 0; r < 4; ++r) {
        for (int c = r + 1; c < 4; ++c) {
            const double prc = state.p[static_cast<std::size_t>(r * 4 + c)];
            const double pcr = state.p[static_cast<std::size_t>(c * 4 + r)];
            CHECK(near(prc, pcr, 1e-15));
        }
    }
}

static void test_all_finite_after_extreme_values() {
    // Feed extreme measurements to stress the filter
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    aether::upload::kalman_bandwidth_step(&state, 1, 0.001, &out);
    aether::upload::kalman_bandwidth_step(&state, 1000000000LL, 0.001, &out);
    aether::upload::kalman_bandwidth_step(&state, 1, 100.0, &out);
    aether::upload::kalman_bandwidth_step(&state, 1000000000LL, 100.0, &out);

    CHECK(std::isfinite(out.predicted_bps));
    CHECK(std::isfinite(out.ci_low));
    CHECK(std::isfinite(out.ci_high));
    // All P values must be finite
    for (double v : state.p) {
        CHECK(std::isfinite(v));
    }
    for (double v : state.x) {
        CHECK(std::isfinite(v));
    }
}

// ---------------------------------------------------------------------------
// NaN corruption auto-reset
// ---------------------------------------------------------------------------

static void test_nan_recovery() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    // Manually corrupt state
    state.x[0] = std::numeric_limits<double>::quiet_NaN();
    state.p[0] = std::numeric_limits<double>::quiet_NaN();
    // Next step should auto-reset
    CHECK(aether::upload::kalman_bandwidth_step(&state, 1000000, 1.0, &out) ==
          aether::core::Status::kOk);
    CHECK(std::isfinite(out.predicted_bps));
    CHECK(std::isfinite(state.x[0]));
    for (double v : state.p) {
        CHECK(std::isfinite(v));
    }
}

// ---------------------------------------------------------------------------
// Trend detection
// ---------------------------------------------------------------------------

static void test_rising_trend() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    // Feed increasing bandwidth
    for (int i = 1; i <= 10; ++i) {
        const std::int64_t bytes = static_cast<std::int64_t>(i) * 1000000;
        aether::upload::kalman_bandwidth_step(&state, bytes, 1.0, &out);
    }
    CHECK(out.trend == aether::upload::BandwidthTrend::kRising);
}

static void test_falling_trend() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    // Feed decreasing bandwidth
    for (int i = 10; i >= 1; --i) {
        const std::int64_t bytes = static_cast<std::int64_t>(i) * 1000000;
        aether::upload::kalman_bandwidth_step(&state, bytes, 1.0, &out);
    }
    CHECK(out.trend == aether::upload::BandwidthTrend::kFalling);
}

// ---------------------------------------------------------------------------
// Predict without step
// ---------------------------------------------------------------------------

static void test_predict_initial_state() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    CHECK(aether::upload::kalman_bandwidth_predict(&state, &out) ==
          aether::core::Status::kOk);
    CHECK(near(out.predicted_bps, 0.0));
    CHECK(!out.reliable);  // No samples => not reliable
}

// ---------------------------------------------------------------------------
// Mahalanobis outlier attenuation
// ---------------------------------------------------------------------------

static void test_outlier_attenuation() {
    aether::upload::KalmanBandwidthState state{};
    aether::upload::KalmanBandwidthOutput out{};
    // Establish steady state at ~80 Mbps
    for (int i = 0; i < 10; ++i) {
        aether::upload::kalman_bandwidth_step(&state, 10000000, 1.0, &out);
    }
    const double before = out.predicted_bps;
    // Inject extreme outlier: 100x normal
    aether::upload::kalman_bandwidth_step(&state, 1000000000LL, 1.0, &out);
    // The gain_scale=0.5 attenuates the outlier's impact
    // Prediction shouldn't jump all the way to the outlier
    CHECK(out.predicted_bps < before * 50.0);
}

int main() {
    test_null_state();
    test_null_predict_state();
    test_null_predict_output();
    test_reset_null();
    test_reset_clears_state();
    test_single_step();
    test_convergence_to_steady_state();
    test_zero_duration_skips();
    test_negative_duration_skips();
    test_nan_duration_skips();
    test_covariance_stays_positive();
    test_covariance_symmetric();
    test_all_finite_after_extreme_values();
    test_nan_recovery();
    test_rising_trend();
    test_falling_trend();
    test_predict_initial_state();
    test_outlier_attenuation();

    if (g_failed == 0) {
        std::fprintf(stdout, "kalman_bandwidth_test: all tests passed\n");
    }
    return g_failed;
}
