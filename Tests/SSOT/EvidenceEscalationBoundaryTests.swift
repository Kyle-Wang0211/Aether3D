//
// EvidenceEscalationBoundaryTests.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - EEB Invariant Tests
//
// Tests must cover complete transition matrix and trigger coverage.
//

import Foundation
import XCTest

@testable import Aether3DCore

final class EvidenceEscalationBoundaryTests: XCTestCase {
    
    // MARK: - Legal Single-Step Escalations
    
    func testL0ToL1Legal() {
        let result = EEBGuard.allows(
            from: .L0,
            to: .L1,
            trigger: .newValidObservation,
            isCrossEpoch: false
        )
        XCTAssertTrue(result)
    }
    
    func testL1ToL2Legal() {
        let result = EEBGuard.allows(
            from: .L1,
            to: .L2,
            trigger: .newBaselineSatisfied,
            isCrossEpoch: false
        )
        XCTAssertTrue(result)
    }
    
    func testL2ToL3CoreLegal() {
        let result = EEBGuard.allows(
            from: .L2,
            to: .L3_core,
            trigger: .newColorStabilitySatisfied,
            isCrossEpoch: false
        )
        XCTAssertTrue(result)
    }
    
    func testL2ToL3StrictLegal() {
        let result = EEBGuard.allows(
            from: .L2,
            to: .L3_strict,
            trigger: .newColorStabilitySatisfied,
            isCrossEpoch: false
        )
        XCTAssertTrue(result)
    }
    
    // MARK: - Illegal Multi-Step Escalations
    
    func testL0ToL2Forbidden() {
        let result = EEBGuard.allows(
            from: .L0,
            to: .L2,
            trigger: .newBaselineSatisfied,
            isCrossEpoch: false
        )
        XCTAssertFalse(result)
    }
    
    func testL0ToL3CoreForbidden() {
        let result = EEBGuard.allows(
            from: .L0,
            to: .L3_core,
            trigger: .newColorStabilitySatisfied,
            isCrossEpoch: false
        )
        XCTAssertFalse(result)
    }
    
    func testL1ToL3StrictForbidden() {
        let result = EEBGuard.allows(
            from: .L1,
            to: .L3_strict,
            trigger: .newColorStabilitySatisfied,
            isCrossEpoch: false
        )
        XCTAssertFalse(result)
    }
    
    // MARK: - Downgrades
    
    func testL2ToL1DowngradeForbidden() {
        let result = EEBGuard.allows(
            from: .L2,
            to: .L1,
            trigger: .newValidObservation,
            isCrossEpoch: false
        )
        XCTAssertFalse(result)
    }
    
    func testL3StrictToL2DowngradeForbidden() {
        let result = EEBGuard.allows(
            from: .L3_strict,
            to: .L2,
            trigger: .newBaselineSatisfied,
            isCrossEpoch: false
        )
        XCTAssertFalse(result)
    }
    
    // MARK: - Cross-Epoch Inheritance
    
    func testEpochMigrationRequiresCrossEpoch() {
        let result = EEBGuard.allows(
            from: .L1,
            to: .L2,
            trigger: .epochMigrationInheritance,
            isCrossEpoch: false
        )
        XCTAssertFalse(result)
    }
    
    func testEpochMigrationCannotInheritL3Core() {
        let result = EEBGuard.allows(
            from: .L2,
            to: .L3_core,
            trigger: .epochMigrationInheritance,
            isCrossEpoch: true
        )
        XCTAssertFalse(result)
    }
    
    func testEpochMigrationCannotInheritL3Strict() {
        let result = EEBGuard.allows(
            from: .L2,
            to: .L3_strict,
            trigger: .epochMigrationInheritance,
            isCrossEpoch: true
        )
        XCTAssertFalse(result)
    }
    
    func testEpochMigrationCanInheritL2() {
        let result = EEBGuard.allows(
            from: .L1,
            to: .L2,
            trigger: .epochMigrationInheritance,
            isCrossEpoch: true
        )
        XCTAssertTrue(result)
    }
    
    // MARK: - Trigger Coverage
    
    func testAllTriggersCovered() {
        // Verify all triggers exist
        let triggers = EEBTrigger.allCases
        XCTAssertTrue(triggers.contains(.newValidObservation))
        XCTAssertTrue(triggers.contains(.newBaselineSatisfied))
        XCTAssertTrue(triggers.contains(.newColorStabilitySatisfied))
        XCTAssertTrue(triggers.contains(.epochMigrationInheritance))
    }
}
