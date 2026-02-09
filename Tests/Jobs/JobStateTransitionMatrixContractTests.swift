// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5 (PR1 C-Class: +1 state CAPACITY_SATURATED)
// States: 9 | Transitions: 14 | FailureReasons: 14 | CancelReasons: 2
// ============================================================================

import XCTest
@testable import Aether3DCore

/// Transition matrix contract tests
/// 
/// These tests enforce that ContractConstants values stay consistent with actual enum counts
/// and transition sets. This prevents silent drift in the state machine contract.
final class JobStateTransitionMatrixContractTests: XCTestCase {
    
    // MARK: - Contract Consistency Tests
    
    func testStateCountMatchesEnumCount() {
        XCTAssertEqual(
            ContractConstants.STATE_COUNT,
            JobState.allCases.count,
            "STATE_COUNT must equal JobState.allCases.count"
        )
    }
    
    func testTotalStatePairsMatchesMatrixSize() {
        let expectedPairs = JobState.allCases.count * JobState.allCases.count
        XCTAssertEqual(
            ContractConstants.TOTAL_STATE_PAIRS,
            expectedPairs,
            "TOTAL_STATE_PAIRS must equal count * count"
        )
    }
    
    func testLegalTransitionCountMatchesActualTransitions() {
        // Count actual legal transitions by testing all pairs
        var actualLegalCount = 0
        for from in JobState.allCases {
            for to in JobState.allCases {
                if JobStateMachine.canTransition(from: from, to: to) {
                    actualLegalCount += 1
                }
            }
        }
        
        XCTAssertEqual(
            ContractConstants.LEGAL_TRANSITION_COUNT,
            actualLegalCount,
            "LEGAL_TRANSITION_COUNT must match actual legal transitions"
        )
    }
    
    func testIllegalTransitionCountMatchesComputedValue() {
        let expectedIllegal = ContractConstants.TOTAL_STATE_PAIRS - ContractConstants.LEGAL_TRANSITION_COUNT
        XCTAssertEqual(
            ContractConstants.ILLEGAL_TRANSITION_COUNT,
            expectedIllegal,
            "ILLEGAL_TRANSITION_COUNT must equal TOTAL_STATE_PAIRS - LEGAL_TRANSITION_COUNT"
        )
    }
    
    func testCapacitySaturatedIsInStateList() {
        XCTAssertTrue(
            JobState.allCases.contains(.capacitySaturated),
            "capacitySaturated must be included in JobState.allCases"
        )
    }
    
    // MARK: - Specific Transition Tests
    
    func testProcessingToCapacitySaturatedIsLegal() {
        XCTAssertTrue(
            JobStateMachine.canTransition(from: .processing, to: .capacitySaturated),
            "PROCESSING -> CAPACITY_SATURATED must be a legal transition"
        )
    }
    
    func testCompletedToProcessingIsIllegal() {
        XCTAssertFalse(
            JobStateMachine.canTransition(from: .completed, to: .processing),
            "COMPLETED -> PROCESSING must be illegal (deterministic test case)"
        )
    }
}
