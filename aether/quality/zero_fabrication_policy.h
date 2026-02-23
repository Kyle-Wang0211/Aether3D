// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_ZERO_FABRICATION_POLICY_H
#define AETHER_QUALITY_ZERO_FABRICATION_POLICY_H

namespace aether {
namespace quality {

enum class ZeroFabricationMode {
    kForensicStrict = 0,
    kResearchRelaxed = 1,
};

enum class MLAction {
    kCalibrationCorrection = 0,
    kMultiViewDenoise = 1,
    kOutlierRejection = 2,
    kConfidenceEstimation = 3,
    kUncertaintyEstimation = 4,
    kTextureInpaint = 5,
    kHoleFilling = 6,
    kGeometryCompletion = 7,
    kUnknownRegionGrowth = 8,
};

enum class ReconstructionConfidenceClass {
    kMeasured = 0,
    kEstimated = 1,
    kUnknown = 2,
};

enum class ZeroFabricationReason {
    kAllowNonGenerativeCalibration = 0,
    kAllowDenoise = 1,
    kAllowOutlierRejection = 2,
    kAllowObservedGrowth = 3,
    kBlockGenerativeAction = 4,
    kBlockUnknownGrowth = 5,
    kBlockCoordinateRewrite = 6,
    kDenoiseDisplacementExceedsPolicy = 7,
};

enum class PolicySeverity {
    kInfo = 0,
    kWarn = 1,
    kBlock = 2,
};

struct ZeroFabricationPolicyConfig {
    ZeroFabricationMode mode{ZeroFabricationMode::kForensicStrict};
    float max_denoise_displacement_meters{0.002f};
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

inline bool is_generative_action(MLAction action) {
    switch (action) {
        case MLAction::kTextureInpaint:
        case MLAction::kHoleFilling:
        case MLAction::kGeometryCompletion:
        case MLAction::kUnknownRegionGrowth:
            return true;
        default:
            return false;
    }
}

inline ZeroFabricationDecision evaluate_zero_fabrication(
    const ZeroFabricationPolicyConfig& config,
    MLAction action,
    const ZeroFabricationContext& context) {
    ZeroFabricationDecision decision{};

    // Non-generative calibration actions always allowed
    if (action == MLAction::kCalibrationCorrection ||
        action == MLAction::kConfidenceEstimation ||
        action == MLAction::kUncertaintyEstimation) {
        decision.allowed = true;
        decision.reason = ZeroFabricationReason::kAllowNonGenerativeCalibration;
        decision.severity = PolicySeverity::kInfo;
        return decision;
    }

    // Outlier rejection always allowed
    if (action == MLAction::kOutlierRejection) {
        decision.allowed = true;
        decision.reason = ZeroFabricationReason::kAllowOutlierRejection;
        decision.severity = PolicySeverity::kInfo;
        return decision;
    }

    // Denoising: check displacement limit
    if (action == MLAction::kMultiViewDenoise) {
        if (context.requested_point_displacement_meters <= config.max_denoise_displacement_meters) {
            decision.allowed = true;
            decision.reason = ZeroFabricationReason::kAllowDenoise;
            decision.severity = PolicySeverity::kInfo;
        } else {
            decision.allowed = false;
            decision.reason = ZeroFabricationReason::kDenoiseDisplacementExceedsPolicy;
            decision.severity = PolicySeverity::kWarn;
        }
        return decision;
    }

    // Generative actions: block in forensic mode
    if (is_generative_action(action)) {
        if (config.mode == ZeroFabricationMode::kForensicStrict) {
            if (action == MLAction::kUnknownRegionGrowth) {
                decision.reason = ZeroFabricationReason::kBlockUnknownGrowth;
            } else {
                decision.reason = ZeroFabricationReason::kBlockGenerativeAction;
            }
            decision.allowed = false;
            decision.severity = PolicySeverity::kBlock;
        } else {
            // Research relaxed: allow if observed
            if (context.has_direct_observation) {
                decision.allowed = true;
                decision.reason = ZeroFabricationReason::kAllowObservedGrowth;
                decision.severity = PolicySeverity::kWarn;
            } else {
                decision.allowed = false;
                decision.reason = ZeroFabricationReason::kBlockUnknownGrowth;
                decision.severity = PolicySeverity::kBlock;
            }
        }
        return decision;
    }

    // Default: block
    decision.allowed = false;
    decision.reason = ZeroFabricationReason::kBlockCoordinateRewrite;
    decision.severity = PolicySeverity::kBlock;
    return decision;
}

}  // namespace quality
}  // namespace aether

#endif  // AETHER_QUALITY_ZERO_FABRICATION_POLICY_H
