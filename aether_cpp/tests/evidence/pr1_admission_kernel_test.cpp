// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/pr1_admission_kernel.h"

#include <cstdio>

int main() {
    using namespace aether::evidence;
    int failed = 0;

    PR1AdmissionDecision decision{};
    PR1AdmissionInput input{};
    input.current_mode = PR1BuildMode::kNormal;
    input.eeb_min_quantum = 1.0;

    // Accepted path.
    if (evaluate_pr1_admission(input, &decision) != aether::core::Status::kOk ||
        decision.classification != PR1Classification::kAccepted ||
        decision.reason != PR1RejectReason::kNone ||
        decision.eeb_delta != 1.0) {
        std::fprintf(stderr, "accepted path mismatch\n");
        failed++;
    }

    // Duplicate dominates all other gates.
    input.is_duplicate = true;
    input.hard_trigger = PR1HardFuseTrigger::kPatchCountHard;
    if (evaluate_pr1_admission(input, &decision) != aether::core::Status::kOk ||
        decision.classification != PR1Classification::kDuplicateRejected ||
        decision.reason != PR1RejectReason::kDuplicate ||
        decision.hard_fuse_trigger != PR1HardFuseTrigger::kNone) {
        std::fprintf(stderr, "duplicate priority mismatch\n");
        failed++;
    }

    // Hard fuse.
    input.is_duplicate = false;
    input.hard_trigger = PR1HardFuseTrigger::kPatchCountHard;
    if (evaluate_pr1_admission(input, &decision) != aether::core::Status::kOk ||
        decision.classification != PR1Classification::kRejected ||
        decision.reason != PR1RejectReason::kHardCap ||
        decision.build_mode != PR1BuildMode::kSaturated ||
        decision.guidance_signal != PR1GuidanceSignal::kStaticOverlay ||
        decision.hard_fuse_trigger != PR1HardFuseTrigger::kPatchCountHard) {
        std::fprintf(stderr, "hard fuse mismatch\n");
        failed++;
    }

    // Soft reject by information gain.
    input.hard_trigger = PR1HardFuseTrigger::kNone;
    input.current_mode = PR1BuildMode::kDamping;
    input.should_trigger_soft_limit = true;
    input.info_gain = 0.01;
    input.novelty = 0.9;
    input.ig_min_soft = 0.1;
    input.novelty_min_soft = 0.1;
    if (evaluate_pr1_admission(input, &decision) != aether::core::Status::kOk ||
        decision.classification != PR1Classification::kRejected ||
        decision.reason != PR1RejectReason::kLowGainSoft ||
        decision.build_mode != PR1BuildMode::kDamping ||
        decision.guidance_signal != PR1GuidanceSignal::kHeatCoolCoverage) {
        std::fprintf(stderr, "soft reject info gain mismatch\n");
        failed++;
    }

    // Soft pass in damping keeps directional guidance.
    input.info_gain = 0.7;
    input.novelty = 0.8;
    if (evaluate_pr1_admission(input, &decision) != aether::core::Status::kOk ||
        decision.classification != PR1Classification::kAccepted ||
        decision.reason != PR1RejectReason::kNone ||
        decision.guidance_signal != PR1GuidanceSignal::kDirectionalAffordance) {
        std::fprintf(stderr, "soft pass damping mismatch\n");
        failed++;
    }

    if (evaluate_pr1_admission(input, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid argument mismatch\n");
        failed++;
    }

    return failed;
}
