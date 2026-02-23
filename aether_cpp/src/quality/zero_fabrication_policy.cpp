// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/zero_fabrication_policy.h"

namespace aether {
namespace quality {

ZeroFabricationDecision evaluate_zero_fabrication(
    const ZeroFabricationPolicyConfig& config,
    MLAction action,
    const ZeroFabricationContext& context) {
    switch (action) {
        case MLAction::kTextureInpaint:
        case MLAction::kHoleFilling:
        case MLAction::kGeometryCompletion:
            return ZeroFabricationDecision{
                false,
                ZeroFabricationReason::kBlockGenerativeAction,
                PolicySeverity::kBlock};

        case MLAction::kUnknownRegionGrowth:
            if (context.confidence_class == ReconstructionConfidenceClass::kUnknown ||
                !context.has_direct_observation) {
                return ZeroFabricationDecision{
                    false,
                    ZeroFabricationReason::kBlockUnknownGrowth,
                    PolicySeverity::kBlock};
            }
            return ZeroFabricationDecision{
                true,
                ZeroFabricationReason::kAllowObservedGrowth,
                PolicySeverity::kInfo};

        case MLAction::kMultiViewDenoise:
            if (config.mode == ZeroFabricationMode::kForensicStrict &&
                context.requested_point_displacement_meters > 0.0f) {
                return ZeroFabricationDecision{
                    false,
                    ZeroFabricationReason::kBlockCoordinateRewrite,
                    PolicySeverity::kBlock};
            }
            if (context.requested_point_displacement_meters >
                config.max_denoise_displacement_meters) {
                return ZeroFabricationDecision{
                    false,
                    ZeroFabricationReason::kDenoiseDisplacementExceedsPolicy,
                    PolicySeverity::kBlock};
            }
            return ZeroFabricationDecision{
                true,
                ZeroFabricationReason::kAllowDenoise,
                PolicySeverity::kInfo};

        case MLAction::kOutlierRejection:
            return ZeroFabricationDecision{
                true,
                ZeroFabricationReason::kAllowOutlierRejection,
                PolicySeverity::kInfo};

        case MLAction::kCalibrationCorrection:
        case MLAction::kConfidenceEstimation:
        case MLAction::kUncertaintyEstimation:
        default:
            return ZeroFabricationDecision{
                true,
                ZeroFabricationReason::kAllowNonGenerativeCalibration,
                PolicySeverity::kInfo};
    }
}

}  // namespace quality
}  // namespace aether
