// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TIME_ANCHOR_POLICY_H
#define AETHER_TIME_ANCHOR_POLICY_H

#include <cstdint>
#include <vector>

namespace aether {
namespace time {

enum class AnchorEventKind : uint8_t {
    kSessionStart = 0,
    kPeriodic = 1,
    kSessionEnd = 2,
};

struct AnchorEvent {
    AnchorEventKind kind{AnchorEventKind::kPeriodic};
    int64_t timestamp_ms{0};
};

struct AnchorPolicyConfig {
    int64_t periodic_interval_ms{60000};  // 60s hard policy
};

enum AnchorPolicyViolation : uint32_t {
    kMissingSessionStart = 1u << 0,
    kMissingSessionEnd = 1u << 1,
    kPeriodicGapTooLarge = 1u << 2,
    kOutOfOrder = 1u << 3,
};

struct AnchorPolicyResult {
    bool pass{false};
    uint32_t violation_mask{0};
    int64_t max_gap_ms{0};
};

inline bool has_violation(uint32_t mask, AnchorPolicyViolation v) {
    return (mask & static_cast<uint32_t>(v)) != 0;
}

inline AnchorPolicyResult evaluate_anchor_policy(
    const std::vector<AnchorEvent>& events,
    const AnchorPolicyConfig& config) {
    AnchorPolicyResult result{};
    if (events.empty()) {
        result.violation_mask |= static_cast<uint32_t>(kMissingSessionStart);
        result.violation_mask |= static_cast<uint32_t>(kMissingSessionEnd);
        return result;
    }

    bool saw_start = false;
    bool saw_end = false;
    int64_t last_ms = events.front().timestamp_ms;
    int64_t max_gap_ms = 0;

    for (size_t i = 0; i < events.size(); ++i) {
        const AnchorEvent& event = events[i];
        if (event.timestamp_ms < last_ms) {
            result.violation_mask |= static_cast<uint32_t>(kOutOfOrder);
        }
        if (i > 0) {
            const int64_t gap_ms = event.timestamp_ms - last_ms;
            if (gap_ms > max_gap_ms) {
                max_gap_ms = gap_ms;
            }
            if (gap_ms > config.periodic_interval_ms) {
                result.violation_mask |= static_cast<uint32_t>(kPeriodicGapTooLarge);
            }
        }
        if (event.kind == AnchorEventKind::kSessionStart) {
            saw_start = true;
            if (i != 0) {
                result.violation_mask |= static_cast<uint32_t>(kOutOfOrder);
            }
        }
        if (event.kind == AnchorEventKind::kSessionEnd) {
            saw_end = true;
            if (i + 1 != events.size()) {
                result.violation_mask |= static_cast<uint32_t>(kOutOfOrder);
            }
        }
        last_ms = event.timestamp_ms;
    }

    if (!saw_start) {
        result.violation_mask |= static_cast<uint32_t>(kMissingSessionStart);
    }
    if (!saw_end) {
        result.violation_mask |= static_cast<uint32_t>(kMissingSessionEnd);
    }

    result.max_gap_ms = max_gap_ms;
    result.pass = (result.violation_mask == 0);
    return result;
}

}  // namespace time
}  // namespace aether

#endif  // AETHER_TIME_ANCHOR_POLICY_H
