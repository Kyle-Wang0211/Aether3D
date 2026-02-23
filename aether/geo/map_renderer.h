// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_GEO_MAP_RENDERER_H
#define AETHER_GEO_MAP_RENDERER_H

#include "aether/core/status.h"
#include "aether/geo/sol_illumination.h"
#include "aether/geo/geo_constants.h"

#include <cstdint>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Quality Presets (3-tier system)
// ---------------------------------------------------------------------------
enum class QualityPreset : std::int32_t {
    kSaver = 0,
    kBalanced = 1,
    kCinematic = 2,
};

// ---------------------------------------------------------------------------
// Phase 7 Feature Flags
// ---------------------------------------------------------------------------
enum class Phase7Feature : std::uint32_t {
    kPulseField4D         = 1u << 0,
    kTimeLens             = 1u << 1,
    kEvidenceXRay         = 1u << 2,
    kSolarStory           = 1u << 3,
    kCausalReplay         = 1u << 4,
    kQualityToggle        = 1u << 5,
    kTrustWeightedTimeLens = 1u << 6,
    kUncertaintyVeil      = 1u << 7,
    kDualEpochSplit       = 1u << 8,
    kDeterministicCinematic = 1u << 9,
    kPrivacyHeat          = 1u << 10,
};

// ---------------------------------------------------------------------------
// Render frame input
// ---------------------------------------------------------------------------
struct MapRenderInput {
    double camera_lat{0};
    double camera_lon{0};
    double camera_altitude_m{100};
    float camera_fov_deg{60.0f};
    float viewport_width{1920};
    float viewport_height{1080};
    double timestamp_utc{0};
    QualityPreset quality{QualityPreset::kBalanced};
    std::uint32_t active_phase7_features{0};

    // Thermal/memory signals for budget scheduling
    std::int32_t thermal_level{0};
    float frame_budget_ms{16.0f};
};

// ---------------------------------------------------------------------------
// GPU budget allocation
// ---------------------------------------------------------------------------
struct GpuBudget {
    float terrain_ms{0};
    float tiles_ms{0};
    float labels_ms{0};
    float effects_ms{0};
    float reserve_ms{0};
    float total_ms{16.0f};
};

// ---------------------------------------------------------------------------
// Render frame output / statistics
// ---------------------------------------------------------------------------
struct MapRenderStats {
    std::uint32_t tiles_rendered{0};
    std::uint32_t tiles_culled{0};
    std::uint32_t labels_visible{0};
    std::uint32_t labels_culled{0};
    float frame_time_ms{0};
    GpuBudget budget_used{};
    SolarEnvironmentLight solar_light{};
};

// ---------------------------------------------------------------------------
// Phase 7 feature state
// ---------------------------------------------------------------------------
struct Phase7State {
    // Pulse Field 4D
    float pulse_energy_total{0};
    std::uint32_t active_voxels{0};

    // Time Lens
    bool time_lens_active{false};
    float time_lens_x{0};
    float time_lens_y{0};
    float time_lens_radius{TIMELENS_RADIUS_PX};

    // Evidence X-Ray
    bool xray_active{false};
    std::uint64_t xray_target_id{0};

    // Causal Replay
    bool replay_active{false};
    std::uint32_t replay_epoch{0};

    // Dual-Epoch Split
    bool dual_epoch_active{false};
    float split_position{0.5f};

    // Deterministic Cinematic
    bool deterministic_mode{false};
    std::uint32_t frame_index{0};

    // Feature concurrency mutex (bitmask of active features)
    std::uint32_t active_mask{0};
};

// ---------------------------------------------------------------------------
// Map Renderer handle
// ---------------------------------------------------------------------------
struct MapRenderer;

/// Create / destroy.
MapRenderer* map_renderer_create();
void map_renderer_destroy(MapRenderer* renderer);

/// Render one frame through the 8-step pipeline.
core::Status map_renderer_frame(MapRenderer* renderer,
                                const MapRenderInput& input,
                                MapRenderStats* out_stats);

/// Get the current Phase 7 state (read-only).
const Phase7State* map_renderer_phase7_state(const MapRenderer* renderer);

/// Set quality preset.
void map_renderer_set_quality(MapRenderer* renderer, QualityPreset preset);

/// Get current quality preset.
QualityPreset map_renderer_get_quality(const MapRenderer* renderer);

/// Enable/disable a Phase 7 feature.  Returns false if blocked by concurrency matrix.
bool map_renderer_enable_feature(MapRenderer* renderer, Phase7Feature feature);
bool map_renderer_disable_feature(MapRenderer* renderer, Phase7Feature feature);

/// Compute GPU budget allocation for the current frame.
GpuBudget map_renderer_compute_budget(const MapRenderer* renderer,
                                       const MapRenderInput& input);

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_MAP_RENDERER_H
