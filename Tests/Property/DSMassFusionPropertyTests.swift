// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DSMassFusionPropertyTests.swift
// Aether3D
//
// PR6 Evidence Grid System - D-S Mass Fusion Property-Based Tests
//

import XCTest
@testable import Aether3DCore

final class DSMassFusionPropertyTests: XCTestCase {
    
    /// Generate random mass function with O+F+U=1.0
    private func randomMass() -> DSMassFunction {
        let o = Double.random(in: 0...1)
        let f = Double.random(in: 0...(1.0 - o))
        let u = 1.0 - o - f
        return DSMassFunction(occupied: o, free: f, unknown: u)
    }
    
    func testRandomMassesSumToOne() {
        // Generate 100 random masses, verify all preserve invariant
        for _ in 0..<100 {
            let mass = randomMass()
            XCTAssertTrue(mass.verifyInvariant(), "Random mass must satisfy invariant")
            let sum = mass.occupied + mass.free + mass.unknown
            XCTAssertEqual(sum, 1.0, accuracy: EvidenceConstants.dsEpsilon)
        }
    }
    
    func testCombinedMassesSumToOne() {
        // Generate 100 random pairs, combine them, verify result sums to 1
        for _ in 0..<100 {
            let m1 = randomMass()
            let m2 = randomMass()
            
            let (combined, _) = DSMassFusion.dempsterCombine(m1, m2)
            
            XCTAssertTrue(combined.verifyInvariant(), "Combined mass must satisfy invariant")
            let sum = combined.occupied + combined.free + combined.unknown
            XCTAssertEqual(sum, 1.0, accuracy: EvidenceConstants.dsEpsilon)
        }
    }
    
    func testConflictKBounded() {
        // Generate 100 random pairs, verify conflict K ∈ [0, 1)
        for _ in 0..<100 {
            let m1 = randomMass()
            let m2 = randomMass()
            
            let (_, conflict) = DSMassFusion.dempsterCombine(m1, m2)
            
            XCTAssertGreaterThanOrEqual(conflict, 0.0, "Conflict K must be >= 0")
            XCTAssertLessThan(conflict, 1.0, "Conflict K must be < 1")
        }
    }
    
    func testReliabilityIdentityAtR1() {
        // r=1.0 should be identity for all random masses
        for _ in 0..<100 {
            let mass = randomMass()
            let discounted = DSMassFusion.discount(mass: mass, reliability: 1.0)
            
            XCTAssertEqual(discounted.occupied, mass.occupied, accuracy: EvidenceConstants.dsEpsilon)
            XCTAssertEqual(discounted.free, mass.free, accuracy: EvidenceConstants.dsEpsilon)
            XCTAssertEqual(discounted.unknown, mass.unknown, accuracy: EvidenceConstants.dsEpsilon)
        }
    }
    
    func testDempsterCombineCommutative() {
        // combine(a,b) ≈ combine(b,a) within epsilon
        for _ in 0..<100 {
            let m1 = randomMass()
            let m2 = randomMass()
            
            let (combined1, _) = DSMassFusion.dempsterCombine(m1, m2)
            let (combined2, _) = DSMassFusion.dempsterCombine(m2, m1)
            
            XCTAssertEqual(combined1.occupied, combined2.occupied, accuracy: EvidenceConstants.dsEpsilon)
            XCTAssertEqual(combined1.free, combined2.free, accuracy: EvidenceConstants.dsEpsilon)
            XCTAssertEqual(combined1.unknown, combined2.unknown, accuracy: EvidenceConstants.dsEpsilon)
        }
    }
}
