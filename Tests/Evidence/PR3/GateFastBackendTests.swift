//
// GateFastBackendTests.swift
// Aether3D
//
// PR3 - Fast Backend Error Bounds Tests
//

import XCTest
@testable import Aether3DCore

final class GateFastBackendTests: XCTestCase {

    func testErrorBounds() {
        // Force Fast backend (for benchmark/shadow only)
        let context = TierContext.forBenchmark  // Fast/LUT

        // Maximum allowed error (in quantized units)
        // 0.0001 in [0,1] = 100_000_000 in Q01 scale
        let maxErrorQ: Int64 = 100_000_000

        let testCases: [(input: Double, expected: Double)] = [
            (-8.0, StableLogistic.sigmoid(-8.0)),
            (0.0, StableLogistic.sigmoid(0.0)),
            (8.0, StableLogistic.sigmoid(8.0))
        ]

        for (input, expected) in testCases {
            let actual = PRMath.sigmoid(input, context: context)
            let expectedQ = QuantizerQ01.quantize(expected)
            let actualQ = QuantizerQ01.quantize(actual)
            let error = abs(actualQ - expectedQ)

            // Error bound check (not exact match)
            XCTAssertLessThanOrEqual(
                error,
                maxErrorQ,
                "LUT error \(error) exceeds bound \(maxErrorQ) for input \(input)"
            )
        }
    }

    func testMonotonicity() {
        let context = TierContext.forBenchmark

        // Test that sigmoid is monotonically increasing
        var previousValue = 0.0
        for i in stride(from: -10.0, through: 10.0, by: 0.1) {
            let value = PRMath.sigmoid(i, context: context)
            XCTAssertGreaterThanOrEqual(
                value,
                previousValue,
                "Monotonicity violated at x=\(i)"
            )
            previousValue = value
        }
    }

    func testStability() {
        let context = TierContext.forBenchmark

        // Test extreme inputs don't produce NaN/Inf
        let extremeInputs: [Double] = [
            -1000, -100, -10, -1, -0.001,
            0, 0.001, 1, 10, 100, 1000,
            Double.nan, Double.infinity, -Double.infinity
        ]

        for x in extremeInputs {
            let value = PRMath.sigmoid(x, context: context)
            XCTAssertTrue(value.isFinite, "Non-finite result for x=\(x)")
            XCTAssertGreaterThanOrEqual(value, 0.0, "Below 0 for x=\(x)")
            XCTAssertLessThanOrEqual(value, 1.0, "Above 1 for x=\(x)")
        }
    }
}
