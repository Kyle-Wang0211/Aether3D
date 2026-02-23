// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/map_renderer.h"
#include "aether/geo/geo_constants.h"
#include "aether/geo/sol_illumination.h"
#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Feature concurrency matrix: some Phase 7 features are mutually exclusive.
// Matrix[i][j] = true means features i and j can coexist.
// ---------------------------------------------------------------------------
namespace {

// Features that conflict with each other:
// - TimeLens and DualEpochSplit (both claim the viewport)
// - CausalReplay and DeterministicCinematic (both control timeline)
// - PulseField4D and UncertaintyVeil (visual conflict)
bool features_compatible(Phase7Feature a, Phase7Feature b) {
    auto ai = static_cast<std::uint32_t>(a);
    auto bi = static_cast<std::uint32_t>(b);
    if (ai == bi) return true;

    // Incompatible pairs
    if ((ai == static_cast<std::uint32_t>(Phase7Feature::kTimeLens) &&
         bi == static_cast<std::uint32_t>(Phase7Feature::kDualEpochSplit)) ||
        (bi == static_cast<std::uint32_t>(Phase7Feature::kTimeLens) &&
         ai == static_cast<std::uint32_t>(Phase7Feature::kDualEpochSplit)))
        return false;

    if ((ai == static_cast<std::uint32_t>(Phase7Feature::kCausalReplay) &&
         bi == static_cast<std::uint32_t>(Phase7Feature::kDeterministicCinematic)) ||
        (bi == static_cast<std::uint32_t>(Phase7Feature::kCausalReplay) &&
         ai == static_cast<std::uint32_t>(Phase7Feature::kDeterministicCinematic)))
        return false;

    if ((ai == static_cast<std::uint32_t>(Phase7Feature::kPulseField4D) &&
         bi == static_cast<std::uint32_t>(Phase7Feature::kUncertaintyVeil)) ||
        (bi == static_cast<std::uint32_t>(Phase7Feature::kPulseField4D) &&
         ai == static_cast<std::uint32_t>(Phase7Feature::kUncertaintyVeil)))
        return false;

    return true;
}

// Thermal degradation: reduce budget at high thermal levels
float thermal_factor(std::int32_t thermal_level) {
    if (thermal_level <= 3) return 1.0f;
    if (thermal_level <= 5) return 0.7f;
    if (thermal_level <= 7) return 0.4f;
    return 0.2f;
}

}  // anonymous namespace

// ---------------------------------------------------------------------------
// MapRenderer implementation
// ---------------------------------------------------------------------------
struct MapRenderer {
    QualityPreset quality{QualityPreset::kBalanced};
    Phase7State phase7{};
    SolarEnvironmentLight last_solar{};
    double last_solar_update_s{0};
    std::uint64_t frame_counter{0};
};

MapRenderer* map_renderer_create() {
    return new MapRenderer();
}

void map_renderer_destroy(MapRenderer* renderer) {
    delete renderer;
}

// ---------------------------------------------------------------------------
// 8-step per-frame pipeline
// ---------------------------------------------------------------------------
core::Status map_renderer_frame(MapRenderer* renderer,
                                const MapRenderInput& input,
                                MapRenderStats* out_stats) {
    if (!renderer || !out_stats) return core::Status::kInvalidArgument;

    std::memset(out_stats, 0, sizeof(MapRenderStats));

    // Step 1: Bootstrap — determine view parameters
    float zoom_approx = static_cast<float>(
        std::log2(40075016.0 / (input.camera_altitude_m * 2.0)));
    if (zoom_approx < 0.0f) zoom_approx = 0.0f;
    if (zoom_approx > 20.0f) zoom_approx = 20.0f;

    // Step 2: Solar — update environment light
    double solar_dt = input.timestamp_utc - renderer->last_solar_update_s;
    if (solar_dt >= SOL_UPDATE_INTERVAL_S || renderer->frame_counter == 0) {
        SolarPosition pos{};
        solar_position(input.timestamp_utc, input.camera_lat, input.camera_lon, &pos);
        SolarEnvironmentLight new_light{};
        solar_environment_light(pos, input.camera_lat, input.camera_lon, &new_light);

        if (renderer->frame_counter > 0 && solar_dt < SOL_RESUME_SKIP_THRESHOLD_S) {
            // Smooth interpolation
            float t = static_cast<float>(solar_dt / SOL_INTERPOLATION_DURATION_S);
            core::guard_finite_scalar(&t);
            t = std::max(0.0f, std::min(1.0f, t));
            solar_interpolate(renderer->last_solar, new_light, t, &renderer->last_solar);
        } else {
            renderer->last_solar = new_light;
        }
        renderer->last_solar_update_s = input.timestamp_utc;
    }
    out_stats->solar_light = renderer->last_solar;

    // Step 3: Tiles — determine visible tiles
    std::uint32_t zoom_level = static_cast<std::uint32_t>(zoom_approx);
    std::uint32_t tiles_per_axis = 1u << zoom_level;
    // Estimate visible tile range (simplified)
    float view_span_deg = input.camera_fov_deg;
    std::uint32_t tile_count_est = static_cast<std::uint32_t>(
        (view_span_deg / 360.0f) * tiles_per_axis * (view_span_deg / 180.0f) * tiles_per_axis);
    if (tile_count_est < 1) tile_count_est = 1;
    if (tile_count_est > 256) tile_count_est = 256;

    // Step 4: Fetch — (simulated) load tiles from source
    out_stats->tiles_rendered = tile_count_est;

    // Step 5: Geometry — build mesh (simulated)

    // Step 6: Cull — frustum and horizon culling
    out_stats->tiles_culled = tile_count_est / 4;  // ~25% culled typical
    out_stats->tiles_rendered -= out_stats->tiles_culled;

    // Step 7: Render — (simulated) draw calls
    out_stats->labels_visible = tile_count_est;
    out_stats->labels_culled = tile_count_est / 3;

    // Step 8: Budget — GPU scheduling
    GpuBudget budget = map_renderer_compute_budget(renderer, input);
    out_stats->budget_used = budget;
    out_stats->frame_time_ms = budget.total_ms * 0.8f; // Simulated 80% utilization

    // Phase 7 features processing
    if (renderer->phase7.active_mask & static_cast<std::uint32_t>(Phase7Feature::kPulseField4D)) {
        // Pulse field advection (simplified)
        renderer->phase7.pulse_energy_total *= (1.0f - PULSE_FIELD_DECAY_RATE);
        core::guard_finite_scalar(&renderer->phase7.pulse_energy_total);
    }

    if (renderer->phase7.deterministic_mode) {
        renderer->phase7.frame_index++;
        if (renderer->phase7.frame_index >= DETERMINISTIC_REPLAY_WINDOW_FRAMES) {
            renderer->phase7.frame_index = 0;
        }
    }

    renderer->frame_counter++;
    return core::Status::kOk;
}

const Phase7State* map_renderer_phase7_state(const MapRenderer* renderer) {
    return renderer ? &renderer->phase7 : nullptr;
}

void map_renderer_set_quality(MapRenderer* renderer, QualityPreset preset) {
    if (renderer) renderer->quality = preset;
}

QualityPreset map_renderer_get_quality(const MapRenderer* renderer) {
    return renderer ? renderer->quality : QualityPreset::kBalanced;
}

bool map_renderer_enable_feature(MapRenderer* renderer, Phase7Feature feature) {
    if (!renderer) return false;

    std::uint32_t bit = static_cast<std::uint32_t>(feature);

    // Check concurrency matrix
    for (std::uint32_t i = 0; i < 11; ++i) {
        std::uint32_t existing_bit = 1u << i;
        if (renderer->phase7.active_mask & existing_bit) {
            if (!features_compatible(feature, static_cast<Phase7Feature>(existing_bit))) {
                return false;  // Blocked by concurrency matrix
            }
        }
    }

    renderer->phase7.active_mask |= bit;

    // Initialize feature-specific state
    if (feature == Phase7Feature::kDeterministicCinematic) {
        renderer->phase7.deterministic_mode = true;
        renderer->phase7.frame_index = 0;
    }
    if (feature == Phase7Feature::kTimeLens) {
        renderer->phase7.time_lens_active = true;
        renderer->phase7.time_lens_radius = TIMELENS_RADIUS_PX;
    }

    return true;
}

bool map_renderer_disable_feature(MapRenderer* renderer, Phase7Feature feature) {
    if (!renderer) return false;

    std::uint32_t bit = static_cast<std::uint32_t>(feature);
    renderer->phase7.active_mask &= ~bit;

    if (feature == Phase7Feature::kDeterministicCinematic) {
        renderer->phase7.deterministic_mode = false;
    }
    if (feature == Phase7Feature::kTimeLens) {
        renderer->phase7.time_lens_active = false;
    }

    return true;
}

GpuBudget map_renderer_compute_budget(const MapRenderer* /*renderer*/,
                                       const MapRenderInput& input) {
    GpuBudget budget{};
    budget.total_ms = input.frame_budget_ms;

    float tf = thermal_factor(input.thermal_level);
    float effective = budget.total_ms * tf;

    // 5-way split based on quality preset
    switch (input.quality) {
        case QualityPreset::kCinematic:
            budget.terrain_ms = effective * 0.25f;
            budget.tiles_ms   = effective * 0.30f;
            budget.labels_ms  = effective * 0.15f;
            budget.effects_ms = effective * 0.20f;
            budget.reserve_ms = effective * 0.10f;
            break;
        case QualityPreset::kBalanced:
            budget.terrain_ms = effective * 0.20f;
            budget.tiles_ms   = effective * 0.35f;
            budget.labels_ms  = effective * 0.15f;
            budget.effects_ms = effective * 0.15f;
            budget.reserve_ms = effective * 0.15f;
            break;
        case QualityPreset::kSaver:
            budget.terrain_ms = effective * 0.15f;
            budget.tiles_ms   = effective * 0.40f;
            budget.labels_ms  = effective * 0.10f;
            budget.effects_ms = effective * 0.10f;
            budget.reserve_ms = effective * 0.25f;
            break;
    }

    // NumericGuard on all budget values
    core::guard_finite_scalar(&budget.terrain_ms);
    core::guard_finite_scalar(&budget.tiles_ms);
    core::guard_finite_scalar(&budget.labels_ms);
    core::guard_finite_scalar(&budget.effects_ms);
    core::guard_finite_scalar(&budget.reserve_ms);

    return budget;
}

}  // namespace geo
}  // namespace aether
