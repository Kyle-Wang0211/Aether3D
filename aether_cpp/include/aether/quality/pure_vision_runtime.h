// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_PURE_VISION_RUNTIME_H
#define AETHER_QUALITY_PURE_VISION_RUNTIME_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>

namespace aether {
namespace quality {

enum class CrossValidationDecision : std::uint8_t {
    kKeep = 0u,
    kDowngrade = 1u,
    kReject = 2u,
};

enum class CrossValidationReasonCode : std::uint8_t {
    kOutlierBothInlier = 0u,
    kOutlierBothReject = 1u,
    kOutlierDisagreementDowngrade = 2u,
    kCalibrationBothPass = 3u,
    kCalibrationBothFail = 4u,
    kCalibrationDisagreementOrDivergence = 5u,
};

struct OutlierCrossValidationInput {
    bool rule_inlier{false};
    double ml_inlier_score{0.0};
    double ml_inlier_threshold{0.0};
};

struct CalibrationCrossValidationInput {
    double baseline_error_cm{0.0};
    double ml_error_cm{0.0};
    double max_allowed_error_cm{0.0};
    double max_divergence_cm{0.0};
};

struct CrossValidationOutcome {
    CrossValidationDecision decision{CrossValidationDecision::kDowngrade};
    CrossValidationReasonCode reason{CrossValidationReasonCode::kOutlierDisagreementDowngrade};
};

CrossValidationOutcome evaluate_outlier_cross_validation(const OutlierCrossValidationInput& input);
CrossValidationOutcome evaluate_calibration_cross_validation(const CalibrationCrossValidationInput& input);

enum class PureVisionGateId : std::uint8_t {
    kBaselinePixels = 0u,
    kBlurLaplacian = 1u,
    kOrbFeatureCount = 2u,
    kParallaxRatio = 3u,
    kDepthSigma = 4u,
    kClosureRatio = 5u,
    kUnknownVoxelRatio = 6u,
    kThermalCelsius = 7u,
};

struct PureVisionRuntimeMetrics {
    double baseline_pixels{0.0};
    double blur_laplacian{0.0};
    std::int32_t orb_features{0};
    double parallax_ratio{0.0};
    double depth_sigma_meters{0.0};
    double closure_ratio{0.0};
    double unknown_voxel_ratio{0.0};
    double thermal_celsius{0.0};
};

struct PureVisionGateThresholds {
    double min_baseline_pixels{3.0};
    double min_blur_laplacian{200.0};
    std::int32_t min_orb_features{500};
    double min_parallax_ratio{0.2};
    double max_depth_sigma_meters{0.015};
    double min_closure_ratio{0.97};
    double max_unknown_voxel_ratio{0.03};
    double max_thermal_celsius{45.0};
};

struct PureVisionGateEvaluation {
    PureVisionGateId gate_id{PureVisionGateId::kBaselinePixels};
    bool passed{false};
    double observed{0.0};
    double threshold{0.0};
    bool comparator_greater_equal{true};
};

constexpr std::size_t kPureVisionGateCount = 8u;

std::size_t evaluate_pure_vision_gates(
    const PureVisionRuntimeMetrics& metrics,
    const PureVisionGateThresholds& thresholds,
    PureVisionGateEvaluation out_evaluations[kPureVisionGateCount]);

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_PURE_VISION_RUNTIME_H
