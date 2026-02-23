// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/pure_vision_runtime.h"

#include <cmath>

namespace aether {
namespace quality {

CrossValidationOutcome evaluate_outlier_cross_validation(const OutlierCrossValidationInput& input) {
    const bool ml_says_inlier = input.ml_inlier_score >= input.ml_inlier_threshold;
    if (input.rule_inlier && ml_says_inlier) {
        return CrossValidationOutcome{
            CrossValidationDecision::kKeep,
            CrossValidationReasonCode::kOutlierBothInlier};
    }
    if (!input.rule_inlier && !ml_says_inlier) {
        return CrossValidationOutcome{
            CrossValidationDecision::kReject,
            CrossValidationReasonCode::kOutlierBothReject};
    }
    return CrossValidationOutcome{
        CrossValidationDecision::kDowngrade,
        CrossValidationReasonCode::kOutlierDisagreementDowngrade};
}

CrossValidationOutcome evaluate_calibration_cross_validation(const CalibrationCrossValidationInput& input) {
    const bool baseline_good = input.baseline_error_cm <= input.max_allowed_error_cm;
    const bool ml_good = input.ml_error_cm <= input.max_allowed_error_cm;
    const double divergence = std::fabs(input.baseline_error_cm - input.ml_error_cm);
    const bool consistent = divergence <= input.max_divergence_cm;

    if (baseline_good && ml_good && consistent) {
        return CrossValidationOutcome{
            CrossValidationDecision::kKeep,
            CrossValidationReasonCode::kCalibrationBothPass};
    }
    if (!baseline_good && !ml_good) {
        return CrossValidationOutcome{
            CrossValidationDecision::kReject,
            CrossValidationReasonCode::kCalibrationBothFail};
    }
    return CrossValidationOutcome{
        CrossValidationDecision::kDowngrade,
        CrossValidationReasonCode::kCalibrationDisagreementOrDivergence};
}

namespace {

PureVisionGateEvaluation make_eval(
    PureVisionGateId gate_id,
    bool passed,
    double observed,
    double threshold,
    bool comparator_greater_equal) {
    PureVisionGateEvaluation out{};
    out.gate_id = gate_id;
    out.passed = passed;
    out.observed = observed;
    out.threshold = threshold;
    out.comparator_greater_equal = comparator_greater_equal;
    return out;
}

}  // namespace

std::size_t evaluate_pure_vision_gates(
    const PureVisionRuntimeMetrics& metrics,
    const PureVisionGateThresholds& thresholds,
    PureVisionGateEvaluation out_evaluations[kPureVisionGateCount]) {
    if (out_evaluations == nullptr) {
        return 0u;
    }

    out_evaluations[0] = make_eval(
        PureVisionGateId::kBaselinePixels,
        metrics.baseline_pixels >= thresholds.min_baseline_pixels,
        metrics.baseline_pixels,
        thresholds.min_baseline_pixels,
        true);
    out_evaluations[1] = make_eval(
        PureVisionGateId::kBlurLaplacian,
        metrics.blur_laplacian >= thresholds.min_blur_laplacian,
        metrics.blur_laplacian,
        thresholds.min_blur_laplacian,
        true);
    out_evaluations[2] = make_eval(
        PureVisionGateId::kOrbFeatureCount,
        metrics.orb_features >= thresholds.min_orb_features,
        static_cast<double>(metrics.orb_features),
        static_cast<double>(thresholds.min_orb_features),
        true);
    out_evaluations[3] = make_eval(
        PureVisionGateId::kParallaxRatio,
        metrics.parallax_ratio >= thresholds.min_parallax_ratio,
        metrics.parallax_ratio,
        thresholds.min_parallax_ratio,
        true);
    out_evaluations[4] = make_eval(
        PureVisionGateId::kDepthSigma,
        metrics.depth_sigma_meters <= thresholds.max_depth_sigma_meters,
        metrics.depth_sigma_meters,
        thresholds.max_depth_sigma_meters,
        false);
    out_evaluations[5] = make_eval(
        PureVisionGateId::kClosureRatio,
        metrics.closure_ratio >= thresholds.min_closure_ratio,
        metrics.closure_ratio,
        thresholds.min_closure_ratio,
        true);
    out_evaluations[6] = make_eval(
        PureVisionGateId::kUnknownVoxelRatio,
        metrics.unknown_voxel_ratio <= thresholds.max_unknown_voxel_ratio,
        metrics.unknown_voxel_ratio,
        thresholds.max_unknown_voxel_ratio,
        false);
    out_evaluations[7] = make_eval(
        PureVisionGateId::kThermalCelsius,
        metrics.thermal_celsius <= thresholds.max_thermal_celsius,
        metrics.thermal_celsius,
        thresholds.max_thermal_celsius,
        false);

    return kPureVisionGateCount;
}

}  // namespace quality
}  // namespace aether
