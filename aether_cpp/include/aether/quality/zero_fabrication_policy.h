// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_ZERO_FABRICATION_POLICY_H
#define AETHER_QUALITY_ZERO_FABRICATION_POLICY_H

#ifdef __cplusplus

namespace aether {
namespace quality {

enum class ZeroFabricationMode : unsigned char {
    kForensicStrict = 0u,
    kResearchRelaxed = 1u,
};

enum class MLAction : unsigned char {
    kCalibrationCorrection = 0u,
    kMultiViewDenoise = 1u,
    kOutlierRejection = 2u,
    kConfidenceEstimation = 3u,
    kUncertaintyEstimation = 4u,
    kTextureInpaint = 5u,
    kHoleFilling = 6u,
    kGeometryCompletion = 7u,
    kUnknownRegionGrowth = 8u,
};

enum class ReconstructionConfidenceClass : unsigned char {
    kMeasured = 0u,
    kEstimated = 1u,
    kUnknown = 2u,
};

enum class PolicySeverity : unsigned char {
    kInfo = 0u,
    kWarn = 1u,
    kBlock = 2u,
};

enum class ZeroFabricationReason : unsigned char {
    kBlockGenerativeAction = 0u,
    kBlockUnknownGrowth = 1u,
    kAllowObservedGrowth = 2u,
    kBlockCoordinateRewrite = 3u,
    kDenoiseDisplacementExceedsPolicy = 4u,
    kAllowDenoise = 5u,
    kAllowOutlierRejection = 6u,
    kAllowNonGenerativeCalibration = 7u,
};

struct ZeroFabricationPolicyConfig {
    ZeroFabricationMode mode{ZeroFabricationMode::kForensicStrict};
    float max_denoise_displacement_meters{0.0f};
};

struct ZeroFabricationContext {
    ReconstructionConfidenceClass confidence_class{ReconstructionConfidenceClass::kUnknown};
    bool has_direct_observation{false};
    float requested_point_displacement_meters{0.0f};
    int requested_new_geometry_count{0};
};

struct ZeroFabricationDecision {
    bool allowed{false};
    ZeroFabricationReason reason{ZeroFabricationReason::kBlockGenerativeAction};
    PolicySeverity severity{PolicySeverity::kBlock};
};

ZeroFabricationDecision evaluate_zero_fabrication(
    const ZeroFabricationPolicyConfig& config,
    MLAction action,
    const ZeroFabricationContext& context);

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_ZERO_FABRICATION_POLICY_H
