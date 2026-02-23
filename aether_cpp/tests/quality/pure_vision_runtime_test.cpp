// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/pure_vision_runtime.h"

#include <cmath>
#include <cstdio>

static int g_failed = 0;

static void check(bool cond, const char* msg, int line) {
    if (!cond) {
        std::fprintf(stderr, "FAIL [line %d]: %s\n", line, msg);
        ++g_failed;
    }
}
#define CHECK(cond) check((cond), #cond, __LINE__)

// ---------------------------------------------------------------------------
// evaluate_outlier_cross_validation
// ---------------------------------------------------------------------------

static void test_outlier_both_inlier() {
    using namespace aether::quality;
    OutlierCrossValidationInput in{};
    in.rule_inlier = true;
    in.ml_inlier_score = 0.9;
    in.ml_inlier_threshold = 0.5;
    auto out = evaluate_outlier_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kKeep);
    CHECK(out.reason == CrossValidationReasonCode::kOutlierBothInlier);
}

static void test_outlier_both_reject() {
    using namespace aether::quality;
    OutlierCrossValidationInput in{};
    in.rule_inlier = false;
    in.ml_inlier_score = 0.1;
    in.ml_inlier_threshold = 0.5;
    auto out = evaluate_outlier_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kReject);
    CHECK(out.reason == CrossValidationReasonCode::kOutlierBothReject);
}

static void test_outlier_disagreement_rule_yes_ml_no() {
    using namespace aether::quality;
    OutlierCrossValidationInput in{};
    in.rule_inlier = true;
    in.ml_inlier_score = 0.1;
    in.ml_inlier_threshold = 0.5;
    auto out = evaluate_outlier_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kDowngrade);
}

static void test_outlier_disagreement_rule_no_ml_yes() {
    using namespace aether::quality;
    OutlierCrossValidationInput in{};
    in.rule_inlier = false;
    in.ml_inlier_score = 0.9;
    in.ml_inlier_threshold = 0.5;
    auto out = evaluate_outlier_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kDowngrade);
}

static void test_outlier_exact_threshold() {
    using namespace aether::quality;
    OutlierCrossValidationInput in{};
    in.rule_inlier = true;
    in.ml_inlier_score = 0.5;
    in.ml_inlier_threshold = 0.5;
    auto out = evaluate_outlier_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kKeep);
}

// ---------------------------------------------------------------------------
// evaluate_calibration_cross_validation
// ---------------------------------------------------------------------------

static void test_calibration_both_pass() {
    using namespace aether::quality;
    CalibrationCrossValidationInput in{};
    in.baseline_error_cm = 0.5;
    in.ml_error_cm = 0.6;
    in.max_allowed_error_cm = 1.0;
    in.max_divergence_cm = 0.5;
    auto out = evaluate_calibration_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kKeep);
    CHECK(out.reason == CrossValidationReasonCode::kCalibrationBothPass);
}

static void test_calibration_both_fail() {
    using namespace aether::quality;
    CalibrationCrossValidationInput in{};
    in.baseline_error_cm = 5.0;
    in.ml_error_cm = 6.0;
    in.max_allowed_error_cm = 1.0;
    in.max_divergence_cm = 2.0;
    auto out = evaluate_calibration_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kReject);
    CHECK(out.reason == CrossValidationReasonCode::kCalibrationBothFail);
}

static void test_calibration_disagreement() {
    using namespace aether::quality;
    CalibrationCrossValidationInput in{};
    in.baseline_error_cm = 0.5;
    in.ml_error_cm = 5.0;
    in.max_allowed_error_cm = 1.0;
    in.max_divergence_cm = 0.5;
    auto out = evaluate_calibration_cross_validation(in);
    CHECK(out.decision == CrossValidationDecision::kDowngrade);
}

static void test_calibration_consistent_but_high_divergence() {
    using namespace aether::quality;
    CalibrationCrossValidationInput in{};
    in.baseline_error_cm = 0.3;
    in.ml_error_cm = 0.9;
    in.max_allowed_error_cm = 1.0;
    in.max_divergence_cm = 0.1;  // Very tight consistency
    auto out = evaluate_calibration_cross_validation(in);
    // Both pass error threshold but divergence is too high
    CHECK(out.decision == CrossValidationDecision::kDowngrade);
}

// ---------------------------------------------------------------------------
// evaluate_pure_vision_gates
// ---------------------------------------------------------------------------

static void test_gates_all_pass() {
    using namespace aether::quality;
    PureVisionRuntimeMetrics m{};
    m.baseline_pixels = 10.0;
    m.blur_laplacian = 500.0;
    m.orb_features = 1000;
    m.parallax_ratio = 0.5;
    m.depth_sigma_meters = 0.005;
    m.closure_ratio = 0.99;
    m.unknown_voxel_ratio = 0.01;
    m.thermal_celsius = 30.0;

    PureVisionGateThresholds t{};
    PureVisionGateEvaluation evals[kPureVisionGateCount] = {};
    std::size_t count = evaluate_pure_vision_gates(m, t, evals);
    CHECK(count == kPureVisionGateCount);
    for (std::size_t i = 0; i < count; ++i) {
        CHECK(evals[i].passed);
    }
}

static void test_gates_all_fail() {
    using namespace aether::quality;
    PureVisionRuntimeMetrics m{};
    // All below/above thresholds
    m.baseline_pixels = 1.0;
    m.blur_laplacian = 50.0;
    m.orb_features = 100;
    m.parallax_ratio = 0.05;
    m.depth_sigma_meters = 0.05;
    m.closure_ratio = 0.50;
    m.unknown_voxel_ratio = 0.10;
    m.thermal_celsius = 60.0;

    PureVisionGateThresholds t{};
    PureVisionGateEvaluation evals[kPureVisionGateCount] = {};
    std::size_t count = evaluate_pure_vision_gates(m, t, evals);
    CHECK(count == kPureVisionGateCount);
    for (std::size_t i = 0; i < count; ++i) {
        CHECK(!evals[i].passed);
    }
}

static void test_gates_null_output() {
    using namespace aether::quality;
    PureVisionRuntimeMetrics m{};
    PureVisionGateThresholds t{};
    std::size_t count = evaluate_pure_vision_gates(m, t, nullptr);
    CHECK(count == 0u);
}

static void test_gates_gate_ids() {
    using namespace aether::quality;
    PureVisionRuntimeMetrics m{};
    PureVisionGateThresholds t{};
    PureVisionGateEvaluation evals[kPureVisionGateCount] = {};
    evaluate_pure_vision_gates(m, t, evals);
    CHECK(evals[0].gate_id == PureVisionGateId::kBaselinePixels);
    CHECK(evals[1].gate_id == PureVisionGateId::kBlurLaplacian);
    CHECK(evals[2].gate_id == PureVisionGateId::kOrbFeatureCount);
    CHECK(evals[3].gate_id == PureVisionGateId::kParallaxRatio);
    CHECK(evals[4].gate_id == PureVisionGateId::kDepthSigma);
    CHECK(evals[5].gate_id == PureVisionGateId::kClosureRatio);
    CHECK(evals[6].gate_id == PureVisionGateId::kUnknownVoxelRatio);
    CHECK(evals[7].gate_id == PureVisionGateId::kThermalCelsius);
}

static void test_gates_comparator_direction() {
    using namespace aether::quality;
    PureVisionRuntimeMetrics m{};
    PureVisionGateThresholds t{};
    PureVisionGateEvaluation evals[kPureVisionGateCount] = {};
    evaluate_pure_vision_gates(m, t, evals);
    // >= comparator gates
    CHECK(evals[0].comparator_greater_equal);   // baseline_pixels
    CHECK(evals[1].comparator_greater_equal);   // blur_laplacian
    CHECK(evals[2].comparator_greater_equal);   // orb_features
    CHECK(evals[3].comparator_greater_equal);   // parallax_ratio
    CHECK(evals[5].comparator_greater_equal);   // closure_ratio
    // <= comparator gates
    CHECK(!evals[4].comparator_greater_equal);  // depth_sigma
    CHECK(!evals[6].comparator_greater_equal);  // unknown_voxel
    CHECK(!evals[7].comparator_greater_equal);  // thermal
}

int main() {
    test_outlier_both_inlier();
    test_outlier_both_reject();
    test_outlier_disagreement_rule_yes_ml_no();
    test_outlier_disagreement_rule_no_ml_yes();
    test_outlier_exact_threshold();

    test_calibration_both_pass();
    test_calibration_both_fail();
    test_calibration_disagreement();
    test_calibration_consistent_but_high_divergence();

    test_gates_all_pass();
    test_gates_all_fail();
    test_gates_null_output();
    test_gates_gate_ids();
    test_gates_comparator_direction();

    if (g_failed == 0) {
        std::fprintf(stdout, "pure_vision_runtime_test: all tests passed\n");
    }
    return g_failed;
}
