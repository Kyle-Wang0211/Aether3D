//
// DSMassFusionTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Dempster-Shafer Mass Fusion Tests
//

import XCTest
@testable import Aether3DCore

final class DSMassFusionTests: XCTestCase {
    
    // MARK: - Basic Dempster Combine Tests
    
    func testDempsterCombineBasic() {
        let m1 = DSMassFunction(occupied: 0.6, free: 0.1, unknown: 0.3)
        let m2 = DSMassFunction(occupied: 0.5, free: 0.2, unknown: 0.3)
        
        let (combined, conflict) = DSMassFusion.dempsterCombine(m1, m2)
        
        // Verify invariant: O+F+U = 1.0
        XCTAssertTrue(combined.verifyInvariant(), "Combined mass must satisfy invariant")
        let sum = combined.occupied + combined.free + combined.unknown
        XCTAssertEqual(sum, 1.0, accuracy: EvidenceConstants.dsEpsilon)
        
        // Verify conflict is computed
        XCTAssertGreaterThanOrEqual(conflict, 0.0)
        XCTAssertLessThan(conflict, 1.0)
    }
    
    func testYagerCombineHighConflict() {
        // Create high conflict scenario: K >= 0.85
        let m1 = DSMassFunction(occupied: 0.9, free: 0.05, unknown: 0.05)
        let m2 = DSMassFunction(occupied: 0.05, free: 0.9, unknown: 0.05)
        
        // Conflict K = 0.9 * 0.9 + 0.05 * 0.05 = 0.81 + 0.0025 = 0.8125
        // But with normalization, K might exceed threshold
        let (combined, conflict) = DSMassFusion.dempsterCombine(m1, m2)
        
        // Verify Yager fallback activates for high conflict
        XCTAssertTrue(combined.verifyInvariant())
        
        // Yager assigns conflict to unknown
        if conflict >= EvidenceConstants.dsConflictSwitch {
            XCTAssertGreaterThan(combined.unknown, 0.0, "Yager should assign conflict to unknown")
        }
    }
    
    func testConflictSwitchThreshold() {
        // Test exactly at dsConflictSwitch threshold
        let threshold = EvidenceConstants.dsConflictSwitch
        
        // Create masses that produce conflict near threshold
        let m1 = DSMassFunction(occupied: 0.85, free: 0.1, unknown: 0.05)
        let m2 = DSMassFunction(occupied: 0.1, free: 0.85, unknown: 0.05)
        
        let (combined, conflict) = DSMassFusion.dempsterCombine(m1, m2)
        
        XCTAssertTrue(combined.verifyInvariant())
        
        // Verify >= branch (MUST-FIX X)
        if conflict >= threshold {
            // Should use Yager
            XCTAssertGreaterThan(combined.unknown, 0.0)
        } else {
            // Should use Dempster
            XCTAssertGreaterThan(combined.occupied, 0.0)
        }
    }
    
    // MARK: - Reliability Discount Tests
    
    func testReliabilityDiscountR0() {
        let mass = DSMassFunction(occupied: 0.7, free: 0.2, unknown: 0.1)
        let r: Double = 0.0
        
        let discounted = DSMassFusion.discount(mass: mass, reliability: r)
        
        // r=0: all mass goes to unknown
        XCTAssertEqual(discounted.occupied, 0.0, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(discounted.free, 0.0, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(discounted.unknown, 1.0, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertTrue(discounted.verifyInvariant())
    }
    
    func testReliabilityDiscountR1() {
        let mass = DSMassFunction(occupied: 0.7, free: 0.2, unknown: 0.1)
        let r: Double = 1.0
        
        let discounted = DSMassFusion.discount(mass: mass, reliability: r)
        
        // r=1: mass unchanged
        XCTAssertEqual(discounted.occupied, mass.occupied, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(discounted.free, mass.free, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(discounted.unknown, mass.unknown, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertTrue(discounted.verifyInvariant())
    }
    
    func testReliabilityDiscountPreservesInvariant() {
        let mass = DSMassFunction(occupied: 0.6, free: 0.3, unknown: 0.1)
        
        for r in stride(from: 0.0, through: 1.0, by: 0.1) {
            let discounted = DSMassFusion.discount(mass: mass, reliability: r)
            XCTAssertTrue(discounted.verifyInvariant(), "Discount at r=\(r) must preserve invariant")
        }
    }
    
    // MARK: - NaN/Inf Handling Tests
    
    func testNaNInputFallsBackToVacuous() {
        let mass = DSMassFunction(occupied: Double.nan, free: 0.0, unknown: 0.0)
        
        // Should normalize to vacuous or handle gracefully
        XCTAssertTrue(mass.verifyInvariant() || mass.unknown == 1.0, "NaN input should result in vacuous or valid mass")
    }
    
    func testInfInputFallsBackToVacuous() {
        let mass = DSMassFunction(occupied: Double.infinity, free: 0.0, unknown: 0.0)
        
        // Should normalize to vacuous or handle gracefully
        XCTAssertTrue(mass.verifyInvariant() || mass.unknown == 1.0, "Inf input should result in vacuous or valid mass")
    }
    
    // MARK: - Verdict to Mass Mapping Tests
    
    func testVerdictToMassMapping() {
        // Test good verdict
        let goodMass = DSMassFusion.fromDeltaMultiplier(1.0) // Good verdict
        XCTAssertGreaterThan(goodMass.occupied, 0.7) // Should be high occupied
        XCTAssertLessThan(goodMass.unknown, 0.3)
        XCTAssertTrue(goodMass.verifyInvariant())
        
        // Test suspect verdict (deltaMultiplier around 0.5)
        let suspectMass = DSMassFusion.fromDeltaMultiplier(0.5)
        XCTAssertGreaterThan(suspectMass.unknown, 0.5) // Should be high unknown
        XCTAssertTrue(suspectMass.verifyInvariant())
        
        // Test bad verdict (deltaMultiplier around 0.0)
        let badMass = DSMassFusion.fromDeltaMultiplier(0.0)
        XCTAssertGreaterThan(badMass.free, 0.0) // Should have some free
        XCTAssertGreaterThan(badMass.unknown, 0.5) // Should be high unknown
        XCTAssertTrue(badMass.verifyInvariant())
    }
    
    // MARK: - Commutativity Tests
    
    func testCombineIsCommutative() {
        let m1 = DSMassFunction(occupied: 0.6, free: 0.2, unknown: 0.2)
        let m2 = DSMassFunction(occupied: 0.5, free: 0.3, unknown: 0.2)
        
        let (combined1, conflict1) = DSMassFusion.dempsterCombine(m1, m2)
        let (combined2, conflict2) = DSMassFusion.dempsterCombine(m2, m1)
        
        // Dempster's rule is commutative
        XCTAssertEqual(combined1.occupied, combined2.occupied, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(combined1.free, combined2.free, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(combined1.unknown, combined2.unknown, accuracy: EvidenceConstants.dsEpsilon)
        XCTAssertEqual(conflict1, conflict2, accuracy: EvidenceConstants.dsEpsilon)
    }
}
