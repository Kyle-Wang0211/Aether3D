// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/evidence_state_machine.h"

#include <cassert>
#include <cmath>
#include <cstdio>

using namespace aether::evidence;

namespace {

// ── Helper: build an EvidenceStateMachineInput with only coverage set ──
// For S0-S4 tests that only care about coverage, all other fields default to
// "not S5 ready" (dim_scores all 0 → Choquet will be 0, lyapunov_rate=1.0).
EvidenceStateMachineInput coverage_only(double bel_cov) {
    EvidenceStateMachineInput in{};
    in.coverage = bel_cov;
    // All other fields at default → S5 gates will NOT pass.
    return in;
}

// ── Helper: build a fully-S5-certified input ──
// All 6 gates satisfied with comfortable margin.
EvidenceStateMachineInput s5_certified_input(
    double bel_cov = 0.90,
    double pl_cov = 0.95,
    double unc = 0.05,
    double high_obs = 0.35,
    double lyap = 0.03,
    double all_dims = 0.80)
{
    EvidenceStateMachineInput in{};
    in.coverage = bel_cov;
    in.plausibility_coverage = pl_cov;
    in.uncertainty_width = unc;
    in.high_observation_ratio = high_obs;
    in.lyapunov_rate = lyap;
    for (int i = 0; i < 10; ++i) in.dim_scores[i] = all_dims;
    return in;
}

// ---------------------------------------------------------------------------
// T1: Default starts at S0 (kBlack)
// ---------------------------------------------------------------------------
void test_default_state() {
    EvidenceStateMachine sm;
    assert(sm.current_state() == ColorState::kBlack);
    std::printf("  PASS test_default_state\n");
}

// ---------------------------------------------------------------------------
// T2: Golden path S0 → S1 → S2 → S3 → S4 → S5
// ---------------------------------------------------------------------------
void test_golden_path_s0_to_s5() {
    EvidenceStateMachine sm;

    // S0: coverage = 0
    {
        auto r = sm.evaluate(coverage_only(0.0));
        assert(r.state == ColorState::kBlack);
        assert(!r.transitioned);
    }

    // S1: coverage = 0.10  (S1 and S2 both map to kDarkGray)
    {
        auto r = sm.evaluate(coverage_only(0.10));
        assert(r.state == ColorState::kDarkGray);
        assert(r.transitioned);
        assert(r.previous_state == ColorState::kBlack);
    }

    // S2: coverage = 0.25 — still kDarkGray (same visual), no transition
    {
        auto r = sm.evaluate(coverage_only(0.25));
        assert(r.state == ColorState::kDarkGray);
        assert(!r.transitioned);  // same order value
    }

    // S3: coverage = 0.50
    {
        auto r = sm.evaluate(coverage_only(0.50));
        assert(r.state == ColorState::kLightGray);
        assert(r.transitioned);
        assert(r.previous_state == ColorState::kDarkGray);
    }

    // S4: coverage = 0.75
    {
        auto r = sm.evaluate(coverage_only(0.75));
        assert(r.state == ColorState::kWhite);
        assert(r.transitioned);
        assert(r.previous_state == ColorState::kLightGray);
    }

    // S5: all 6 gates satisfied
    {
        auto r = sm.evaluate(s5_certified_input());
        assert(r.state == ColorState::kOriginal);
        assert(r.transitioned);
        assert(r.previous_state == ColorState::kWhite);
    }

    std::printf("  PASS test_golden_path_s0_to_s5\n");
}

// ---------------------------------------------------------------------------
// T3: Monotonic — state never decreases
// ---------------------------------------------------------------------------
void test_monotonic_never_retreats() {
    EvidenceStateMachine sm;

    // Advance to S4 (kWhite)
    sm.evaluate(coverage_only(0.80));
    assert(sm.current_state() == ColorState::kWhite);

    // Try to go back with coverage = 0 → should stay at kWhite
    {
        auto r = sm.evaluate(coverage_only(0.0));
        assert(r.state == ColorState::kWhite);
        assert(!r.transitioned);
    }

    // Try coverage = 0.30 → still kWhite
    {
        auto r = sm.evaluate(coverage_only(0.30));
        assert(r.state == ColorState::kWhite);
        assert(!r.transitioned);
    }

    // Advance to S5
    {
        auto r = sm.evaluate(s5_certified_input());
        assert(r.state == ColorState::kOriginal);
        assert(r.transitioned);
    }

    // Try to go back from S5 — stays at kOriginal
    {
        auto r = sm.evaluate(coverage_only(0.0));
        assert(r.state == ColorState::kOriginal);
        assert(!r.transitioned);
    }

    std::printf("  PASS test_monotonic_never_retreats\n");
}

// ---------------------------------------------------------------------------
// T4: S5 requires ALL 6 information-theoretic gates
// ---------------------------------------------------------------------------
void test_s5_six_gate() {
    // Case A: High coverage but dim_scores all 0 → Choquet=0 → S4 only
    {
        EvidenceStateMachine sm;
        EvidenceStateMachineInput in{};
        in.coverage = 0.95;
        in.plausibility_coverage = 0.98;
        in.uncertainty_width = 0.03;
        in.high_observation_ratio = 0.40;
        in.lyapunov_rate = 0.02;
        // dim_scores all 0 → Choquet = 0, min_super_dim = 0
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kWhite);  // S4, not S5
    }

    // Case B: All gates OK but uncertainty_width too large → S4
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.uncertainty_width = 0.30;  // exceeds 0.15 threshold
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kWhite);
    }

    // Case C: All gates OK but lyapunov_rate too large (not converged) → S4
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.lyapunov_rate = 0.20;  // exceeds 0.05 threshold
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kWhite);
    }

    // Case D: All gates OK but high_observation_ratio too low → S4
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.high_observation_ratio = 0.20;  // below 0.30 threshold
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kWhite);
    }

    // Case E: All gates OK but min_super_dim too low (viewGain low) → S4
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        // Set viewGain(dim[0]) and viewDiversity(dim[9]) low →
        // D_view = min(viewGain, viewDiversity) will be low
        in.dim_scores[0] = 0.30;
        in.dim_scores[9] = 0.30;
        auto r = sm.evaluate(in);
        // D_view = min(0.30, 0.30) = 0.30 < 0.45 threshold
        assert(r.state == ColorState::kWhite);
    }

    // Case F: Coverage just below S5 threshold → S4
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.coverage = 0.879;  // below 0.88
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kWhite);
    }

    // Case G: All 6 gates satisfied → S5
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(s5_certified_input());
        assert(r.state == ColorState::kOriginal);
    }

    // Case H: Low coverage + high soft signals → still lower state
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.coverage = 0.50;  // only S3 level coverage
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kLightGray);  // S3
    }

    std::printf("  PASS test_s5_six_gate\n");
}

// ---------------------------------------------------------------------------
// T5: Reset brings back to S0
// ---------------------------------------------------------------------------
void test_reset() {
    EvidenceStateMachine sm;
    sm.evaluate(s5_certified_input());
    assert(sm.current_state() == ColorState::kOriginal);

    sm.reset();
    assert(sm.current_state() == ColorState::kBlack);

    // Can progress again from S0
    auto r = sm.evaluate(coverage_only(0.60));
    assert(r.state == ColorState::kLightGray);
    assert(r.transitioned);

    std::printf("  PASS test_reset\n");
}

// ---------------------------------------------------------------------------
// T6: NaN / infinity inputs → treated as 0 (safe fallback)
// ---------------------------------------------------------------------------
void test_nan_infinity_handling() {
    EvidenceStateMachine sm;

    // NaN coverage
    {
        auto r = sm.evaluate(coverage_only(std::nan("")));
        assert(r.state == ColorState::kBlack);
    }

    // Infinity coverage — not isfinite, maps to 0.0
    {
        auto r = sm.evaluate(coverage_only(1.0 / 0.0));
        assert(r.state == ColorState::kBlack);
    }

    // Negative coverage
    {
        auto r = sm.evaluate(coverage_only(-0.5));
        assert(r.state == ColorState::kBlack);  // clamped to 0
    }

    // NaN in dim_scores → Choquet handles safely
    {
        sm.reset();
        auto in = s5_certified_input();
        in.dim_scores[0] = std::nan("");
        in.dim_scores[3] = 1.0 / 0.0;  // infinity
        auto r = sm.evaluate(in);
        // Should not crash; NaN dims → super_dim may drop below threshold
        // Result could be S4 or S5 depending on which dims affected
        assert(r.state == ColorState::kWhite || r.state == ColorState::kOriginal);
    }

    // NaN plausibility
    {
        EvidenceStateMachine sm2;
        auto in = s5_certified_input();
        in.plausibility_coverage = std::nan("");
        auto r = sm2.evaluate(in);
        // plausibility NaN → clamped to 0.0, but coverage_cert based on bel_cov
        // Bel=0.90 >= 0.88 → coverage_cert=Certified (bel-based check unaffected)
        // The test verifies no crash
        (void)r;
    }

    std::printf("  PASS test_nan_infinity_handling\n");
}

// ---------------------------------------------------------------------------
// T7: Custom config thresholds (including S5 info-theoretic gates)
// ---------------------------------------------------------------------------
void test_custom_config() {
    EvidenceStateMachineConfig config{};
    config.s0_to_s1_threshold     = 0.05;  // Lower than default
    config.s1_to_s2_threshold     = 0.15;
    config.s2_to_s3_threshold     = 0.30;
    config.s3_to_s4_threshold     = 0.60;
    config.s4_to_s5_threshold     = 0.80;
    // Relaxed S5 gates for easier triggering
    config.s5_min_choquet         = 0.50;
    config.s5_min_dimension_score = 0.30;
    config.s5_max_uncertainty_width = 0.25;
    config.s5_min_high_obs_ratio  = 0.20;
    config.s5_max_lyapunov_rate   = 0.10;

    EvidenceStateMachine sm(config);

    // Coverage 0.05 → S1 with custom threshold (default would be S0)
    {
        auto r = sm.evaluate(coverage_only(0.05));
        assert(r.state == ColorState::kDarkGray);
    }

    // Coverage 0.60 + custom threshold → S4
    {
        auto r = sm.evaluate(coverage_only(0.60));
        assert(r.state == ColorState::kWhite);
    }

    // S5 with relaxed gates
    {
        auto in = s5_certified_input(
            0.80,   // bel_cov (matches custom s4_to_s5)
            0.90,   // pl_cov
            0.10,   // uncertainty_width (under 0.25)
            0.25,   // high_obs (over custom 0.20)
            0.08,   // lyapunov_rate (under custom 0.10)
            0.60);  // all_dims → Choquet ~0.6 (over custom 0.50)
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kOriginal);
    }

    std::printf("  PASS test_custom_config\n");
}

// ---------------------------------------------------------------------------
// T8: color_state_order function
// ---------------------------------------------------------------------------
void test_color_state_order() {
    assert(color_state_order(ColorState::kUnknown) == -1);
    assert(color_state_order(ColorState::kBlack) == 0);
    assert(color_state_order(ColorState::kDarkGray) == 1);
    assert(color_state_order(ColorState::kLightGray) == 2);
    assert(color_state_order(ColorState::kWhite) == 3);
    assert(color_state_order(ColorState::kOriginal) == 4);

    // Verify strict ordering
    assert(color_state_order(ColorState::kBlack) < color_state_order(ColorState::kDarkGray));
    assert(color_state_order(ColorState::kDarkGray) < color_state_order(ColorState::kLightGray));
    assert(color_state_order(ColorState::kLightGray) < color_state_order(ColorState::kWhite));
    assert(color_state_order(ColorState::kWhite) < color_state_order(ColorState::kOriginal));

    std::printf("  PASS test_color_state_order\n");
}

// ---------------------------------------------------------------------------
// T9: Boundary values at exact thresholds (S0-S4 unchanged)
// ---------------------------------------------------------------------------
void test_exact_thresholds() {
    // Test that >= comparison is correct (not >)
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.10));
        assert(r.state == ColorState::kDarkGray);  // exactly 0.10 triggers S1
    }
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.25));
        assert(r.state == ColorState::kDarkGray);  // S2 = same visual as S1
    }
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.50));
        assert(r.state == ColorState::kLightGray);
    }
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.75));
        assert(r.state == ColorState::kWhite);
    }

    // Just below each threshold
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.099));
        assert(r.state == ColorState::kBlack);
    }
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.499));
        assert(r.state == ColorState::kDarkGray);
    }
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(coverage_only(0.749));
        assert(r.state == ColorState::kLightGray);
    }

    // S5 exact boundary: exactly at all 6 gate thresholds
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input(
            0.88,   // exactly at s4_to_s5
            0.93,   // Pl
            0.05,   // unc
            0.30,   // exactly at high_obs threshold
            0.05,   // exactly at lyapunov threshold
            0.80);  // dims → Choquet ~0.80 > 0.72, min_dim ~0.80 > 0.45
        // First reach S4 (monotonic, so we need to go through)
        sm.evaluate(coverage_only(0.80));
        auto r = sm.evaluate(in);
        assert(r.state == ColorState::kOriginal);
    }

    std::printf("  PASS test_exact_thresholds\n");
}

// ---------------------------------------------------------------------------
// T10: Rapid consecutive calls (stress test for monotonicity)
// ---------------------------------------------------------------------------
void test_rapid_monotonic_stress() {
    EvidenceStateMachine sm;
    int last_order = -1;

    // Build up gradually with coverage_only, then hit S5 with full input
    const double coverages[] = {
        0.0, 0.05, 0.12, 0.08, 0.30, 0.20, 0.55, 0.40,
        0.80, 0.60, 0.90, 0.70, 0.88, 0.50, 0.95, 0.10
    };

    for (int i = 0; i < 16; ++i) {
        EvidenceStateMachineInput in{};
        in.coverage = coverages[i];

        // At index 12 (coverage=0.88), provide full S5 certification
        if (i == 12) {
            in = s5_certified_input(coverages[i]);
        }

        auto r = sm.evaluate(in);
        int order = color_state_order(r.state);
        assert(order >= last_order);
        last_order = order;
    }

    // Should have reached S5 somewhere in the sequence
    assert(sm.current_state() == ColorState::kOriginal);

    std::printf("  PASS test_rapid_monotonic_stress\n");
}

// ---------------------------------------------------------------------------
// T11: Choquet integral aggregation
// ---------------------------------------------------------------------------
void test_choquet_aggregation() {
    const auto mu = ChoquetFuzzyMeasure::default_measure();

    // Case 1: All dims = 0.8 → uniform super-dims → Choquet ≈ 0.80
    {
        double dims[10];
        for (int i = 0; i < 10; ++i) dims[i] = 0.80;
        auto r = choquet_aggregate_5(dims, mu);
        // All super-dims = 0.8 (max/min/mean of 0.8 = 0.8)
        // Choquet with uniform values = value * mu({all}) = 0.8 * 1.0 = 0.8
        assert(r.aggregated > 0.75 && r.aggregated < 0.85);
        // Additive = sum(w_i * 0.8) = 0.8 * sum(w_i) ≈ 0.8 * 0.95 = 0.76
        assert(r.additive > 0.70 && r.additive < 0.85);
        for (int i = 0; i < 5; ++i) {
            assert(r.super_dims[i] > 0.79 && r.super_dims[i] < 0.81);
        }
    }

    // Case 2: Strong view diversity (viewGain=1.0, viewDiversity=1.0), others=0.5
    // Should show synergy bonus (D_geo + D_view together > sum of parts)
    {
        double dims[10] = {1.0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0};
        auto r = choquet_aggregate_5(dims, mu);
        // D_view = min(1.0, 1.0) = 1.0
        // D_geo  = max(0.5, 0.5) = 0.5
        // D_semantic = mean(0.5, 0.5) = 0.5
        // D_provenance = mean(0.5, 0.5) = 0.5
        // D_tracker = min(0.5, 0.5) = 0.5
        assert(r.super_dims[1] > 0.99);  // D_view
        assert(r.super_dims[0] < 0.51);  // D_geo
        // Choquet should give bonus for having D_view=1.0
        assert(r.aggregated > r.additive);  // synergy
    }

    // Case 3: All zeros → Choquet = 0
    {
        double dims[10]{};
        auto r = choquet_aggregate_5(dims, mu);
        assert(r.aggregated < 0.01);
        assert(r.additive < 0.01);
        for (int i = 0; i < 5; ++i) {
            assert(r.super_dims[i] < 0.01);
        }
    }

    // Case 4: All ones → Choquet = mu({all}) = 1.0
    {
        double dims[10];
        for (int i = 0; i < 10; ++i) dims[i] = 1.0;
        auto r = choquet_aggregate_5(dims, mu);
        assert(r.aggregated > 0.99 && r.aggregated <= 1.0);
    }

    // Case 5: NaN in one dimension → safe01 maps to 0
    {
        double dims[10];
        for (int i = 0; i < 10; ++i) dims[i] = 0.80;
        dims[0] = std::nan("");  // viewGain → affects D_view
        auto r = choquet_aggregate_5(dims, mu);
        // D_view = min(0.0, 0.8) = 0.0 (NaN→0)
        assert(r.super_dims[1] < 0.01);  // D_view bottlenecked
        // Result should still be a valid number
        assert(std::isfinite(r.aggregated));
    }

    std::printf("  PASS test_choquet_aggregation\n");
}

// ---------------------------------------------------------------------------
// T12: DS interval certification (three-valued logic)
// ---------------------------------------------------------------------------
void test_ds_interval_certification() {
    // Case 1: Bel=0.90 >= 0.88 → Certified
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input(0.90, 0.95, 0.05, 0.35, 0.03, 0.80);
        auto r = sm.evaluate(in);
        assert(r.coverage_cert == CertifiedState::kCertified);
        assert(r.state == ColorState::kOriginal);
    }

    // Case 2: Bel=0.80 < 0.88, Pl=0.92 >= 0.88 → Uncertain
    {
        EvidenceStateMachine sm;
        EvidenceStateMachineInput in{};
        in.coverage = 0.80;
        in.plausibility_coverage = 0.92;
        in.uncertainty_width = 0.12;
        auto r = sm.evaluate(in);
        assert(r.coverage_cert == CertifiedState::kUncertain);
        // Bel not certified → can't be S5
        assert(r.state == ColorState::kWhite);  // S4
    }

    // Case 3: Bel=0.70, Pl=0.85 < 0.88 → Impossible
    {
        EvidenceStateMachine sm;
        EvidenceStateMachineInput in{};
        in.coverage = 0.70;
        in.plausibility_coverage = 0.85;
        in.uncertainty_width = 0.15;
        auto r = sm.evaluate(in);
        assert(r.coverage_cert == CertifiedState::kImpossible);
        assert(r.state == ColorState::kLightGray);  // S3
    }

    // Case 4: Choquet certification
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input(0.90, 0.95, 0.05, 0.35, 0.03, 0.80);
        auto r = sm.evaluate(in);
        assert(r.choquet_cert == CertifiedState::kCertified);
        assert(r.choquet_value > 0.70);  // All dims=0.80 → Choquet ~0.80
    }

    // Case 5: Low dims → Choquet uncertain
    {
        EvidenceStateMachine sm;
        EvidenceStateMachineInput in{};
        in.coverage = 0.90;
        in.plausibility_coverage = 0.95;
        in.uncertainty_width = 0.05;
        in.high_observation_ratio = 0.35;
        in.lyapunov_rate = 0.03;
        for (int i = 0; i < 10; ++i) in.dim_scores[i] = 0.40;
        auto r = sm.evaluate(in);
        assert(r.choquet_cert == CertifiedState::kUncertain);
        assert(r.choquet_value < 0.72);  // Below threshold
    }

    std::printf("  PASS test_ds_interval_certification\n");
}

// ---------------------------------------------------------------------------
// T13: Certification margin diagnostic
// ---------------------------------------------------------------------------
void test_certification_margin() {
    // All gates well above threshold → positive margin
    {
        EvidenceStateMachine sm;
        auto r = sm.evaluate(s5_certified_input());
        assert(r.certification_margin > 0.0);
        assert(r.state == ColorState::kOriginal);
    }

    // One gate just barely failing → negative margin
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.high_observation_ratio = 0.28;  // 0.28 < 0.30 → margin = -0.02
        auto r = sm.evaluate(in);
        assert(r.certification_margin < 0.0);
        assert(r.state == ColorState::kWhite);
    }

    // Edge case: gate exactly at threshold → margin = 0
    {
        EvidenceStateMachine sm;
        auto in = s5_certified_input();
        in.high_observation_ratio = 0.30;  // exactly at threshold
        auto r = sm.evaluate(in);
        // Margin should be ~0 (this gate is the bottleneck at 0.0)
        // Other gates have positive margin, so overall margin = 0.0
        assert(r.certification_margin >= 0.0);
    }

    std::printf("  PASS test_certification_margin\n");
}

// ---------------------------------------------------------------------------
// T14: Super-dimension min diagnostic
// ---------------------------------------------------------------------------
void test_min_super_dim_diagnostic() {
    EvidenceStateMachine sm;

    // D_tracker = min(coverageTrackerScore[7], resolutionQuality[8])
    // Set these low while others high → min_super_dim = D_tracker
    auto in = s5_certified_input();
    in.dim_scores[7] = 0.20;  // coverageTrackerScore
    in.dim_scores[8] = 0.25;  // resolutionQuality
    auto r = sm.evaluate(in);

    // D_tracker = min(0.20, 0.25) = 0.20
    assert(r.min_super_dim < 0.25);
    assert(r.min_super_dim > 0.15);
    // Below s5_min_dimension_score (0.45) → S4
    assert(r.state == ColorState::kWhite);

    std::printf("  PASS test_min_super_dim_diagnostic\n");
}

}  // namespace

int main() {
    std::printf("evidence_state_machine_test\n");
    test_default_state();                   // T1
    test_golden_path_s0_to_s5();            // T2
    test_monotonic_never_retreats();        // T3
    test_s5_six_gate();                     // T4 (expanded from dual_gate)
    test_reset();                           // T5
    test_nan_infinity_handling();           // T6 (expanded)
    test_custom_config();                   // T7 (updated)
    test_color_state_order();               // T8
    test_exact_thresholds();                // T9 (expanded)
    test_rapid_monotonic_stress();          // T10 (updated)
    test_choquet_aggregation();             // T11 (NEW)
    test_ds_interval_certification();       // T12 (NEW)
    test_certification_margin();            // T13 (NEW)
    test_min_super_dim_diagnostic();        // T14 (NEW)
    std::printf("ALL PASSED (14 tests)\n");
    return 0;
}
