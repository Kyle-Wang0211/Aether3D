//
// EvidenceGridMisuseTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Misuse Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceGridMisuseTests: XCTestCase {
    
    func testInvalidMassSumRenormalized() {
        // Create mass with sum != 1.0
        let invalidMass = DSMassFunction(occupied: 0.5, free: 0.3, unknown: 0.1)  // Sum = 0.9
        
        // Should be renormalized
        XCTAssertTrue(invalidMass.verifyInvariant(), "Invalid mass should be renormalized")
        let sum = invalidMass.occupied + invalidMass.free + invalidMass.unknown
        XCTAssertEqual(sum, 1.0, accuracy: EvidenceConstants.dsEpsilon)
    }
}
