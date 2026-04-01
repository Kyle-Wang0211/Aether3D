// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/thermal/thermal_predictor.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace thermal {

ThermalPredictor::ThermalPredictor(const ThermalConfig& config) noexcept
    : config_(config) {
    current_fps_ = config_.fps_nominal;
    target_fps_ = config_.fps_nominal;
    current_training_rate_ = config_.training_rate_nominal;
    target_training_rate_ = config_.training_rate_nominal;
}

void ThermalPredictor::set_thermal_state(int level) noexcept {
    int clamped = std::max(0, std::min(3, level));
    raw_level_.store(clamped, std::memory_order_relaxed);
}

ThermalLevel ThermalPredictor::current_level() const noexcept {
    return static_cast<ThermalLevel>(
        raw_level_.load(std::memory_order_relaxed));
}

ThermalRecommendation ThermalPredictor::evaluate(double timestamp_s) noexcept {
    const float raw = static_cast<float>(
        raw_level_.load(std::memory_order_relaxed));
    const double dt = timestamp_s - last_evaluate_s_;
    last_evaluate_s_ = timestamp_s;

    // ─── EMA smoothing of thermal level ───
    ema_level_ = config_.ema_alpha * raw + (1.0f - config_.ema_alpha) * ema_level_;

    // ─── Prediction: extrapolate trend ───
    // Simple linear extrapolation from EMA derivative
    float trend = (raw - ema_level_) * config_.ema_alpha;
    float horizon_frames = config_.prediction_horizon_s / std::max(0.001f, static_cast<float>(dt));
    predicted_level_ = std::clamp(
        ema_level_ + trend * std::min(horizon_frames, 1800.0f) * 0.001f,
        0.0f, 3.0f);

    // Use max of current and predicted for safety
    float effective = std::max(raw, predicted_level_);

    // ─── Hard ceiling: serious+ immediately clamps ───
    if (raw >= 2.0f) {
        effective = raw;  // No smoothing, immediate response
        last_serious_time_s_ = timestamp_s;
        recovery_active_ = true;
    }

    // ─── Recovery hysteresis ───
    if (recovery_active_ && raw < 2.0f) {
        double time_since_serious = timestamp_s - last_serious_time_s_;
        if (time_since_serious < config_.recovery_delay_s) {
            // Keep at fair level minimum during recovery
            effective = std::max(effective, 1.0f);
        } else {
            recovery_active_ = false;
        }
    }

    // ─── Compute targets ───
    float new_target_fps = fps_for_level(effective);
    float new_target_training = training_rate_for_level(effective);

    // Start new transition if targets changed significantly
    if (std::abs(new_target_fps - target_fps_) > 0.5f) {
        target_fps_ = new_target_fps;
        transition_start_s_ = timestamp_s;
    }
    if (std::abs(new_target_training - target_training_rate_) > 0.01f) {
        target_training_rate_ = new_target_training;
    }

    // ─── Smooth transition (linear interpolation over duration) ───
    float transition_progress = 1.0f;
    if (config_.transition_duration_s > 0.001f) {
        float elapsed = static_cast<float>(timestamp_s - transition_start_s_);
        transition_progress = std::clamp(
            elapsed / config_.transition_duration_s, 0.0f, 1.0f);
    }

    current_fps_ = lerp(current_fps_, target_fps_, transition_progress);
    current_training_rate_ = lerp(current_training_rate_, target_training_rate_,
                                   std::min(transition_progress * 2.0f, 1.0f));

    // ─── Checkpoint trigger (once per serious+ entry) ───
    bool checkpoint = false;
    if (config_.checkpoint_on_serious && raw >= 2.0f && !was_serious_) {
        checkpoint = true;
    }
    was_serious_ = raw >= 2.0f;

    ThermalLevel eff_level;
    if (effective >= 2.5f) {
        eff_level = ThermalLevel::kCritical;
    } else if (effective >= 1.5f) {
        eff_level = ThermalLevel::kSerious;
    } else if (effective >= 0.5f) {
        eff_level = ThermalLevel::kFair;
    } else {
        eff_level = ThermalLevel::kNominal;
    }

    return ThermalRecommendation{
        current_fps_,
        current_training_rate_,
        checkpoint,
        eff_level,
    };
}

float ThermalPredictor::fps_for_level(float level) const noexcept {
    if (level <= 0.0f) return config_.fps_nominal;
    if (level <= 1.0f) return lerp(config_.fps_nominal, config_.fps_fair, level);
    if (level <= 2.0f) return lerp(config_.fps_fair, config_.fps_serious, level - 1.0f);
    return lerp(config_.fps_serious, config_.fps_critical,
                std::min(level - 2.0f, 1.0f));
}

float ThermalPredictor::training_rate_for_level(float level) const noexcept {
    if (level <= 0.0f) return config_.training_rate_nominal;
    if (level <= 1.0f) return lerp(config_.training_rate_nominal, config_.training_rate_fair, level);
    if (level <= 2.0f) return lerp(config_.training_rate_fair, config_.training_rate_serious, level - 1.0f);
    return lerp(config_.training_rate_serious, config_.training_rate_critical,
                std::min(level - 2.0f, 1.0f));
}

float ThermalPredictor::lerp(float a, float b, float t) const noexcept {
    return a + (b - a) * t;
}

}  // namespace thermal
}  // namespace aether
