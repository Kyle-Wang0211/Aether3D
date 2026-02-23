// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_ADMISSION_CONTROLLER_H
#define AETHER_EVIDENCE_ADMISSION_CONTROLLER_H

#include "aether/core/status.h"
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace aether {
namespace evidence {

enum class EvidenceAdmissionReason : uint8_t {
    kAllowed = 0,
    kTimeDensitySamePatch = 1,
    kTokenBucketLow = 2,
    kNoveltyLow = 3,
    kFrequencyCap = 4,
    kConfirmedSpam = 5,
};

struct EvidenceAdmissionDecision {
    bool allowed{false};
    double quality_scale{0.0};
    uint32_t reason_mask{0};

    bool has_reason(EvidenceAdmissionReason reason) const;
    bool is_hard_blocked() const;
};

class TokenBucketLimiter {
public:
    core::Status try_consume(const std::string& patch_id, int64_t timestamp_ms, bool& consumed);
    core::Status available_tokens(const std::string& patch_id, int64_t timestamp_ms, double& tokens);
    void reset();

private:
    struct BucketState {
        double tokens{0.0};
        int64_t last_refill_ms{0};
    };

    void refill(const std::string& patch_id, int64_t timestamp_ms);

    std::map<std::string, BucketState> buckets_;
};

class SpamProtection {
public:
    bool should_allow_update(const std::string& patch_id, int64_t timestamp_ms) const;
    double novelty_scale(double raw_novelty) const;
    double frequency_scale(const std::string& patch_id, int64_t timestamp_ms);
    void reset();

private:
    struct SpamState {
        int64_t last_update_ms{0};
        int recent_update_count{0};
        int64_t last_reset_ms{0};
    };

    void record_update(const std::string& patch_id, int64_t timestamp_ms);

    std::map<std::string, SpamState> patch_states_;
};

class ViewDiversityTracker {
public:
    double add_observation(const std::string& patch_id, double view_angle_deg, int64_t timestamp_ms);
    double diversity_score(const std::string& patch_id) const;
    void reset();

private:
    struct AngleBucket {
        int bucket_index{0};
        int observation_count{0};
        int64_t last_update_ms{0};
    };

    std::map<std::string, std::vector<AngleBucket>> patch_buckets_;
};

class AdmissionController {
public:
    EvidenceAdmissionDecision check_admission(
        const std::string& patch_id,
        double view_angle_deg,
        int64_t timestamp_ms);
    EvidenceAdmissionDecision check_confirmed_spam(
        const std::string& patch_id,
        double spam_score,
        double threshold = 0.95) const;
    void reset();

    const SpamProtection& spam_protection() const { return spam_protection_; }
    const TokenBucketLimiter& token_bucket() const { return token_bucket_; }
    const ViewDiversityTracker& view_diversity() const { return view_diversity_; }

private:
    static void add_reason(EvidenceAdmissionDecision& decision, EvidenceAdmissionReason reason);

    SpamProtection spam_protection_{};
    TokenBucketLimiter token_bucket_{};
    ViewDiversityTracker view_diversity_{};
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_ADMISSION_CONTROLLER_H
