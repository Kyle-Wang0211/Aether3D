// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_EVIDENCE_CONSTANTS_H
#define AETHER_EVIDENCE_EVIDENCE_CONSTANTS_H

namespace aether {
namespace evidence {

constexpr double PATCH_DISPLAY_ALPHA = 0.2;
constexpr double SOFT_WRITE_REQUIRES_GATE_MIN = 0.30;
constexpr double LOCK_THRESHOLD = 0.85;
constexpr int MIN_OBSERVATIONS_FOR_LOCK = 20;

constexpr double MINIMUM_SOFT_SCALE = 0.25;
constexpr double NO_TOKEN_PENALTY = 0.6;
constexpr double LOW_NOVELTY_THRESHOLD = 0.2;
constexpr double LOW_NOVELTY_PENALTY = 0.7;

constexpr double TOKEN_REFILL_RATE_PER_SEC = 2.0;
constexpr double TOKEN_BUCKET_MAX_TOKENS = 10.0;
constexpr double TOKEN_COST_PER_OBSERVATION = 1.0;

constexpr double DS_CONFLICT_SWITCH = 0.85;
constexpr double DS_EPSILON = 1e-9;
constexpr double DS_DEFAULT_OCCUPIED_GOOD = 0.8;
constexpr double DS_DEFAULT_UNKNOWN_GOOD = 0.2;
constexpr double DS_DEFAULT_FREE_BAD = 0.3;

static_assert(SOFT_WRITE_REQUIRES_GATE_MIN >= 0.25 && SOFT_WRITE_REQUIRES_GATE_MIN <= 0.35,
              "softWriteRequiresGateMin parity range");
static_assert(LOCK_THRESHOLD == 0.85, "lockThreshold parity");
static_assert(MIN_OBSERVATIONS_FOR_LOCK == 20, "minObservationsForLock parity");
static_assert(DS_CONFLICT_SWITCH == 0.85, "dsConflictSwitch parity");

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_EVIDENCE_CONSTANTS_H
