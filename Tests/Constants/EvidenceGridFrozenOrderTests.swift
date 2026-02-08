//
// EvidenceGridFrozenOrderTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Frozen Order Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceGridFrozenOrderTests: XCTestCase {
    
    func testEvidenceConfidenceLevelFrozenOrder() {
        // Verify L0.rawValue=0, L1=1, ..., L6=6
        XCTAssertEqual(EvidenceConfidenceLevel.L0.rawValue, 0)
        XCTAssertEqual(EvidenceConfidenceLevel.L1.rawValue, 1)
        XCTAssertEqual(EvidenceConfidenceLevel.L2.rawValue, 2)
        XCTAssertEqual(EvidenceConfidenceLevel.L3.rawValue, 3)
        XCTAssertEqual(EvidenceConfidenceLevel.L4.rawValue, 4)
        XCTAssertEqual(EvidenceConfidenceLevel.L5.rawValue, 5)
        XCTAssertEqual(EvidenceConfidenceLevel.L6.rawValue, 6)
    }
    
    func testConfidenceLevelCaseCount() {
        // Verify exactly 7 cases (L0-L6)
        let allCases = EvidenceConfidenceLevel.allCases
        XCTAssertEqual(allCases.count, 7, "Must have exactly 7 confidence levels")
    }
}
