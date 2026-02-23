// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/replay_engine.h"

#include "aether/evidence/deterministic_json.h"
#include "aether/evidence/evidence_constants.h"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace aether {
namespace evidence {
namespace {

CanonicalJsonValue patch_to_canonical(const PatchEntrySnapshot& patch) {
    return CanonicalJsonValue::make_object({
        {"evidence", CanonicalJsonValue::make_number_quantized(patch.evidence, 4)},
        {"lastUpdateMs", CanonicalJsonValue::make_int(patch.last_update_ms)},
        {"observationCount", CanonicalJsonValue::make_int(patch.observation_count)},
        {"bestFrameId", patch.best_frame_id.empty()
            ? CanonicalJsonValue::make_null()
            : CanonicalJsonValue::make_string(patch.best_frame_id)},
        {"errorCount", CanonicalJsonValue::make_int(patch.error_count)},
        {"errorStreak", CanonicalJsonValue::make_int(patch.error_streak)},
        {"lastGoodUpdateMs", patch.has_last_good_update_ms
            ? CanonicalJsonValue::make_int(patch.last_good_update_ms)
            : CanonicalJsonValue::make_null()},
    }, true);
}

CanonicalJsonValue state_to_canonical(const EvidenceState& state) {
    std::vector<std::pair<std::string, CanonicalJsonValue>> patch_pairs;
    patch_pairs.reserve(state.patches.size());
    for (const auto& kv : state.patches) {
        patch_pairs.push_back({kv.first, patch_to_canonical(kv.second)});
    }

    return CanonicalJsonValue::make_object({
        {"patches", CanonicalJsonValue::make_object(std::move(patch_pairs), true)},
        {"gateDisplay", CanonicalJsonValue::make_number_quantized(state.gate_display, 4)},
        {"softDisplay", CanonicalJsonValue::make_number_quantized(state.soft_display, 4)},
        {"lastTotalDisplay", CanonicalJsonValue::make_number_quantized(state.last_total_display, 4)},
        {"schemaVersion", CanonicalJsonValue::make_string(state.schema_version)},
        {"exportedAtMs", CanonicalJsonValue::make_int(state.exported_at_ms)},
    }, true);
}

}  // namespace

void EvidenceReplayEngine::reset() {
    admission_.reset();
    state_ = EvidenceState{};
    patch_mass_.clear();
    patch_best_frame_evidence_.clear();
    last_timestamp_ms_ = 0;
}

core::Status EvidenceReplayEngine::load_state(const EvidenceState& initial_state) {
    reset();
    state_ = initial_state;
    last_timestamp_ms_ = initial_state.exported_at_ms;
    for (const auto& kv : state_.patches) {
        const double occupied = clamp01(kv.second.evidence);
        patch_mass_[kv.first] = DSMassFunction(occupied, 0.0, 1.0 - occupied);
        patch_best_frame_evidence_[kv.first] = occupied;
    }
    return core::Status::kOk;
}

core::Status EvidenceReplayEngine::process_observation(const ObservationLogEntry& entry) {
    if (entry.observation.patch_id.empty()) return core::Status::kInvalidArgument;
    if (!std::isfinite(entry.gate_quality) || !std::isfinite(entry.soft_quality)) {
        return core::Status::kInvalidArgument;
    }
    if (entry.timestamp_ms < last_timestamp_ms_) return core::Status::kOutOfRange;
    last_timestamp_ms_ = entry.timestamp_ms;

    const double gate_quality = clamp01(entry.gate_quality);
    const double soft_quality = clamp01(entry.soft_quality);
    const EvidenceAdmissionDecision admission = admission_.check_admission(
        entry.observation.patch_id,
        entry.observation.view_angle_deg,
        entry.timestamp_ms);

    const double alpha = PATCH_DISPLAY_ALPHA;
    const double smoothed_gate = alpha * gate_quality + (1.0 - alpha) * state_.gate_display;
    const double smoothed_soft = alpha * soft_quality + (1.0 - alpha) * state_.soft_display;
    state_.gate_display = std::max(state_.gate_display, smoothed_gate);
    state_.soft_display = std::max(state_.soft_display, smoothed_soft);
    state_.last_total_display = 0.5 * (state_.gate_display + state_.soft_display);
    state_.exported_at_ms = entry.timestamp_ms;

    if (!admission.allowed) {
        return core::Status::kOk;
    }

    DSMassFunction current_mass = DSMassFunction::vacuous();
    const auto mass_it = patch_mass_.find(entry.observation.patch_id);
    if (mass_it != patch_mass_.end()) current_mass = mass_it->second;

    const double delta_multiplier = verdict_delta_multiplier(entry.verdict);
    const DSMassFunction observed_mass = DSMassFusion::from_delta_multiplier(delta_multiplier);
    const double reliability = clamp01(admission.quality_scale * (0.5 + 0.5 * gate_quality));
    const DSMassFunction discounted = DSMassFusion::discount(observed_mass, reliability);
    const DSMassFunction fused = DSMassFusion::combine(current_mass, discounted);
    patch_mass_[entry.observation.patch_id] = fused;

    PatchEntrySnapshot& patch = state_.patches[entry.observation.patch_id];
    double target_evidence = fused.occupied;
    if (entry.verdict == ObservationVerdict::kBad) {
        target_evidence = std::max(0.0, target_evidence - 0.05 * admission.quality_scale);
    }
    const double blended = patch.evidence + (target_evidence - patch.evidence) * alpha;
    patch.evidence = clamp01(blended);
    patch.last_update_ms = entry.timestamp_ms;
    patch.observation_count += 1;
    double& best_frame_evidence = patch_best_frame_evidence_[entry.observation.patch_id];
    if (patch.best_frame_id.empty() || target_evidence > best_frame_evidence + 1e-9) {
        patch.best_frame_id = entry.observation.frame_id;
        best_frame_evidence = target_evidence;
    }

    if (entry.verdict == ObservationVerdict::kBad) {
        patch.error_count += 1;
        patch.error_streak += 1;
    } else if (entry.verdict == ObservationVerdict::kGood) {
        patch.error_streak = 0;
        patch.has_last_good_update_ms = true;
        patch.last_good_update_ms = entry.timestamp_ms;
    } else {
        patch.error_streak = std::max(0, patch.error_streak - 1);
    }

    return core::Status::kOk;
}

core::Status EvidenceReplayEngine::replay(const std::vector<ObservationLogEntry>& log_entries) {
    for (const ObservationLogEntry& entry : log_entries) {
        const core::Status status = process_observation(entry);
        if (status != core::Status::kOk) return status;
    }
    return core::Status::kOk;
}

core::Status EvidenceReplayEngine::export_state_json(std::string& out_json) const {
    return encode_canonical_json(state_to_canonical(state_), out_json);
}

core::Status EvidenceReplayEngine::export_state_sha256_hex(std::string& out_hex) const {
    return canonical_json_sha256_hex(state_to_canonical(state_), out_hex);
}

std::vector<std::string> EvidenceReplayEngine::compare_snapshots(const EvidenceState& expected, const EvidenceState& actual) {
    std::vector<std::string> diffs;
    auto near = [](double lhs, double rhs) { return std::fabs(lhs - rhs) <= 1e-6; };

    if (!near(expected.gate_display, actual.gate_display)) {
        diffs.push_back("gateDisplay mismatch");
    }
    if (!near(expected.soft_display, actual.soft_display)) {
        diffs.push_back("softDisplay mismatch");
    }
    if (!near(expected.last_total_display, actual.last_total_display)) {
        diffs.push_back("lastTotalDisplay mismatch");
    }
    if (expected.patches.size() != actual.patches.size()) {
        diffs.push_back("patch count mismatch");
    }

    for (const auto& kv : expected.patches) {
        const auto it = actual.patches.find(kv.first);
        if (it == actual.patches.end()) {
            diffs.push_back("missing patch: " + kv.first);
            continue;
        }
        if (!near(kv.second.evidence, it->second.evidence)) {
            diffs.push_back("patch evidence mismatch: " + kv.first);
        }
    }
    return diffs;
}

double EvidenceReplayEngine::verdict_delta_multiplier(ObservationVerdict verdict) {
    switch (verdict) {
    case ObservationVerdict::kGood:
        return 1.0;
    case ObservationVerdict::kSuspect:
        return 0.3;
    case ObservationVerdict::kBad:
        return 0.0;
    case ObservationVerdict::kUnknown:
        return 0.3;
    }
    return 0.3;
}

double EvidenceReplayEngine::clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

}  // namespace evidence
}  // namespace aether
