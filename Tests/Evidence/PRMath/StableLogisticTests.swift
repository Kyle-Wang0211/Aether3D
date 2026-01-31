//
// StableLogisticTests.swift
// Aether3D
//
// PR3 - Stable Logistic Tests
//

import XCTest
@testable import Aether3DCore

final class StableLogisticTests: XCTestCase {

    func testSigmoidNoNaN() {
        // Test that sigmoid never returns NaN for finite inputs
        let testCases: [Double] = [
            -100, -80, -10, -1, -0.1, 0, 0.1, 1, 10, 80, 100
        ]

        for x in testCases {
            let result = StableLogistic.sigmoid(x)
            XCTAssertFalse(result.isNaN, "sigmoid(\(x)) returned NaN")
            XCTAssertTrue(result.isFinite, "sigmoid(\(x)) returned non-finite")
        }
    }

    func testSigmoidNoInf() {
        // Test that sigmoid never returns Inf
        let testCases: [Double] = [
            -1000, -100, -80, 80, 100, 1000
        ]

        for x in testCases {
            let result = StableLogistic.sigmoid(x)
            XCTAssertTrue(result.isFinite, "sigmoid(\(x)) returned Inf")
        }
    }

    func testSigmoidBoundaryCases() {
        // Test boundary cases
        XCTAssertEqual(StableLogistic.sigmoid(-80.0), 0.0, accuracy: 1e-10)
        XCTAssertEqual(StableLogistic.sigmoid(0.0), 0.5, accuracy: 1e-10)
        XCTAssertEqual(StableLogistic.sigmoid(80.0), 1.0, accuracy: 1e-10)
    }

    func testSigmoidMonotonicity() {
        // Test sigmoid is monotonically increasing
        var previous = -1.0
        for i in stride(from: -10.0, through: 10.0, by: 0.1) {
            let current = StableLogistic.sigmoid(i)
            XCTAssertGreaterThanOrEqual(current, previous, "Monotonicity violated at x=\(i)")
            previous = current
        }
    }

    func testExpSafe() {
        // Test expSafe clamps input
        let result = StableLogistic.expSafe(1000.0)
        XCTAssertTrue(result.isFinite)
        XCTAssertEqual(result, StableLogistic.expSafe(80.0))
    }
}
