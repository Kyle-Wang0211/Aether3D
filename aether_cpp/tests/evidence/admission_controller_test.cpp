// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/admission_controller.h"
#include "aether/evidence/evidence_constants.h"

#include <cstdio>

int main() {
    int failed = 0;
    using namespace aether::evidence;

    AdmissionController admission;
    const std::string patch_id = "weak_texture_patch";

    // First observation should be allowed.
    EvidenceAdmissionDecision first = admission.check_admission(patch_id, 0.0, 1000);
    if (!first.allowed) {
        std::fprintf(stderr, "first observation should be allowed\n");
        failed++;
    }

    // Dense same-patch updates should be hard-blocked by time-density gate.
    EvidenceAdmissionDecision blocked = admission.check_admission(patch_id, 0.0, 1010);
    if (blocked.allowed || !blocked.is_hard_blocked() ||
        !blocked.has_reason(EvidenceAdmissionReason::kTimeDensitySamePatch)) {
        std::fprintf(stderr, "time-density hard block failed\n");
        failed++;
    }

    // Allowed observations must keep minimum throughput.
    bool saw_allowed = false;
    for (int i = 0; i < 60; ++i) {
        const int64_t ts = 2000 + i * 40;  // >33ms, allows checks to pass through.
        EvidenceAdmissionDecision decision = admission.check_admission(patch_id, 0.0, ts);
        if (decision.allowed) {
            saw_allowed = true;
            if (decision.quality_scale < MINIMUM_SOFT_SCALE) {
                std::fprintf(stderr, "minimum throughput broken: %.6f\n", decision.quality_scale);
                failed++;
                break;
            }
        }
    }
    if (!saw_allowed) {
        std::fprintf(stderr, "expected at least one allowed decision\n");
        failed++;
    }

    // Confirmed spam path.
    EvidenceAdmissionDecision spam = admission.check_confirmed_spam(patch_id, 0.97);
    if (spam.allowed || !spam.has_reason(EvidenceAdmissionReason::kConfirmedSpam)) {
        std::fprintf(stderr, "confirmed spam hard block failed\n");
        failed++;
    }

    return failed;
}
