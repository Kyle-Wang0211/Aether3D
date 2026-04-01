// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/thermal/thermal_predictor.h"

#include <cassert>
#include <cmath>
#include <cstdio>

using namespace aether::thermal;

static void test_default_state() {
    ThermalPredictor predictor;

    [[maybe_unused]] auto rec = predictor.evaluate(0.0);
    assert(rec.effective_level == ThermalLevel::kNominal);
    assert(rec.target_fps >= 59.0f);
    assert(rec.training_rate >= 0.99f);
    assert(!rec.should_checkpoint);

    std::printf("  PASS: default state → nominal, 60fps, full training\n");
}

static void test_thermal_escalation() {
    ThermalConfig config;
    config.transition_duration_s = 0.0f;  // Instant transitions for test
    ThermalPredictor predictor(config);

    // Initialize
    predictor.evaluate(0.0);

    // Set to fair and wait for convergence
    predictor.set_thermal_state(1);
    auto rec = predictor.evaluate(1.0);
    // With instant transitions, fps should reach target immediately
    assert(rec.target_fps <= 56.0f);
    assert(rec.training_rate <= 0.6f);

    // Set to serious
    predictor.set_thermal_state(2);
    rec = predictor.evaluate(2.0);
    assert(rec.effective_level == ThermalLevel::kSerious);
    assert(rec.training_rate < 0.01f);  // Training paused
    assert(rec.should_checkpoint);       // First time entering serious

    // Second evaluate at serious — no duplicate checkpoint
    rec = predictor.evaluate(3.0);
    assert(!rec.should_checkpoint);

    std::printf("  PASS: escalation nominal→fair→serious with checkpoint\n");
}

static void test_recovery_hysteresis() {
    ThermalConfig config;
    config.recovery_delay_s = 3.0f;
    config.transition_duration_s = 0.0f;  // Instant transitions
    ThermalPredictor predictor(config);

    // Initialize
    predictor.evaluate(0.0);

    // Heat up to serious
    predictor.set_thermal_state(2);
    predictor.evaluate(1.0);

    // Cool down
    predictor.set_thermal_state(0);
    auto rec = predictor.evaluate(2.0);
    // Should still be at fair minimum (recovery hysteresis)
    assert(rec.effective_level >= ThermalLevel::kFair);

    // After recovery delay (serious was at t=1.0, need t > 1.0 + 3.0 = 4.0)
    rec = predictor.evaluate(5.0);
    assert(rec.effective_level == ThermalLevel::kNominal);

    std::printf("  PASS: recovery hysteresis (3s delay)\n");
}

static void test_smooth_transitions() {
    ThermalConfig config;
    config.transition_duration_s = 2.0f;
    ThermalPredictor predictor(config);

    // Get initial fps
    [[maybe_unused]] auto rec0 = predictor.evaluate(0.0);
    [[maybe_unused]] float initial_fps = rec0.target_fps;
    assert(std::abs(initial_fps - 60.0f) < 1.0f);

    // Jump to fair
    predictor.set_thermal_state(1);

    // First eval at t=1.0 starts transition
    [[maybe_unused]] auto rec1 = predictor.evaluate(1.0);
    // Transition just started at t=1.0, elapsed=0, so fps near 60
    assert(rec1.target_fps > 54.0f);  // Not fully fair yet

    // After full transition (t=1.0 start + 2.0 duration = t=3.0)
    [[maybe_unused]] auto rec2 = predictor.evaluate(4.0);
    assert(rec2.target_fps <= 56.0f);  // Fully fair now

    std::printf("  PASS: smooth fps transitions over 2s\n");
}

static void test_critical_immediate() {
    ThermalConfig config;
    config.transition_duration_s = 0.0f;
    ThermalPredictor predictor(config);

    predictor.evaluate(0.0);

    // Critical should respond immediately
    predictor.set_thermal_state(3);
    [[maybe_unused]] auto rec = predictor.evaluate(1.0);
    assert(rec.effective_level == ThermalLevel::kCritical);
    assert(rec.training_rate < 0.01f);

    std::printf("  PASS: critical → immediate response\n");
}

static void test_level_query() {
    ThermalPredictor predictor;

    assert(predictor.current_level() == ThermalLevel::kNominal);

    predictor.set_thermal_state(2);
    assert(predictor.current_level() == ThermalLevel::kSerious);

    predictor.set_thermal_state(0);
    assert(predictor.current_level() == ThermalLevel::kNominal);

    std::printf("  PASS: current_level() lock-free query\n");
}

static void test_clamping() {
    ThermalPredictor predictor;

    // Invalid values should clamp
    predictor.set_thermal_state(-5);
    assert(predictor.current_level() == ThermalLevel::kNominal);

    predictor.set_thermal_state(99);
    assert(predictor.current_level() == ThermalLevel::kCritical);

    std::printf("  PASS: input clamping (negative and overflow)\n");
}

static void test_checkpoint_dedup() {
    ThermalConfig config;
    config.transition_duration_s = 0.0f;
    config.checkpoint_on_serious = true;
    ThermalPredictor predictor(config);

    predictor.evaluate(0.0);

    // Enter serious → should trigger checkpoint
    predictor.set_thermal_state(2);
    auto rec = predictor.evaluate(1.0);
    assert(rec.should_checkpoint);

    // Stay at serious → no duplicate
    rec = predictor.evaluate(2.0);
    assert(!rec.should_checkpoint);

    // Drop to nominal
    predictor.set_thermal_state(0);
    predictor.evaluate(10.0);  // Past recovery delay

    // Re-enter serious → should trigger checkpoint again
    predictor.set_thermal_state(2);
    rec = predictor.evaluate(11.0);
    assert(rec.should_checkpoint);

    std::printf("  PASS: checkpoint dedup (once per serious entry)\n");
}

int main() {
    std::printf("=== ThermalPredictor tests ===\n");

    test_default_state();
    test_thermal_escalation();
    test_recovery_hysteresis();
    test_smooth_transitions();
    test_critical_immediate();
    test_level_query();
    test_clamping();
    test_checkpoint_dedup();

    std::printf("=== All ThermalPredictor tests passed ===\n");
    return 0;
}
