// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_REPLAY_ENGINE_H
#define AETHER_EVIDENCE_REPLAY_ENGINE_H

#include "aether/core/status.h"
#include "aether/evidence/admission_controller.h"
#include "aether/evidence/ds_mass_function.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace aether {
namespace evidence {

enum class ObservationVerdict : uint8_t {
    kGood = 0,
    kSuspect = 1,
    kBad = 2,
    kUnknown = 3,
};

struct EvidenceObservation {
    std::string patch_id;
    double timestamp_s{0.0};
    std::string frame_id;
    double view_angle_deg{0.0};
};

struct ObservationLogEntry {
    EvidenceObservation observation{};
    double gate_quality{0.0};
    double soft_quality{0.0};
    ObservationVerdict verdict{ObservationVerdict::kUnknown};
    int64_t timestamp_ms{0};
};

struct PatchEntrySnapshot {
    double evidence{0.0};
    int64_t last_update_ms{0};
    int observation_count{0};
    std::string best_frame_id;
    int error_count{0};
    int error_streak{0};
    bool has_last_good_update_ms{false};
    int64_t last_good_update_ms{0};
};

struct EvidenceState {
    std::map<std::string, PatchEntrySnapshot> patches{};
    double gate_display{0.0};
    double soft_display{0.0};
    double last_total_display{0.0};
    std::string schema_version{"3.0"};
    int64_t exported_at_ms{0};
};

class EvidenceReplayEngine {
public:
    EvidenceReplayEngine() = default;

    void reset();
    core::Status load_state(const EvidenceState& initial_state);
    core::Status process_observation(const ObservationLogEntry& entry);
    core::Status replay(const std::vector<ObservationLogEntry>& log_entries);

    core::Status export_state_json(std::string& out_json) const;
    core::Status export_state_sha256_hex(std::string& out_hex) const;
    const EvidenceState& state() const { return state_; }

    static std::vector<std::string> compare_snapshots(const EvidenceState& expected, const EvidenceState& actual);

private:
    static double verdict_delta_multiplier(ObservationVerdict verdict);
    static double clamp01(double value);

    AdmissionController admission_{};
    EvidenceState state_{};
    std::map<std::string, DSMassFunction> patch_mass_{};
    std::map<std::string, double> patch_best_frame_evidence_{};
    int64_t last_timestamp_ms_{0};
};

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_REPLAY_ENGINE_H
