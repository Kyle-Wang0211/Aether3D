// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_renderer.h"
#include "aether/geo/geo_constants.h"
#include "aether/core/status.h"

#include <cmath>
#include <cstdio>

int main() {
    int failed = 0;

    // Test 1: Create / destroy
    {
        auto* r = aether::geo::map_renderer_create();
        if (!r) { std::fprintf(stderr, "create null\n"); ++failed; }
        else { aether::geo::map_renderer_destroy(r); }
    }

    // Test 2: Basic frame render (smoke test)
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::MapRenderInput input{};
        input.camera_lat = 51.5074;
        input.camera_lon = -0.1278;
        input.camera_altitude_m = 500.0;
        input.camera_fov_deg = 60.0f;
        input.viewport_width = 1920;
        input.viewport_height = 1080;
        input.timestamp_utc = 1718884800.0;  // Summer solstice 2024
        input.quality = aether::geo::QualityPreset::kBalanced;
        input.frame_budget_ms = 16.0f;

        aether::geo::MapRenderStats stats{};
        auto s = aether::geo::map_renderer_frame(r, input, &stats);
        if (s != aether::core::Status::kOk) {
            std::fprintf(stderr, "frame render failed\n"); ++failed;
        }
        if (stats.tiles_rendered == 0) {
            std::fprintf(stderr, "zero tiles rendered\n"); ++failed;
        }
        if (stats.budget_used.total_ms <= 0.0f) {
            std::fprintf(stderr, "zero budget\n"); ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 3: Quality presets
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::map_renderer_set_quality(r, aether::geo::QualityPreset::kCinematic);
        if (aether::geo::map_renderer_get_quality(r) != aether::geo::QualityPreset::kCinematic) {
            std::fprintf(stderr, "quality preset not set\n"); ++failed;
        }
        aether::geo::map_renderer_destroy(r);
    }

    // Test 4: Budget allocation varies by quality
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::MapRenderInput input{};
        input.camera_lat = 0; input.camera_lon = 0;
        input.camera_altitude_m = 1000;
        input.frame_budget_ms = 16.0f;

        input.quality = aether::geo::QualityPreset::kCinematic;
        auto budget_c = aether::geo::map_renderer_compute_budget(r, input);

        input.quality = aether::geo::QualityPreset::kSaver;
        auto budget_s = aether::geo::map_renderer_compute_budget(r, input);

        // Cinematic should allocate more to effects
        if (budget_c.effects_ms <= budget_s.effects_ms) {
            std::fprintf(stderr, "cinematic effects <= saver effects\n"); ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 5: Thermal degradation
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::MapRenderInput input{};
        input.frame_budget_ms = 16.0f;
        input.quality = aether::geo::QualityPreset::kBalanced;

        input.thermal_level = 0;
        auto budget_cool = aether::geo::map_renderer_compute_budget(r, input);

        input.thermal_level = 8;
        auto budget_hot = aether::geo::map_renderer_compute_budget(r, input);

        // Hot should use less budget
        float cool_total = budget_cool.terrain_ms + budget_cool.tiles_ms +
                           budget_cool.labels_ms + budget_cool.effects_ms;
        float hot_total = budget_hot.terrain_ms + budget_hot.tiles_ms +
                          budget_hot.labels_ms + budget_hot.effects_ms;
        if (hot_total >= cool_total) {
            std::fprintf(stderr, "thermal degradation not working: cool=%.1f hot=%.1f\n",
                         cool_total, hot_total);
            ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 6: Phase 7 feature enable/disable
    {
        auto* r = aether::geo::map_renderer_create();

        bool ok = aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kPulseField4D);
        if (!ok) { std::fprintf(stderr, "enable PulseField4D failed\n"); ++failed; }

        ok = aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kTimeLens);
        if (!ok) { std::fprintf(stderr, "enable TimeLens failed\n"); ++failed; }

        const auto* state = aether::geo::map_renderer_phase7_state(r);
        if (!state || !state->time_lens_active) {
            std::fprintf(stderr, "TimeLens not active\n"); ++failed;
        }

        aether::geo::map_renderer_disable_feature(r, aether::geo::Phase7Feature::kTimeLens);
        if (state->time_lens_active) {
            std::fprintf(stderr, "TimeLens still active after disable\n"); ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 7: Phase 7 concurrency matrix — incompatible features
    {
        auto* r = aether::geo::map_renderer_create();

        // Enable TimeLens
        aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kTimeLens);
        // Try to enable DualEpochSplit — should be blocked
        bool ok = aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kDualEpochSplit);
        if (ok) {
            std::fprintf(stderr, "DualEpochSplit should be blocked by TimeLens\n"); ++failed;
        }

        // Disable TimeLens, then DualEpochSplit should work
        aether::geo::map_renderer_disable_feature(r, aether::geo::Phase7Feature::kTimeLens);
        ok = aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kDualEpochSplit);
        if (!ok) {
            std::fprintf(stderr, "DualEpochSplit should be allowed after TimeLens disabled\n"); ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 8: CausalReplay and DeterministicCinematic are incompatible
    {
        auto* r = aether::geo::map_renderer_create();

        aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kCausalReplay);
        bool ok = aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kDeterministicCinematic);
        if (ok) {
            std::fprintf(stderr, "DeterministicCinematic should be blocked by CausalReplay\n"); ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 9: Solar light updates during frame
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::MapRenderInput input{};
        input.camera_lat = 51.5074;
        input.camera_lon = -0.1278;
        input.camera_altitude_m = 500;
        input.timestamp_utc = 1718884800.0;  // Noon
        input.frame_budget_ms = 16.0f;

        aether::geo::MapRenderStats stats{};
        aether::geo::map_renderer_frame(r, input, &stats);

        // Solar light should be populated
        if (stats.solar_light.sun_intensity <= 0.0f) {
            std::fprintf(stderr, "noon: zero sun intensity\n"); ++failed;
        }
        if (stats.solar_light.phase != aether::geo::DayPhase::kFullDay &&
            stats.solar_light.phase != aether::geo::DayPhase::kGoldenHour) {
            std::fprintf(stderr, "noon: unexpected phase %d\n",
                         static_cast<int>(stats.solar_light.phase));
            ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 10: Multiple frames
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::MapRenderInput input{};
        input.camera_lat = 0; input.camera_lon = 0;
        input.camera_altitude_m = 10000;
        input.frame_budget_ms = 16.0f;

        aether::geo::MapRenderStats stats{};
        for (int i = 0; i < 10; ++i) {
            input.timestamp_utc = 1718884800.0 + i * 60.0;
            auto s = aether::geo::map_renderer_frame(r, input, &stats);
            if (s != aether::core::Status::kOk) {
                std::fprintf(stderr, "frame %d failed\n", i); ++failed;
                break;
            }
        }

        aether::geo::map_renderer_destroy(r);
    }

    // Test 11: Deterministic cinematic mode frame counter
    {
        auto* r = aether::geo::map_renderer_create();
        aether::geo::map_renderer_enable_feature(r, aether::geo::Phase7Feature::kDeterministicCinematic);

        aether::geo::MapRenderInput input{};
        input.camera_lat = 0; input.camera_lon = 0;
        input.camera_altitude_m = 1000;
        input.timestamp_utc = 1718884800.0;
        input.frame_budget_ms = 16.0f;

        aether::geo::MapRenderStats stats{};
        for (int i = 0; i < 5; ++i) {
            aether::geo::map_renderer_frame(r, input, &stats);
        }

        const auto* state = aether::geo::map_renderer_phase7_state(r);
        if (!state || state->frame_index != 5) {
            std::fprintf(stderr, "deterministic frame_index=%u expected 5\n",
                         state ? state->frame_index : 0);
            ++failed;
        }

        aether::geo::map_renderer_destroy(r);
    }

    return failed;
}
