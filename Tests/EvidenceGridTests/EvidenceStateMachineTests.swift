// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceStateMachineTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence State Machine Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceStateMachineTests: XCTestCase {
    
    func testGoldenPathS0ToS5() {
        let stateMachine = EvidenceStateMachine()
        
        // S0: Very low coverage
        var coverage = CoverageResult(
            coveragePercentage: 0.05,
            breakdownCounts: [100, 0, 0, 0, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        var state = stateMachine.evaluate(coverage: coverage)
        XCTAssertEqual(state, .black) // S0
        
        // S1: Low coverage
        coverage = CoverageResult(
            coveragePercentage: 0.15,
            breakdownCounts: [50, 50, 0, 0, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage)
        XCTAssertEqual(state, .darkGray) // S1
        
        // S2: Medium coverage
        coverage = CoverageResult(
            coveragePercentage: 0.35,
            breakdownCounts: [0, 50, 50, 0, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage)
        XCTAssertEqual(state, .darkGray) // S2
        
        // S3: Medium-high coverage
        coverage = CoverageResult(
            coveragePercentage: 0.60,
            breakdownCounts: [0, 0, 50, 50, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage)
        XCTAssertEqual(state, .lightGray) // S3
        
        // S4: High coverage
        coverage = CoverageResult(
            coveragePercentage: 0.80,
            breakdownCounts: [0, 0, 0, 50, 50, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage)
        XCTAssertEqual(state, .white) // S4
        
        // S5: Very high coverage + soft evidence
        var evidenceSnapshot = EvidenceState(
            patches: [:],
            gateDisplay: 0.0,
            softDisplay: 0.80,  // High soft evidence
            lastTotalDisplay: 0.0,
            exportedAtMs: MonotonicClock.nowMs(),
            schemaVersion: "3.0"
        )
        coverage = CoverageResult(
            coveragePercentage: 0.90,  // Above whiteThreshold (0.88)
            breakdownCounts: [0, 0, 0, 0, 0, 50, 50],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage, evidenceSnapshot: evidenceSnapshot)
        XCTAssertEqual(state, .original) // S5
    }
    
    func testMonotonicNeverRetreats() {
        let stateMachine = EvidenceStateMachine()
        
        // Start at S3
        var coverage = CoverageResult(
            coveragePercentage: 0.60,
            breakdownCounts: [0, 0, 0, 100, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        var state = stateMachine.evaluate(coverage: coverage)
        XCTAssertEqual(state, .lightGray) // S3
        
        // Try to go back to S2 (lower coverage)
        coverage = CoverageResult(
            coveragePercentage: 0.30,
            breakdownCounts: [0, 50, 50, 0, 0, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage)
        
        // Should stay at S3 (monotonic)
        XCTAssertEqual(state, .lightGray) // Still S3, not S2
    }
    
    func testS5RequiresWhiteThresholdAndSoftEvidence() {
        let stateMachine = EvidenceStateMachine()
        
        // High coverage but low soft evidence
        var evidenceSnapshot = EvidenceState(
            patches: [:],
            gateDisplay: 0.0,
            softDisplay: 0.50,  // Below s5MinSoftEvidence (0.75)
            lastTotalDisplay: 0.0,
            exportedAtMs: MonotonicClock.nowMs(),
            schemaVersion: "3.0"
        )
        var coverage = CoverageResult(
            coveragePercentage: 0.90,  // Above whiteThreshold
            breakdownCounts: [0, 0, 0, 0, 0, 50, 50],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        var state = stateMachine.evaluate(coverage: coverage, evidenceSnapshot: evidenceSnapshot)
        XCTAssertNotEqual(state, .original) // Not S5 (low soft evidence)
        
        // High soft evidence but low coverage
        evidenceSnapshot = EvidenceState(
            patches: [:],
            gateDisplay: 0.0,
            softDisplay: 0.80,  // Above s5MinSoftEvidence
            lastTotalDisplay: 0.0,
            exportedAtMs: MonotonicClock.nowMs(),
            schemaVersion: "3.0"
        )
        coverage = CoverageResult(
            coveragePercentage: 0.80,  // Below whiteThreshold (0.88)
            breakdownCounts: [0, 0, 0, 0, 50, 0, 0],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage, evidenceSnapshot: evidenceSnapshot)
        XCTAssertNotEqual(state, .original) // Not S5 (low coverage)
        
        // Both conditions met: S5
        evidenceSnapshot = EvidenceState(
            patches: [:],
            gateDisplay: 0.0,
            softDisplay: 0.80,  // Above s5MinSoftEvidence
            lastTotalDisplay: 0.0,
            exportedAtMs: MonotonicClock.nowMs(),
            schemaVersion: "3.0"
        )
        coverage = CoverageResult(
            coveragePercentage: 0.90,  // Above whiteThreshold
            breakdownCounts: [0, 0, 0, 0, 0, 50, 50],
            weightedSumComponents: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            excludedAreaSqM: 0.0
        )
        state = stateMachine.evaluate(coverage: coverage, evidenceSnapshot: evidenceSnapshot)
        XCTAssertEqual(state, .original) // S5
    }
}
