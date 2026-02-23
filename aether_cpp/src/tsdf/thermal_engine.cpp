// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/thermal_engine.h"

#include <algorithm>
#include <cmath>
#include <cstddef>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace aether {
namespace tsdf {
namespace {

inline float clamp_float(float value, float low, float high) {
    return std::max(low, std::min(high, value));
}

inline std::int32_t clamp_int(std::int32_t value, std::int32_t low, std::int32_t high) {
    return std::max(low, std::min(high, value));
}

float probe_headroom(float probe_ms) {
    if (!std::isfinite(probe_ms) || probe_ms <= 0.0f) {
        return 1.0f;
    }
    const float normalized = clamp_float((probe_ms - 1.0f) / 5.0f, 0.0f, 1.0f);
    return 1.0f - normalized;
}

float level_to_headroom_floor(AetherThermalLevel level) {
    static constexpr float kMap[10] = {
        0.95f, 0.90f, 0.82f, 0.74f, 0.64f, 0.54f, 0.40f, 0.28f, 0.16f, 0.05f};
    return kMap[static_cast<int>(level)];
}

}  // namespace

float AetherThermalEngine::normalize_temperature(float celsius) {
    if (!std::isfinite(celsius)) {
        return 0.5f;
    }
    // 35C -> headroom 1.0, 80C -> headroom 0.0
    const float normalized = (80.0f - celsius) / 45.0f;
    return clamp_float(normalized, 0.0f, 1.0f);
}

float AetherThermalEngine::fuse_headroom(const ThermalObservation& obs) const {
    const float os = clamp_float(obs.os_headroom, 0.0f, 1.0f);
    const float batt = normalize_temperature(obs.battery_temp_c);
    const float soc = normalize_temperature(obs.soc_temp_c);
    const float skin = normalize_temperature(obs.skin_temp_c);
    const float gpu = clamp_float(1.0f - obs.gpu_busy_ratio, 0.0f, 1.0f);
    const float probe = probe_headroom(obs.cpu_probe_ms > 0.0f ? obs.cpu_probe_ms : probe_ewma_ms_);

    constexpr float w_os = 0.34f;
    constexpr float w_soc = 0.24f;
    constexpr float w_skin = 0.16f;
    constexpr float w_batt = 0.12f;
    constexpr float w_gpu = 0.08f;
    constexpr float w_probe = 0.06f;
    const float fused = os * w_os + soc * w_soc + skin * w_skin + batt * w_batt + gpu * w_gpu + probe * w_probe;
    return clamp_float(fused, 0.0f, 1.0f);
}

AetherThermalLevel AetherThermalEngine::map_level(float fused_headroom, std::int32_t os_level) {
    const std::int32_t os_clamped = clamp_int(os_level, 0, 9);
    AetherThermalLevel level = AetherThermalLevel::kDead;
    if (fused_headroom >= 0.92f) level = AetherThermalLevel::kFrost;
    else if (fused_headroom >= 0.86f) level = AetherThermalLevel::kCool;
    else if (fused_headroom >= 0.78f) level = AetherThermalLevel::kNormal;
    else if (fused_headroom >= 0.70f) level = AetherThermalLevel::kWarm;
    else if (fused_headroom >= 0.62f) level = AetherThermalLevel::kHot;
    else if (fused_headroom >= 0.52f) level = AetherThermalLevel::kVeryHot;
    else if (fused_headroom >= 0.40f) level = AetherThermalLevel::kThrottle;
    else if (fused_headroom >= 0.28f) level = AetherThermalLevel::kCritical;
    else if (fused_headroom >= 0.14f) level = AetherThermalLevel::kEmergency;
    else level = AetherThermalLevel::kDead;

    // Respect explicit OS thermal level escalation.
    const auto os_as_level = static_cast<AetherThermalLevel>(os_clamped);
    if (static_cast<int>(os_as_level) > static_cast<int>(level)) {
        level = os_as_level;
    }
    return level;
}

core::Status AetherThermalEngine::update(const ThermalObservation& obs, AetherThermalState* out_state) {
    if (out_state == nullptr || !std::isfinite(obs.timestamp_s)) {
        return core::Status::kInvalidArgument;
    }

    const float probe = obs.cpu_probe_ms > 0.0f ? obs.cpu_probe_ms : run_cpu_probe();
    if (std::isfinite(probe)) {
        if (probe_ewma_ms_ <= 0.0f) {
            probe_ewma_ms_ = probe;
        } else {
            probe_ewma_ms_ = probe_ewma_ms_ * 0.8f + probe * 0.2f;
        }
    }

    ThermalObservation compensated = obs;
    compensated.cpu_probe_ms = probe_ewma_ms_;
    const float fused_headroom = fuse_headroom(compensated);

    float slope = 0.0f;
    float slope_2nd = 0.0f;
    float dt = 0.0f;
    if (has_history_) {
        dt = static_cast<float>(std::max(1e-3, obs.timestamp_s - last_timestamp_s_));
        slope = (fused_headroom - last_headroom_) / dt;
        slope_2nd = (slope - last_slope_) / dt;
    }

    state_.level = map_level(fused_headroom, obs.os_level);
    // Avoid reporting a headroom that is lower than the mapped level floor.
    const float floor = level_to_headroom_floor(state_.level);
    state_.headroom = clamp_float(std::max(fused_headroom, floor), 0.0f, 1.0f);
    state_.slope = clamp_float(slope, -3.0f, 3.0f);
    state_.slope_2nd = clamp_float(slope_2nd, -20.0f, 20.0f);

    if (!has_history_ || state_.slope >= -1e-4f) {
        state_.time_to_next_s = 0.0f;
    } else {
        const int next_level = std::min(9, static_cast<int>(state_.level) + 1);
        const float next_floor = level_to_headroom_floor(static_cast<AetherThermalLevel>(next_level));
        const float delta = state_.headroom - next_floor;
        state_.time_to_next_s = delta > 0.0f ? delta / (-state_.slope) : 0.0f;
    }
    state_.time_to_next_s = clamp_float(state_.time_to_next_s, 0.0f, 120.0f);

    float confidence = 0.80f;
    if (has_history_ && dt >= 0.01f) {
        confidence += 0.10f;
    }
    if (std::fabs(state_.slope_2nd) > 5.0f) {
        confidence -= 0.10f;
    }
    if (!std::isfinite(obs.os_headroom) || obs.os_headroom < 0.0f || obs.os_headroom > 1.0f) {
        confidence -= 0.15f;
    }
    state_.confidence = clamp_float(confidence, 0.30f, 1.0f);

    has_history_ = true;
    last_timestamp_s_ = obs.timestamp_s;
    last_headroom_ = state_.headroom;
    last_slope_ = state_.slope;

    *out_state = state_;
    return core::Status::kOk;
}

float AetherThermalEngine::run_cpu_probe() {
    // 200-dot synthetic probe for thermal drift estimation.
    alignas(16) float a[200];
    alignas(16) float b[200];
    for (std::size_t i = 0u; i < 200u; ++i) {
        a[i] = static_cast<float>(i % 13u) * 0.01f + 0.37f;
        b[i] = static_cast<float>(i % 17u) * 0.02f + 0.19f;
    }

    float acc = 0.0f;
#if defined(__ARM_NEON)
    std::size_t i = 0u;
    float32x4_t vacc = vdupq_n_f32(0.0f);
    for (; i + 4u <= 200u; i += 4u) {
        const float32x4_t va = vld1q_f32(a + i);
        const float32x4_t vb = vld1q_f32(b + i);
        vacc = vfmaq_f32(vacc, va, vb);
    }
    alignas(16) float lane[4];
    vst1q_f32(lane, vacc);
    acc = lane[0] + lane[1] + lane[2] + lane[3];
    for (; i < 200u; ++i) {
        acc += a[i] * b[i];
    }
#else
    for (std::size_t i = 0u; i < 200u; ++i) {
        acc += a[i] * b[i];
    }
#endif

    // Convert arithmetic work signal to a bounded pseudo-ms score.
    const float normalized = std::fabs(acc) / 200.0f;
    return clamp_float(0.5f + normalized * 0.2f, 0.2f, 5.0f);
}

}  // namespace tsdf
}  // namespace aether
