// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/pr1_admission_kernel.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace evidence {
namespace {

double clamp_non_negative_finite(double value, double fallback) {
    if (value != value || !std::isfinite(value) || value < 0.0) {
        return fallback;
    }
    return value;
}

}  // namespace

core::Status evaluate_pr1_admission(
    const PR1AdmissionInput& input,
    PR1AdmissionDecision* out_decision) {
    if (out_decision == nullptr) {
        return core::Status::kInvalidArgument;
    }

    PR1AdmissionDecision decision{};
    decision.classification = PR1Classification::kAccepted;
    decision.reason = PR1RejectReason::kNone;
    decision.eeb_delta = 0.0;
    decision.build_mode = input.current_mode;
    decision.guidance_signal = PR1GuidanceSignal::kNone;
    decision.hard_fuse_trigger = PR1HardFuseTrigger::kNone;

    const double ig_min_soft = clamp_non_negative_finite(input.ig_min_soft, 0.1);
    const double novelty_min_soft = clamp_non_negative_finite(input.novelty_min_soft, 0.1);
    const double eeb_min_quantum = clamp_non_negative_finite(input.eeb_min_quantum, 1.0);
    const double info_gain = clamp_non_negative_finite(input.info_gain, 0.0);
    const double novelty = clamp_non_negative_finite(input.novelty, 0.0);

    // 1) Duplicate has highest priority.
    if (input.is_duplicate) {
        decision.classification = PR1Classification::kDuplicateRejected;
        decision.reason = PR1RejectReason::kDuplicate;
        *out_decision = decision;
        return core::Status::kOk;
    }

    // 2) Hard fuse.
    if (input.hard_trigger != PR1HardFuseTrigger::kNone) {
        decision.classification = PR1Classification::kRejected;
        decision.reason = PR1RejectReason::kHardCap;
        decision.build_mode = PR1BuildMode::kSaturated;
        decision.guidance_signal = PR1GuidanceSignal::kStaticOverlay;
        decision.hard_fuse_trigger = input.hard_trigger;
        *out_decision = decision;
        return core::Status::kOk;
    }

    // 3) Soft damping.
    if (input.should_trigger_soft_limit) {
        if (info_gain < ig_min_soft || novelty < novelty_min_soft) {
            decision.classification = PR1Classification::kRejected;
            decision.reason =
                (info_gain < ig_min_soft)
                    ? PR1RejectReason::kLowGainSoft
                    : PR1RejectReason::kRedundantCoverage;
            decision.build_mode = PR1BuildMode::kDamping;
            decision.guidance_signal = PR1GuidanceSignal::kHeatCoolCoverage;
            *out_decision = decision;
            return core::Status::kOk;
        }
    }

    // 4) Accepted baseline.
    decision.classification = PR1Classification::kAccepted;
    decision.reason = PR1RejectReason::kNone;
    decision.eeb_delta = std::max(eeb_min_quantum, 0.0);
    decision.guidance_signal =
        (input.current_mode == PR1BuildMode::kDamping)
            ? PR1GuidanceSignal::kDirectionalAffordance
            : PR1GuidanceSignal::kNone;

    *out_decision = decision;
    return core::Status::kOk;
}

}  // namespace evidence
}  // namespace aether
