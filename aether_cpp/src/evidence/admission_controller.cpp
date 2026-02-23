// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/admission_controller.h"
#include "aether/evidence/evidence_constants.h"

#include <algorithm>
#include <cstddef>
#include <cmath>

namespace aether {
namespace evidence {
namespace {

constexpr int64_t kFrequencyWindowMs = 1000;
constexpr int kMaxUpdatesPerWindow = 10;
constexpr int64_t kMinUpdateIntervalMs = 33;
constexpr uint32_t kReasonMaxShift = 31u;
constexpr uint32_t kReasonEnumMaxValue = static_cast<uint32_t>(EvidenceAdmissionReason::kConfirmedSpam);
static_assert(kReasonEnumMaxValue <= kReasonMaxShift, "EvidenceAdmissionReason exceeds 32-bit reason_mask capacity");

uint32_t reason_bit(EvidenceAdmissionReason reason) {
    const uint32_t shift = static_cast<uint32_t>(reason);
    if (shift > kReasonMaxShift) {
        return 0u;
    }
    return 1u << shift;
}

double clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

}  // namespace

bool EvidenceAdmissionDecision::has_reason(EvidenceAdmissionReason reason) const {
    return (reason_mask & reason_bit(reason)) != 0u;
}

bool EvidenceAdmissionDecision::is_hard_blocked() const {
    if (allowed) return false;
    return has_reason(EvidenceAdmissionReason::kTimeDensitySamePatch) ||
           has_reason(EvidenceAdmissionReason::kConfirmedSpam);
}

core::Status TokenBucketLimiter::try_consume(const std::string& patch_id, int64_t timestamp_ms, bool& consumed) {
    refill(patch_id, timestamp_ms);
    BucketState& state = buckets_[patch_id];
    consumed = false;
    if (state.tokens >= TOKEN_COST_PER_OBSERVATION) {
        state.tokens -= TOKEN_COST_PER_OBSERVATION;
        consumed = true;
    }
    return core::Status::kOk;
}

core::Status TokenBucketLimiter::available_tokens(const std::string& patch_id, int64_t timestamp_ms, double& tokens) {
    refill(patch_id, timestamp_ms);
    tokens = buckets_[patch_id].tokens;
    return core::Status::kOk;
}

void TokenBucketLimiter::reset() {
    buckets_.clear();
}

void TokenBucketLimiter::refill(const std::string& patch_id, int64_t timestamp_ms) {
    BucketState& state = buckets_[patch_id];
    if (state.last_refill_ms == 0) {
        state.last_refill_ms = timestamp_ms;
        return;
    }
    const int64_t dt_ms = timestamp_ms - state.last_refill_ms;
    if (dt_ms < 0) {
        state.last_refill_ms = timestamp_ms;
        return;
    }
    const double dt_s = static_cast<double>(dt_ms) / 1000.0;
    const double refill_amount = TOKEN_REFILL_RATE_PER_SEC * dt_s;
    state.tokens = std::min(TOKEN_BUCKET_MAX_TOKENS, state.tokens + refill_amount);
    state.last_refill_ms = timestamp_ms;
}

bool SpamProtection::should_allow_update(const std::string& patch_id, int64_t timestamp_ms) const {
    const auto it = patch_states_.find(patch_id);
    if (it == patch_states_.end()) return true;
    return (timestamp_ms - it->second.last_update_ms) >= kMinUpdateIntervalMs;
}

double SpamProtection::novelty_scale(double raw_novelty) const {
    const double novelty = clamp01(raw_novelty);
    if (novelty < LOW_NOVELTY_THRESHOLD) {
        return LOW_NOVELTY_PENALTY;
    }
    const double normalized = (novelty - LOW_NOVELTY_THRESHOLD) / (1.0 - LOW_NOVELTY_THRESHOLD);
    return LOW_NOVELTY_PENALTY + (1.0 - LOW_NOVELTY_PENALTY) * normalized;
}

double SpamProtection::frequency_scale(const std::string& patch_id, int64_t timestamp_ms) {
    record_update(patch_id, timestamp_ms);
    const SpamState& state = patch_states_[patch_id];
    if (state.recent_update_count <= kMaxUpdatesPerWindow) {
        return 1.0;
    }
    const int excess = state.recent_update_count - kMaxUpdatesPerWindow;
    const double penalty = std::min(1.0, static_cast<double>(excess) / static_cast<double>(kMaxUpdatesPerWindow));
    return std::max(0.0, 1.0 - penalty);
}

void SpamProtection::reset() {
    patch_states_.clear();
}

void SpamProtection::record_update(const std::string& patch_id, int64_t timestamp_ms) {
    SpamState& state = patch_states_[patch_id];
    if (state.last_update_ms == 0) {
        state.last_update_ms = timestamp_ms;
        state.last_reset_ms = timestamp_ms;
        state.recent_update_count = 1;
        return;
    }

    if ((timestamp_ms - state.last_reset_ms) >= kFrequencyWindowMs) {
        state.recent_update_count = 0;
        state.last_reset_ms = timestamp_ms;
    }
    state.recent_update_count += 1;
    state.last_update_ms = timestamp_ms;
}

double ViewDiversityTracker::add_observation(const std::string& patch_id, double view_angle_deg, int64_t timestamp_ms) {
    double angle = std::fmod(view_angle_deg, 360.0);
    if (angle < 0.0) angle += 360.0;
    const int bucket_index = static_cast<int>(angle / 15.0);

    std::vector<AngleBucket>& buckets = patch_buckets_[patch_id];
    bool found = false;
    for (AngleBucket& bucket : buckets) {
        if (bucket.bucket_index == bucket_index) {
            bucket.observation_count += 1;
            bucket.last_update_ms = timestamp_ms;
            found = true;
            break;
        }
    }
    if (!found) {
        AngleBucket bucket{};
        bucket.bucket_index = bucket_index;
        bucket.observation_count = 1;
        bucket.last_update_ms = timestamp_ms;
        buckets.push_back(bucket);
    }

    std::sort(buckets.begin(), buckets.end(),
              [](const AngleBucket& lhs, const AngleBucket& rhs) { return lhs.bucket_index < rhs.bucket_index; });
    if (buckets.size() > 16u) {
        size_t oldest_idx = 0u;
        for (size_t i = 1; i < buckets.size(); ++i) {
            if (buckets[i].last_update_ms < buckets[oldest_idx].last_update_ms) oldest_idx = i;
        }
        buckets.erase(buckets.begin() + static_cast<std::ptrdiff_t>(oldest_idx));
        std::sort(buckets.begin(), buckets.end(),
                  [](const AngleBucket& lhs, const AngleBucket& rhs) { return lhs.bucket_index < rhs.bucket_index; });
    }
    return diversity_score(patch_id);
}

double ViewDiversityTracker::diversity_score(const std::string& patch_id) const {
    const auto it = patch_buckets_.find(patch_id);
    if (it == patch_buckets_.end() || it->second.empty()) return 1.0;
    const std::vector<AngleBucket>& buckets = it->second;

    int total_observations = 0;
    for (const AngleBucket& bucket : buckets) total_observations += bucket.observation_count;
    if (total_observations <= 0) return 1.0;

    const double bucket_score = static_cast<double>(buckets.size()) / 16.0;
    double distribution_score = 0.0;
    for (const AngleBucket& bucket : buckets) {
        const double proportion = static_cast<double>(bucket.observation_count) / static_cast<double>(total_observations);
        if (proportion > 0.0) distribution_score -= proportion * std::log2(proportion);
    }
    const double max_entropy = std::log2(16.0);
    if (max_entropy > 0.0) distribution_score /= max_entropy;

    const double combined = 0.6 * bucket_score + 0.4 * distribution_score;
    return clamp01(combined);
}

void ViewDiversityTracker::reset() {
    patch_buckets_.clear();
}

EvidenceAdmissionDecision AdmissionController::check_admission(
    const std::string& patch_id,
    double view_angle_deg,
    int64_t timestamp_ms) {
    EvidenceAdmissionDecision decision{};

    if (!spam_protection_.should_allow_update(patch_id, timestamp_ms)) {
        decision.allowed = false;
        decision.quality_scale = 0.0;
        add_reason(decision, EvidenceAdmissionReason::kTimeDensitySamePatch);
        return decision;
    }

    bool has_token = false;
    token_bucket_.try_consume(patch_id, timestamp_ms, has_token);
    const double token_scale = has_token ? 1.0 : NO_TOKEN_PENALTY;

    const double novelty = view_diversity_.add_observation(patch_id, view_angle_deg, timestamp_ms);
    const double novelty_scale = spam_protection_.novelty_scale(novelty);
    const double frequency_scale = spam_protection_.frequency_scale(patch_id, timestamp_ms);

    double combined_scale = token_scale * novelty_scale * frequency_scale;
    combined_scale = std::max(MINIMUM_SOFT_SCALE, combined_scale);

    decision.allowed = true;
    decision.quality_scale = combined_scale;

    if (!has_token) add_reason(decision, EvidenceAdmissionReason::kTokenBucketLow);
    if (novelty < LOW_NOVELTY_THRESHOLD) add_reason(decision, EvidenceAdmissionReason::kNoveltyLow);
    if (frequency_scale < 1.0) add_reason(decision, EvidenceAdmissionReason::kFrequencyCap);
    if (decision.reason_mask == 0u) add_reason(decision, EvidenceAdmissionReason::kAllowed);
    return decision;
}

EvidenceAdmissionDecision AdmissionController::check_confirmed_spam(
    const std::string&,
    double spam_score,
    double threshold) const {
    EvidenceAdmissionDecision decision{};
    if (spam_score >= threshold) {
        decision.allowed = false;
        decision.quality_scale = 0.0;
        decision.reason_mask = reason_bit(EvidenceAdmissionReason::kConfirmedSpam);
        return decision;
    }
    decision.allowed = true;
    decision.quality_scale = 1.0;
    decision.reason_mask = reason_bit(EvidenceAdmissionReason::kAllowed);
    return decision;
}

void AdmissionController::reset() {
    spam_protection_.reset();
    token_bucket_.reset();
    view_diversity_.reset();
}

void AdmissionController::add_reason(EvidenceAdmissionDecision& decision, EvidenceAdmissionReason reason) {
    decision.reason_mask |= reason_bit(reason);
}

}  // namespace evidence
}  // namespace aether
