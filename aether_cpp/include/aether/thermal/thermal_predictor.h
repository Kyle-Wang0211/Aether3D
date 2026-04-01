// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_THERMAL_THERMAL_PREDICTOR_H
#define AETHER_THERMAL_THERMAL_PREDICTOR_H

#ifdef __cplusplus

#include <atomic>
#include <cstdint>

namespace aether {
namespace thermal {

// ═══════════════════════════════════════════════════════════════════════
// ThermalPredictor: MAESTRO-inspired predictive thermal management
// ═══════════════════════════════════════════════════════════════════════
// Predicts future thermal state and applies smooth throttling BEFORE
// hitting thermal limits. Key behaviors:
//   - Predicts temperature 30s ahead using exponential moving average
//   - Smooth frame rate transitions (60→55→48→40, linear interpolation)
//   - 5s hysteresis on recovery (prevents oscillation)
//   - Hard ceiling: .serious → immediate training pause
//   - Neural Engine unaffected (DAv2 runs independently)
//
// Thread safety: set_thermal_state() from any thread (atomic).
// evaluate() and target_fps()/should_train() from coordinator thread.

/// Thermal state levels from iOS ProcessInfo.ThermalState
enum class ThermalLevel : int {
    kNominal  = 0,   // <65C: full speed
    kFair     = 1,   // 65-72C: reduce training 50%
    kSerious  = 2,   // 72-78C: pause training, reduce fps
    kCritical = 3,   // >78C: minimum rendering only
};

/// Configuration for thermal prediction.
struct ThermalConfig {
    // Prediction EMA parameters
    float ema_alpha{0.15f};              // Smoothing factor (0..1), lower = smoother
    float prediction_horizon_s{30.0f};   // Look-ahead window

    // Target frame rates per level (smooth interpolation between these)
    float fps_nominal{60.0f};
    float fps_fair{55.0f};
    float fps_serious{48.0f};
    float fps_critical{40.0f};

    // Training throttle: step interval multiplier per level
    // 1.0 = full speed, 0.5 = half speed, 0.1 = 10% speed
    // NEVER fully pause — user expects training progress while scanning.
    // Heatmap = rendering promise → training must always make progress.
    float training_rate_nominal{1.0f};
    float training_rate_fair{0.5f};
    float training_rate_serious{0.15f};   // Slow but running (~15 steps/sec)
    float training_rate_critical{0.05f};  // Minimal but still progressing

    // Recovery hysteresis: wait this long after cooldown before ramping up
    float recovery_delay_s{5.0f};

    // Transition smoothing: time to interpolate between levels
    float transition_duration_s{2.0f};

    // Checkpoint trigger: save checkpoint when entering .serious+
    bool checkpoint_on_serious{true};
};

/// Output recommendation from the predictor.
struct ThermalRecommendation {
    float target_fps;            // Smoothly interpolated target FPS
    float training_rate;         // 0.0 (paused) to 1.0 (full speed)
    bool should_checkpoint;      // True when entering serious+ (once)
    ThermalLevel effective_level; // Current effective level (after prediction)
};

class ThermalPredictor {
public:
    explicit ThermalPredictor(const ThermalConfig& config = {}) noexcept;

    /// Set current thermal state from system. Thread-safe (atomic).
    void set_thermal_state(int level) noexcept;

    /// Evaluate thermal state and return recommendation.
    /// Called once per frame from coordinator thread.
    /// timestamp_s: monotonic seconds (for transition smoothing).
    ThermalRecommendation evaluate(double timestamp_s) noexcept;

    /// Get current raw thermal level (lock-free).
    ThermalLevel current_level() const noexcept;

private:
    ThermalConfig config_;
    std::atomic<int> raw_level_{0};

    // EMA state
    float ema_level_{0.0f};         // Smoothed thermal level (0.0 - 3.0)
    float predicted_level_{0.0f};   // Predicted future level

    // Transition state
    float current_fps_{60.0f};
    float target_fps_{60.0f};
    float current_training_rate_{1.0f};
    float target_training_rate_{1.0f};
    double transition_start_s_{0.0};
    double last_evaluate_s_{0.0};

    // Recovery hysteresis
    double last_serious_time_s_{-100.0};  // Last time at serious+
    bool recovery_active_{false};

    // Checkpoint dedup
    bool was_serious_{false};

    // Helpers
    float fps_for_level(float level) const noexcept;
    float training_rate_for_level(float level) const noexcept;
    float lerp(float a, float b, float t) const noexcept;
};

}  // namespace thermal
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_THERMAL_THERMAL_PREDICTOR_H
