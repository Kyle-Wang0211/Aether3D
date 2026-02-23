// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_PR1_ADMISSION_KERNEL_H
#define AETHER_EVIDENCE_PR1_ADMISSION_KERNEL_H

#include "aether/core/status.h"
#include <cstdint>

namespace aether {
namespace evidence {

enum class PR1BuildMode : std::uint8_t {
    kNormal = 0,
    kDamping = 1,
    kSaturated = 2,
};

enum class PR1Classification : std::uint8_t {
    kAccepted = 0,
    kRejected = 1,
    kDuplicateRejected = 2,
};

enum class PR1RejectReason : std::uint8_t {
    kNone = 0,
    kLowGainSoft = 1,
    kRedundantCoverage = 2,
    kDuplicate = 3,
    kHardCap = 4,
};

enum class PR1GuidanceSignal : std::uint8_t {
    kNone = 0,
    kHeatCoolCoverage = 1,
    kDirectionalAffordance = 2,
    kStaticOverlay = 3,
};

enum class PR1HardFuseTrigger : std::uint8_t {
    kNone = 0,
    kPatchCountHard = 1,
    kEEBHard = 2,
};

struct PR1AdmissionInput {
    bool is_duplicate{false};
    PR1BuildMode current_mode{PR1BuildMode::kNormal};
    bool should_trigger_soft_limit{false};
    PR1HardFuseTrigger hard_trigger{PR1HardFuseTrigger::kNone};
    double info_gain{0.0};
    double novelty{0.0};
    double ig_min_soft{0.1};
    double novelty_min_soft{0.1};
    double eeb_min_quantum{1.0};
};

struct PR1AdmissionDecision {
    PR1Classification classification{PR1Classification::kAccepted};
    PR1RejectReason reason{PR1RejectReason::kNone};
    double eeb_delta{0.0};
    PR1BuildMode build_mode{PR1BuildMode::kNormal};
    PR1GuidanceSignal guidance_signal{PR1GuidanceSignal::kNone};
    PR1HardFuseTrigger hard_fuse_trigger{PR1HardFuseTrigger::kNone};
};

core::Status evaluate_pr1_admission(
    const PR1AdmissionInput& input,
    PR1AdmissionDecision* out_decision);

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_PR1_ADMISSION_KERNEL_H
