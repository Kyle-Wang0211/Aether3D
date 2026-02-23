// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/volume_controller.h"

#include "aether/core/numeric_guard.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace tsdf {
namespace {

int clamp_int(int v, int lo, int hi) {
    return std::max(lo, std::min(hi, v));
}

float clamp_float(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

int thermal_to_ceiling(int level) {
    static constexpr int kMap[10] = {1, 1, 2, 2, 3, 4, 6, 8, 10, 12};
    const int idx = clamp_int(level, 0, 9);
    return kMap[idx];
}

int memory_to_floor(int level) {
    static constexpr int kMap[5] = {1, 2, 3, 4, 12};
    const int idx = clamp_int(level, 0, 4);
    return kMap[idx];
}

int evict_budget(int level) {
    static constexpr int kMap[5] = {0, 0, 64, 256, 512};
    const int idx = clamp_int(level, 0, 4);
    return kMap[idx];
}

int preallocate_budget(float angular_velocity) {
    const float w = std::fabs(angular_velocity);
    if (w >= 1.5f) {
        return 12;
    }
    if (w >= 0.9f) {
        return 8;
    }
    if (w >= 0.4f) {
        return 4;
    }
    return 0;
}

int effective_thermal_level(const PlatformSignals& signals) {
    const int canonical = static_cast<int>(signals.thermal.level);
    return clamp_int(std::max(canonical, signals.thermal_level), 0, 9);
}

float effective_thermal_headroom(const PlatformSignals& signals) {
    float h = signals.thermal.headroom;
    if (!std::isfinite(h) || h <= 0.0f) {
        h = signals.thermal_headroom;
    }
    return clamp_float(h, 0.0f, 1.0f);
}

int effective_memory_water_level(const PlatformSignals& signals) {
    const int canonical = static_cast<int>(signals.memory);
    return clamp_int(std::max(canonical, signals.memory_water_level), 0, 4);
}

double stable_dt_seconds(const PlatformSignals& signals, const VolumeControllerState& state) {
    double dt_s = 0.0;
    if (std::isfinite(signals.timestamp_s) && std::isfinite(state.last_update_s) &&
        state.last_update_s > 0.0 && signals.timestamp_s > state.last_update_s) {
        dt_s = signals.timestamp_s - state.last_update_s;
    }
    if (!std::isfinite(dt_s) || dt_s <= 0.0 || dt_s > 1.0) {
        const float frame_ms = std::max(0.0f, signals.frame_actual_duration_ms);
        dt_s = std::max(1.0 / 240.0, static_cast<double>(frame_ms) * 1e-3);
    }
    return std::min(dt_s, 0.5);
}

}  // namespace

core::Status volume_controller_decide(
    const PlatformSignals& signals,
    VolumeControllerState* state,
    ControllerDecision* out_decision) {
    if (state == nullptr || out_decision == nullptr) {
        return core::Status::kInvalidArgument;
    }
    *out_decision = ControllerDecision{};

    if (!std::isfinite(signals.thermal_headroom) ||
        !std::isfinite(signals.thermal.headroom) ||
        !std::isfinite(signals.thermal.slope) ||
        !std::isfinite(signals.thermal.confidence) ||
        !std::isfinite(signals.angular_velocity) ||
        !std::isfinite(signals.frame_actual_duration_ms) ||
        !std::isfinite(signals.timestamp_s)) {
        return core::Status::kInvalidArgument;
    }

    const int thermal_level = effective_thermal_level(signals);
    const float thermal_headroom = effective_thermal_headroom(signals);
    const int memory_level = effective_memory_water_level(signals);

    state->frame_counter += 1u;
    state->system_thermal_ceiling = thermal_to_ceiling(thermal_level);
    state->memory_skip_floor = memory_to_floor(memory_level);

    // AIMD based on measured frame cost.
    // Recovery hysteresis: 5s sustained good frames.
    // Degrade hysteresis: 10s sustained bad frames.
    const float frame_ms = std::max(0.0f, signals.frame_actual_duration_ms);
    const double dt_s = stable_dt_seconds(signals, *state);
    if (frame_ms <= 5.0f) {
        state->consecutive_good_frames += 1;
        state->consecutive_bad_frames = 0;
        state->consecutive_good_time_s += dt_s;
        state->consecutive_bad_time_s = 0.0;
        while (state->consecutive_good_time_s >= 5.0 && state->integration_skip_rate > 1) {
            state->integration_skip_rate -= 1;
            state->consecutive_good_time_s -= 5.0;
        }
    } else {
        state->consecutive_bad_frames += 1;
        state->consecutive_good_frames = 0;
        state->consecutive_bad_time_s += dt_s;
        state->consecutive_good_time_s = 0.0;
        while (state->consecutive_bad_time_s >= 10.0) {
            state->integration_skip_rate = std::min(12, state->integration_skip_rate * 2);
            state->consecutive_bad_time_s -= 10.0;
            if (state->integration_skip_rate >= 12) {
                break;
            }
        }
    }

    const int floor_skip = std::max(state->system_thermal_ceiling, state->memory_skip_floor);
    state->integration_skip_rate = clamp_int(state->integration_skip_rate, floor_skip, 12);

    const float valid_ratio = (signals.total_pixel_count > 0)
        ? static_cast<float>(signals.valid_pixel_count) / static_cast<float>(signals.total_pixel_count)
        : 0.0f;

    bool hard_skip = false;
    if (signals.tracking != TrackingState::kNormal) {
        hard_skip = true;
    }
    if (valid_ratio < 0.01f) {
        hard_skip = true;
    }
    if (state->frame_counter % static_cast<std::uint64_t>(state->integration_skip_rate) != 0u) {
        hard_skip = true;
    }

    out_decision->should_skip_frame = hard_skip;
    out_decision->integration_skip_rate = state->integration_skip_rate;
    out_decision->should_evict = memory_level >= 2;
    out_decision->blocks_to_evict = evict_budget(memory_level);
    out_decision->blocks_to_preallocate = preallocate_budget(signals.angular_velocity);
    out_decision->is_keyframe = (!hard_skip) &&
        (valid_ratio >= 0.20f || std::fabs(signals.angular_velocity) >= 0.12f);

    const float thermal_confidence = clamp_float(signals.thermal.confidence, 0.2f, 1.0f);
    const float quality = valid_ratio * (0.5f + 0.5f * thermal_headroom) * thermal_confidence;
    out_decision->quality_weight = clamp_float(quality, 0.05f, 1.0f);

    // C01 NumericGuard: guard quality_weight at API boundary
    core::guard_finite_scalar(&out_decision->quality_weight);

    state->last_update_s = signals.timestamp_s;
    return core::Status::kOk;
}

}  // namespace tsdf
}  // namespace aether
