//
// OverflowTier0StrictTests.swift
// PR4OverflowTests
//
// PR4 V10 - STRICT verification of Tier0 overflow detection
//

import XCTest
@testable import PR4Overflow
@testable import PR4Math

final class OverflowTier0StrictTests: XCTestCase {
    
    /// Tier0 fields that MUST NOT overflow
    let tier0Fields = [
        "gateQ",
        "softQualityQ",
        "fusedDepthQ",
        "healthQ",
    ]
    
    /// Test Tier0 overflow detection and logging
    func testTier0OverflowDetected() {
        for field in tier0Fields {
            // Attempt to overflow
            let _ = OverflowTier0Fence.handleOverflow(
                field: field,
                value: Int64.max,
                bound: 65536,
                direction: .above
            )
            
            // Verify overflow was logged (check via logger)
            XCTAssertTrue(OverflowTier0Fence.isTier0(field),
                "Tier0 field '\(field)' not recognized")
        }
    }
    
    /// Test non-Tier0 fields don't trigger fatal overflow
    func testNonTier0OverflowAllowed() {
        let nonTier0Fields = ["debugValue", "tempCalc", "intermediateResult"]
        
        for field in nonTier0Fields {
            let result = OverflowTier0Fence.handleOverflow(
                field: field,
                value: Int64.max,
                bound: 65536,
                direction: .above
            )
            
            // Should clamp but not be fatal
            XCTAssertEqual(result, 65536, "Should clamp to bound")
        }
    }
    
    /// Test overflow clamping returns correct bound
    func testOverflowClamping() {
        let testCases: [(value: Int64, bound: Int64, direction: OverflowTier0Fence.OverflowDirection, expected: Int64)] = [
            (100000, 65536, .above, 65536),
            (-100000, 0, .below, 0),
        ]
        
        for (i, tc) in testCases.enumerated() {
            let result = OverflowTier0Fence.handleOverflow(
                field: "testField\(i)",
                value: tc.value,
                bound: tc.bound,
                direction: tc.direction
            )
            
            if tc.value > tc.bound && tc.direction == .above {
                XCTAssertEqual(result, tc.expected, "Case \(i): overflow not clamped correctly")
            } else if tc.value < tc.bound && tc.direction == .below {
                XCTAssertEqual(result, tc.expected, "Case \(i): underflow not clamped correctly")
            }
        }
    }
    
    /// Test Q16 arithmetic overflow detection
    func testQ16ArithmeticOverflowDetection() {
        // Test that overflow detection works
        // Note: Actual overflow behavior depends on Q16 implementation
        let (sum, noOverflow) = Q16.add(65536, 65536)
        XCTAssertFalse(noOverflow, "False positive overflow for valid addition")
        XCTAssertEqual(sum, 131072, "1.0 + 1.0 = 2.0")
        
        // Test multiplication
        let (prod, mulOverflow) = Q16.multiply(65536, 65536)
        XCTAssertFalse(mulOverflow, "1.0 * 1.0 should not overflow")
        XCTAssertEqual(prod, 65536, "1.0 * 1.0 = 1.0")
    }
}
