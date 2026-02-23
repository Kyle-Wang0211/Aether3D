// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceStateMachineTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence State Machine Tests
// Updated for information-theoretic S5 certification (6-gate).
//

import XCTest
@testable import Aether3DCore

final class EvidenceStateMachineTests: XCTestCase {

    /// Helper: create a coverage result with only coveragePercentage set (for S0-S4 tests).
    /// beliefCoverage defaults to 0.0 → Swift evaluate() falls back to coveragePercentage.
    private func coverageOnly(_ pct: Double) -> CoverageResult {
        CoverageResult(
            coveragePercentage: pct,
            breakdownCounts: [0, 0, 0, 0, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
    }

    /// Helper: create a fully S5-certified coverage result with all info-theoretic fields.
    private func s5CertifiedCoverage(
        beliefCov: Double = 0.90,
        plCov: Double = 0.95,
        uncWidth: Double = 0.05,
        highObs: Double = 0.35,
        lyapRate: Double = 0.03
    ) -> CoverageResult {
        CoverageResult(
            coveragePercentage: beliefCov,
            breakdownCounts: [0, 0, 0, 0, 0, 50, 50],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0,
            beliefCoverage: beliefCov,
            plausibilityCoverage: plCov,
            uncertaintyWidth: uncWidth,
            highObservationRatio: highObs,
            lyapunovRate: lyapRate,
            meanFisherInfo: 100.0
        )
    }

    /// Helper: create a DimensionalScoreSet with all dimensions at the same value.
    private func uniformDims(_ value: Double) -> DimensionalScoreSet {
        DimensionalScoreSet(
            dim1_viewGain: value,
            dim2_geometryGain: value,
            dim3_depthQuality: value,
            dim4_semanticConsistency: value,
            dim5_errorTypeScore: value,
            dim6_basicGain: value,
            dim7_provenanceContribution: value,
            dim8_coverageTrackerScore: value,
            dim9_resolutionQuality: value,
            dim10_viewDiversity: value
        )
    }

    func testGoldenPathS0ToS5() {
        let stateMachine = EvidenceStateMachine()

        // S0: Very low coverage
        var state = stateMachine.evaluate(coverage: coverageOnly(0.05))
        XCTAssertEqual(state, .black) // S0

        // S1: Low coverage
        state = stateMachine.evaluate(coverage: coverageOnly(0.15))
        XCTAssertEqual(state, .darkGray) // S1

        // S2: Medium coverage (same visual as S1)
        state = stateMachine.evaluate(coverage: coverageOnly(0.35))
        XCTAssertEqual(state, .darkGray) // S2

        // S3: Medium-high coverage
        state = stateMachine.evaluate(coverage: coverageOnly(0.60))
        XCTAssertEqual(state, .lightGray) // S3

        // S4: High coverage
        state = stateMachine.evaluate(coverage: coverageOnly(0.80))
        XCTAssertEqual(state, .white) // S4

        // S5: All 6 information-theoretic gates satisfied
        state = stateMachine.evaluate(
            coverage: s5CertifiedCoverage(),
            dimensionalScores: uniformDims(0.80)
        )
        XCTAssertEqual(state, .original) // S5
    }

    func testMonotonicNeverRetreats() {
        let stateMachine = EvidenceStateMachine()

        // Start at S3
        var state = stateMachine.evaluate(coverage: coverageOnly(0.60))
        XCTAssertEqual(state, .lightGray) // S3

        // Try to go back to S2 (lower coverage)
        state = stateMachine.evaluate(coverage: coverageOnly(0.30))

        // Should stay at S3 (monotonic)
        XCTAssertEqual(state, .lightGray) // Still S3, not S2
    }

    func testS5RequiresSixGateCertification() {
        let stateMachine = EvidenceStateMachine()

        // High coverage but no dimensional scores → Choquet = 0 → S4 only
        let highCoverage = s5CertifiedCoverage()
        var state = stateMachine.evaluate(coverage: highCoverage)
        XCTAssertNotEqual(state, .original) // Not S5 (no dim scores → Choquet fails)

        // Reset for clean test
        stateMachine.reset()

        // High coverage + dim scores but low observation ratio → S4
        let lowObsCoverage = s5CertifiedCoverage(highObs: 0.20)
        state = stateMachine.evaluate(
            coverage: lowObsCoverage,
            dimensionalScores: uniformDims(0.80)
        )
        XCTAssertNotEqual(state, .original) // Not S5 (high_obs too low)

        stateMachine.reset()

        // High coverage + dim scores but not converged → S4
        let notConvergedCoverage = s5CertifiedCoverage(lyapRate: 0.20)
        state = stateMachine.evaluate(
            coverage: notConvergedCoverage,
            dimensionalScores: uniformDims(0.80)
        )
        XCTAssertNotEqual(state, .original) // Not S5 (lyapunov rate too high)

        stateMachine.reset()

        // All 6 gates satisfied → S5
        state = stateMachine.evaluate(
            coverage: s5CertifiedCoverage(),
            dimensionalScores: uniformDims(0.80)
        )
        XCTAssertEqual(state, .original) // S5
    }
}
