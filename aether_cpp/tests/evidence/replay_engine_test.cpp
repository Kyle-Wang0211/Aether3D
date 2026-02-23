// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/replay_engine.h"
#include "aether/core/status.h"

#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

namespace {

std::vector<aether::evidence::ObservationLogEntry> make_log_entries() {
    using namespace aether::evidence;
    std::vector<ObservationLogEntry> entries;
    entries.reserve(8);
    for (int i = 0; i < 8; ++i) {
        ObservationLogEntry entry{};
        entry.observation.patch_id = (i % 2 == 0) ? "patch_a" : "patch_b";
        entry.observation.frame_id = "frame_" + std::to_string(i);
        entry.observation.timestamp_s = 1.0 + static_cast<double>(i) * 0.05;
        entry.observation.view_angle_deg = static_cast<double>((i * 15) % 360);
        entry.gate_quality = 0.35 + 0.05 * static_cast<double>(i % 3);
        entry.soft_quality = 0.30 + 0.04 * static_cast<double>(i % 4);
        entry.verdict = (i % 5 == 4) ? ObservationVerdict::kBad : ObservationVerdict::kGood;
        entry.timestamp_ms = 1000 + i * 50;
        entries.push_back(entry);
    }
    return entries;
}

}  // namespace

int main() {
    int failed = 0;
    using namespace aether::evidence;

    // Deterministic replay: same input -> same hash + no snapshot diff.
    {
        const std::vector<ObservationLogEntry> log = make_log_entries();
        EvidenceReplayEngine engine_a;
        EvidenceReplayEngine engine_b;
        if (engine_a.replay(log) != aether::core::Status::kOk ||
            engine_b.replay(log) != aether::core::Status::kOk) {
            std::fprintf(stderr, "replay failed\n");
            failed++;
        } else {
            std::string hash_a, hash_b;
            engine_a.export_state_sha256_hex(hash_a);
            engine_b.export_state_sha256_hex(hash_b);
            if (hash_a != hash_b) {
                std::fprintf(stderr, "replay hash mismatch\n");
                failed++;
            }
            const auto diffs = EvidenceReplayEngine::compare_snapshots(engine_a.state(), engine_b.state());
            if (!diffs.empty()) {
                std::fprintf(stderr, "snapshot diffs unexpectedly non-empty\n");
                failed++;
            }
        }
    }

    // Cross-language golden check: load Swift golden state, empty replay, export JSON must match bytes.
    {
        EvidenceState initial{};
        initial.gate_display = 0.5;
        initial.soft_display = 0.45;
        initial.last_total_display = 0.475;
        initial.schema_version = "3.0";
        initial.exported_at_ms = 1234567890;

        PatchEntrySnapshot p0{};
        p0.evidence = 0.3;
        p0.last_update_ms = 1000;
        p0.observation_count = 5;
        p0.best_frame_id = "frame_2";
        p0.error_count = 0;
        p0.error_streak = 0;
        p0.has_last_good_update_ms = true;
        p0.last_good_update_ms = 1000;
        initial.patches["patch_0"] = p0;

        PatchEntrySnapshot p1{};
        p1.evidence = 0.6;
        p1.last_update_ms = 2000;
        p1.observation_count = 10;
        p1.best_frame_id = "frame_5";
        p1.error_count = 1;
        p1.error_streak = 0;
        p1.has_last_good_update_ms = true;
        p1.last_good_update_ms = 2000;
        initial.patches["patch_1"] = p1;

        PatchEntrySnapshot p2{};
        p2.evidence = 0.9;
        p2.last_update_ms = 3000;
        p2.observation_count = 20;
        p2.best_frame_id = "frame_10";
        p2.error_count = 0;
        p2.error_streak = 0;
        p2.has_last_good_update_ms = true;
        p2.last_good_update_ms = 3000;
        initial.patches["patch_2"] = p2;

        EvidenceReplayEngine engine;
        if (engine.load_state(initial) != aether::core::Status::kOk) {
            std::fprintf(stderr, "load_state failed\n");
            failed++;
        } else if (engine.replay({}) != aether::core::Status::kOk) {
            std::fprintf(stderr, "empty replay failed\n");
            failed++;
        } else {
            std::string json;
            if (engine.export_state_json(json) != aether::core::Status::kOk) {
                std::fprintf(stderr, "export_state_json failed\n");
                failed++;
            } else {
                const std::string path = std::string(AETHER_REPO_ROOT) +
                    "/Tests/Evidence/Fixtures/Golden/evidence_state_v2.1.json";
                std::ifstream in(path);
                std::string golden((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
                if (!in.good() && !in.eof()) {
                    std::fprintf(stderr, "failed to read golden file: %s\n", path.c_str());
                    failed++;
                } else if (json != golden) {
                    std::fprintf(stderr, "golden byte parity mismatch\n");
                    failed++;
                }
            }
        }
    }

    // Non-monotonic timestamp must fail closed.
    {
        EvidenceReplayEngine engine;
        ObservationLogEntry first{};
        first.observation.patch_id = "p";
        first.observation.frame_id = "f1";
        first.observation.view_angle_deg = 0.0;
        first.gate_quality = 0.5;
        first.soft_quality = 0.5;
        first.verdict = ObservationVerdict::kGood;
        first.timestamp_ms = 1000;

        ObservationLogEntry second = first;
        second.observation.frame_id = "f2";
        second.timestamp_ms = 999;

        if (engine.process_observation(first) != aether::core::Status::kOk) {
            std::fprintf(stderr, "first monotonic observation failed\n");
            failed++;
        }
        if (engine.process_observation(second) == aether::core::Status::kOk) {
            std::fprintf(stderr, "non-monotonic timestamp should fail\n");
            failed++;
        }
    }

    // best_frame_id should update only when evidence target improves.
    {
        EvidenceReplayEngine engine;

        ObservationLogEntry low{};
        low.observation.patch_id = "best_patch";
        low.observation.frame_id = "frame_low";
        low.observation.view_angle_deg = 10.0;
        low.gate_quality = 0.2;
        low.soft_quality = 0.2;
        low.verdict = ObservationVerdict::kGood;
        low.timestamp_ms = 1000;
        if (engine.process_observation(low) != aether::core::Status::kOk) {
            std::fprintf(stderr, "best_frame low observation failed\n");
            failed++;
        }

        ObservationLogEntry high = low;
        high.observation.frame_id = "frame_high";
        high.gate_quality = 0.95;
        high.soft_quality = 0.95;
        high.timestamp_ms = 1050;
        if (engine.process_observation(high) != aether::core::Status::kOk) {
            std::fprintf(stderr, "best_frame high observation failed\n");
            failed++;
        }

        ObservationLogEntry degraded = high;
        degraded.observation.frame_id = "frame_degraded";
        degraded.verdict = ObservationVerdict::kBad;
        degraded.gate_quality = 0.1;
        degraded.soft_quality = 0.1;
        degraded.timestamp_ms = 1100;
        if (engine.process_observation(degraded) != aether::core::Status::kOk) {
            std::fprintf(stderr, "best_frame degraded observation failed\n");
            failed++;
        }

        const auto it = engine.state().patches.find("best_patch");
        if (it == engine.state().patches.end()) {
            std::fprintf(stderr, "best_frame patch missing\n");
            failed++;
        } else if (it->second.best_frame_id != "frame_high") {
            std::fprintf(stderr, "best_frame_id should remain on highest evidence frame\n");
            failed++;
        }
    }

    return failed;
}
