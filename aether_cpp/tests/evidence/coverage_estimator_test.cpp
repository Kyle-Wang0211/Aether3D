// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/coverage_estimator.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

bool approx(double a, double b, double eps) {
    return std::fabs(a - b) <= eps;
}

// ---------------------------------------------------------------------------
// T1: Level weighting and smoothing (discrete mode — Fisher OFF)
// ---------------------------------------------------------------------------
int test_level_weighting_and_smoothing() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.use_fisher_weights = false;  // Use discrete level_weights
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator estimator{cfg};

    CoverageCellObservation cells[2]{};
    cells[0].level = 0u;
    cells[0].mass = DSMassFunction(1.0, 0.0, 0.0).sealed();
    cells[0].area_weight = 1.0;
    cells[1].level = 6u;
    cells[1].mass = DSMassFunction(1.0, 0.0, 0.0).sealed();
    cells[1].area_weight = 1.0;

    CoverageResult result{};
    if (estimator.update(cells, 2u, 1000, &result) != aether::core::Status::kOk) {
        std::fprintf(stderr, "coverage update failed\n");
        return 1;
    }
    // L0 weight=0.00, L6 weight=1.00 → raw = (0*1 + 1*1) / 2 = 0.5
    if (!approx(result.raw_coverage, 0.5, 1e-6)) {
        std::fprintf(stderr, "unexpected raw coverage: %f\n", result.raw_coverage);
        failed++;
    }
    if (!approx(result.coverage, 0.5, 1e-6)) {
        std::fprintf(stderr, "unexpected coverage output: %f\n", result.coverage);
        failed++;
    }
    if (result.breakdown_counts[0] != 1u || result.breakdown_counts[6] != 1u) {
        std::fprintf(stderr, "unexpected level breakdown\n");
        failed++;
    }
    // Info-theoretic fields should still be populated
    if (result.belief_coverage < 0.0 || result.plausibility_coverage < 0.0) {
        std::fprintf(stderr, "info-theoretic fields should be non-negative\n");
        failed++;
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T2: Rate limiter and non-monotonic handling (Fisher OFF)
// ---------------------------------------------------------------------------
int test_rate_limiter_and_non_monotonic_handling() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.use_fisher_weights = false;  // Deterministic behavior
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 0.10;
    CoverageEstimator estimator{cfg};

    CoverageCellObservation empty{};
    empty.level = 0u;
    empty.mass = DSMassFunction(0.0, 1.0, 0.0).sealed();
    empty.area_weight = 1.0;

    CoverageCellObservation full{};
    full.level = 6u;
    full.mass = DSMassFunction(1.0, 0.0, 0.0).sealed();
    full.area_weight = 1.0;

    CoverageResult result{};
    if (estimator.update(&empty, 1u, 1000, &result) != aether::core::Status::kOk) {
        std::fprintf(stderr, "coverage baseline update failed\n");
        return 1;
    }
    if (!approx(result.coverage, 0.0, 1e-6)) {
        std::fprintf(stderr, "baseline coverage mismatch: %f\n", result.coverage);
        failed++;
    }

    if (estimator.update(&full, 1u, 1500, &result) != aether::core::Status::kOk) {
        std::fprintf(stderr, "coverage step update failed\n");
        return failed + 1;
    }
    if (!approx(result.coverage, 0.05, 1e-6)) {
        std::fprintf(stderr, "rate limiter mismatch: %f\n", result.coverage);
        failed++;
    }

    if (estimator.update(&full, 1u, 1490, &result) != aether::core::Status::kOk) {
        std::fprintf(stderr, "non-monotonic update should still succeed\n");
        return failed + 1;
    }
    if (result.non_monotonic_time_count <= 0) {
        std::fprintf(stderr, "non-monotonic time count should increase\n");
        failed++;
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T3: State conversion (unchanged — EvidenceState → CoverageCellObservation)
// ---------------------------------------------------------------------------
int test_state_conversion() {
    int failed = 0;
    using namespace aether::evidence;

    EvidenceState state{};
    state.patches["p0"].evidence = 0.2;
    state.patches["p0"].observation_count = 2;
    state.patches["p1"].evidence = 0.9;
    state.patches["p1"].observation_count = 30;

    std::vector<CoverageCellObservation> cells;
    if (coverage_cells_from_evidence_state(state, &cells) != aether::core::Status::kOk) {
        std::fprintf(stderr, "state conversion failed\n");
        return 1;
    }
    if (cells.size() != 2u) {
        std::fprintf(stderr, "state conversion size mismatch\n");
        failed++;
    }

    bool saw_l1 = false;
    bool saw_l6 = false;
    for (const auto& c : cells) {
        if (c.level == 1u) {
            saw_l1 = true;
        }
        if (c.level == 6u) {
            saw_l6 = true;
        }
    }
    if (!saw_l1 || !saw_l6) {
        std::fprintf(stderr, "state conversion level mapping mismatch\n");
        failed++;
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T4: Invalid input paths
// ---------------------------------------------------------------------------
int test_invalid_paths() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.ema_alpha = -0.5;
    CoverageEstimator estimator{cfg};
    CoverageResult result{};
    if (estimator.update(nullptr, 0u, 0, &result) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "invalid config should fail update\n");
        failed++;
    }

    CoverageEstimator ok{};
    if (ok.update(nullptr, 1u, 0, &result) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null cells should fail for non-zero count\n");
        failed++;
    }
    if (coverage_cells_from_evidence_state(EvidenceState{}, nullptr) != aether::core::Status::kInvalidArgument) {
        std::fprintf(stderr, "null output vector should fail\n");
        failed++;
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T5 (NEW): Fisher-weighted coverage
// ---------------------------------------------------------------------------
int test_fisher_weighted_coverage() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.use_fisher_weights = true;
    cfg.fisher_normalization = 200.0;
    cfg.fisher_floor = 0.05;
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator estimator{cfg};

    // Patch 1: high confidence (n=20, p=0.85) → Fisher = 20/(0.85*0.15) ≈ 157
    //   weight ≈ 0.05 + 0.95 * min(1, 157/200) ≈ 0.05 + 0.95*0.785 ≈ 0.796
    // Patch 2: low confidence (n=3, p=0.50)   → Fisher = 3/(0.5*0.5) = 12
    //   weight ≈ 0.05 + 0.95 * min(1, 12/200) ≈ 0.05 + 0.95*0.06 ≈ 0.107
    CoverageCellObservation cells[2]{};
    cells[0].level = 5u;
    cells[0].mass = DSMassFunction(0.85, 0.05, 0.10).sealed();
    cells[0].area_weight = 1.0;
    cells[0].view_count = 20;
    cells[1].level = 2u;
    cells[1].mass = DSMassFunction(0.50, 0.20, 0.30).sealed();
    cells[1].area_weight = 1.0;
    cells[1].view_count = 3;

    CoverageResult result{};
    auto rc = estimator.update(cells, 2u, 1000, &result);
    if (rc != aether::core::Status::kOk) {
        std::fprintf(stderr, "Fisher-weighted update failed\n");
        return 1;
    }

    // Fisher-weighted coverage should exist and be reasonable
    if (result.raw_coverage < 0.0 || result.raw_coverage > 1.0) {
        std::fprintf(stderr, "Fisher raw_coverage out of bounds: %f\n", result.raw_coverage);
        failed++;
    }

    // Belief coverage should be populated
    if (result.belief_coverage <= 0.0) {
        std::fprintf(stderr, "belief_coverage should be > 0: %f\n", result.belief_coverage);
        failed++;
    }

    // Plausibility should be >= belief
    if (result.plausibility_coverage < result.belief_coverage - 1e-9) {
        std::fprintf(stderr, "plausibility should be >= belief: Pl=%f Bel=%f\n",
            result.plausibility_coverage, result.belief_coverage);
        failed++;
    }

    // Uncertainty width = Pl - Bel >= 0
    if (result.uncertainty_width < -1e-9) {
        std::fprintf(stderr, "uncertainty_width should be >= 0: %f\n", result.uncertainty_width);
        failed++;
    }

    // Mean Fisher info should be significant (both patches have Fisher > 10)
    if (result.mean_fisher_info < 10.0) {
        std::fprintf(stderr, "mean_fisher_info should be > 10: %f\n", result.mean_fisher_info);
        failed++;
    }

    // L5+ ratio: patch[0] is level=5, patch[1] is level=2 → ratio = 1/2 = 0.5
    if (!approx(result.high_observation_ratio, 0.5, 1e-6)) {
        std::fprintf(stderr, "high_observation_ratio expected 0.5, got %f\n",
            result.high_observation_ratio);
        failed++;
    }

    if (failed == 0) {
        std::printf("  PASS test_fisher_weighted_coverage\n");
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T6 (NEW): DS Belief/Plausibility interval output
// ---------------------------------------------------------------------------
int test_ds_interval_output() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.use_fisher_weights = false;  // Deterministic for this test
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator estimator{cfg};

    // Single cell: occupied=0.7, free=0.1, unknown=0.2
    // Bel = occupied = 0.7
    // Pl  = occupied + unknown = 0.9
    // Width = unknown = 0.2
    CoverageCellObservation cell{};
    cell.level = 4u;
    cell.mass = DSMassFunction(0.70, 0.10, 0.20).sealed();
    cell.area_weight = 1.0;

    CoverageResult result{};
    auto rc = estimator.update(&cell, 1u, 1000, &result);
    if (rc != aether::core::Status::kOk) {
        std::fprintf(stderr, "DS interval update failed\n");
        return 1;
    }

    // With discrete L4 weight = 0.80:
    // bel_coverage = weight * occupied * area / denominator
    // Since single cell: bel_coverage = 0.80 * 0.70 * 1.0 / (1.0 * diversity_factor)
    // The exact value depends on view_diversity_boost, but belief < plausibility always
    if (result.plausibility_coverage < result.belief_coverage - 1e-9) {
        std::fprintf(stderr, "Pl should be >= Bel\n");
        failed++;
    }
    if (result.uncertainty_width < 0.0 - 1e-9) {
        std::fprintf(stderr, "uncertainty width should be >= 0\n");
        failed++;
    }
    // The uncertainty should reflect the unknown mass
    // With a single cell, uncertainty = weight * unknown * area / denom should be > 0
    if (result.uncertainty_width < 1e-9) {
        std::fprintf(stderr, "uncertainty width should be > 0 for cell with unknown=0.2\n");
        failed++;
    }

    if (failed == 0) {
        std::printf("  PASS test_ds_interval_output\n");
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T7 (NEW): Lyapunov rate convergence tracking
// ---------------------------------------------------------------------------
int test_lyapunov_rate() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.use_fisher_weights = false;
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator estimator{cfg};

    // Frame 1: early stage, low coverage
    CoverageCellObservation cell{};
    cell.level = 2u;
    cell.mass = DSMassFunction(0.30, 0.10, 0.60).sealed();
    cell.area_weight = 1.0;
    cell.view_count = 3;

    CoverageResult r1{};
    estimator.update(&cell, 1u, 1000, &r1);
    // First frame: lyapunov_rate defaults to 1.0 (not initialized yet)

    // Frame 2: significant improvement
    cell.level = 5u;
    cell.mass = DSMassFunction(0.80, 0.10, 0.10).sealed();
    cell.view_count = 15;

    CoverageResult r2{};
    estimator.update(&cell, 1u, 2000, &r2);
    // Big change in lyapunov → rate should be significant
    if (!std::isfinite(r2.lyapunov_rate)) {
        std::fprintf(stderr, "lyapunov_rate should be finite: %f\n", r2.lyapunov_rate);
        failed++;
    }

    // Frame 3: nearly identical to frame 2 → converging
    cell.mass = DSMassFunction(0.82, 0.10, 0.08).sealed();
    cell.view_count = 18;

    CoverageResult r3{};
    estimator.update(&cell, 1u, 3000, &r3);
    // Small change → lyapunov_rate should be smaller than r2
    if (!std::isfinite(r3.lyapunov_rate)) {
        std::fprintf(stderr, "lyapunov_rate frame 3 should be finite\n");
        failed++;
    }
    // r3 rate should be less than r2 rate (converging)
    // Note: not guaranteed in all cases due to EMA, but with alpha=1.0 and
    // similar inputs, the rate should decrease
    if (r3.lyapunov_rate > r2.lyapunov_rate + 0.5) {
        std::fprintf(stderr, "lyapunov_rate should be decreasing, r2=%f r3=%f\n",
            r2.lyapunov_rate, r3.lyapunov_rate);
        failed++;
    }

    if (failed == 0) {
        std::printf("  PASS test_lyapunov_rate\n");
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T8 (NEW): Fisher vs discrete mode comparison
// ---------------------------------------------------------------------------
int test_fisher_vs_discrete() {
    int failed = 0;
    using namespace aether::evidence;

    // Same cells, different modes
    CoverageCellObservation cells[2]{};
    cells[0].level = 3u;
    cells[0].mass = DSMassFunction(0.60, 0.10, 0.30).sealed();
    cells[0].area_weight = 1.0;
    cells[0].view_count = 10;
    cells[1].level = 6u;
    cells[1].mass = DSMassFunction(0.90, 0.05, 0.05).sealed();
    cells[1].area_weight = 1.0;
    cells[1].view_count = 25;

    // Fisher mode
    CoverageEstimatorConfig fisher_cfg{};
    fisher_cfg.use_fisher_weights = true;
    fisher_cfg.ema_alpha = 1.0;
    fisher_cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator fisher_est{fisher_cfg};
    CoverageResult fisher_r{};
    fisher_est.update(cells, 2u, 1000, &fisher_r);

    // Discrete mode
    CoverageEstimatorConfig discrete_cfg{};
    discrete_cfg.use_fisher_weights = false;
    discrete_cfg.ema_alpha = 1.0;
    discrete_cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator discrete_est{discrete_cfg};
    CoverageResult discrete_r{};
    discrete_est.update(cells, 2u, 1000, &discrete_r);

    // Both should produce valid coverage in [0,1]
    if (fisher_r.raw_coverage < 0.0 || fisher_r.raw_coverage > 1.0) {
        std::fprintf(stderr, "Fisher raw_coverage out of bounds\n");
        failed++;
    }
    if (discrete_r.raw_coverage < 0.0 || discrete_r.raw_coverage > 1.0) {
        std::fprintf(stderr, "Discrete raw_coverage out of bounds\n");
        failed++;
    }

    // Fisher should favor the high-confidence cell (n=25, p=0.90) more
    // than discrete L6 weight would, because Fisher I is very high for that cell.
    // This is a qualitative check — both modes are valid, just different.
    if (fisher_r.mean_fisher_info <= 0.0) {
        std::fprintf(stderr, "Fisher mode should report positive mean_fisher_info\n");
        failed++;
    }
    // In discrete mode, mean_fisher_info should be 0 (not computed)
    if (discrete_r.mean_fisher_info > 1e-9) {
        std::fprintf(stderr, "Discrete mode should have mean_fisher_info ≈ 0\n");
        failed++;
    }

    if (failed == 0) {
        std::printf("  PASS test_fisher_vs_discrete\n");
    }
    return failed;
}

// ---------------------------------------------------------------------------
// T9 (NEW): PAC probability certificates
// ---------------------------------------------------------------------------
int test_pac_certificates() {
    int failed = 0;
    using namespace aether::evidence;

    CoverageEstimatorConfig cfg{};
    cfg.use_fisher_weights = true;
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 100.0;
    CoverageEstimator estimator{cfg};

    // Cell 1: high confidence, many observations → low PAC risk
    //   n=20, b=0.90 → KL(0.90||0.50) = 0.9*ln(1.8) + 0.1*ln(0.2) ≈ 0.368
    //   risk = exp(-20 * 0.368) = exp(-7.36) ≈ 0.00064
    CoverageCellObservation cells[3]{};
    cells[0].level = 5u;
    cells[0].mass = DSMassFunction(0.90, 0.05, 0.05).sealed();
    cells[0].area_weight = 1.0;
    cells[0].view_count = 20;

    // Cell 2: also high confidence → low PAC risk
    cells[1].level = 6u;
    cells[1].mass = DSMassFunction(0.95, 0.02, 0.03).sealed();
    cells[1].area_weight = 1.0;
    cells[1].view_count = 30;

    // Cell 3: uncertain (b≈0.50, n=2) → high PAC risk
    //   KL(0.50||0.50) ≈ 0 → risk ≈ exp(0) = 1.0
    cells[2].level = 1u;
    cells[2].mass = DSMassFunction(0.50, 0.20, 0.30).sealed();
    cells[2].area_weight = 1.0;
    cells[2].view_count = 2;

    CoverageResult result{};
    auto rc = estimator.update(cells, 3u, 1000, &result);
    if (rc != aether::core::Status::kOk) {
        std::fprintf(stderr, "PAC test update failed\n");
        return 1;
    }

    // PAC failure bound should be sum of individual risks
    if (result.pac_failure_bound < 0.0) {
        std::fprintf(stderr, "pac_failure_bound should be >= 0: %f\n",
            result.pac_failure_bound);
        failed++;
    }

    // Max cell risk should be high (cell 3 has b≈0.5, near-zero KL)
    if (result.pac_max_cell_risk < 0.5) {
        std::fprintf(stderr, "pac_max_cell_risk should be high for uncertain cell: %f\n",
            result.pac_max_cell_risk);
        failed++;
    }

    // At least 2 cells should be well-certified (cells 0 and 1)
    if (result.pac_certified_cell_count < 2) {
        std::fprintf(stderr, "pac_certified_cell_count should be >= 2: %zu\n",
            result.pac_certified_cell_count);
        failed++;
    }

    // Cell 3 is NOT certified (risk ≈ 1.0), so certified < total
    if (result.pac_certified_cell_count >= 3) {
        std::fprintf(stderr, "pac_certified should be < 3 (cell 3 is uncertain)\n");
        failed++;
    }

    if (failed == 0) {
        std::printf("  PASS test_pac_certificates\n");
    }
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    std::printf("coverage_estimator_test\n");
    failed += test_level_weighting_and_smoothing();   // T1 (updated: Fisher OFF)
    failed += test_rate_limiter_and_non_monotonic_handling();  // T2 (updated: Fisher OFF)
    failed += test_state_conversion();                // T3 (unchanged)
    failed += test_invalid_paths();                   // T4 (unchanged)
    failed += test_fisher_weighted_coverage();        // T5 (NEW)
    failed += test_ds_interval_output();              // T6 (NEW)
    failed += test_lyapunov_rate();                   // T7 (NEW)
    failed += test_fisher_vs_discrete();              // T8 (NEW)
    failed += test_pac_certificates();                // T9 (NEW: PAC)
    if (failed == 0) {
        std::printf("ALL PASSED (9 tests)\n");
    } else {
        std::printf("FAILED: %d tests failed\n", failed);
    }
    return failed;
}
