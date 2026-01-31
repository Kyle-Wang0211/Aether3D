//
// SmartAntiBoostSmootherTests.swift
// Aether3D
//
// PR3 - Smart Anti-Boost Smoother Tests
//

import XCTest
@testable import Aether3DCore

final class SmartAntiBoostSmootherTests: XCTestCase {

    func testConditionalAntiBoost() {
        let config = SmootherConfig(
            jitterBand: 0.05,
            antiBoostFactor: 0.3,
            normalImproveFactor: 0.7,
            degradeFactor: 1.0,
            maxConsecutiveInvalid: 5,
            worstCaseFallback: 0.0
        )
        let smoother = SmartAntiBoostSmoother(config: config)

        // Add normal improvement (within jitter band)
        let value1 = smoother.addAndSmooth(0.5)
        let value2 = smoother.addAndSmooth(0.52)  // Small change

        // Should use median (stable), not anti-boost
        XCTAssertLessThan(abs(value2 - value1), 0.1)

        // Add suspicious jump (> 3x jitter band)
        let value3 = smoother.addAndSmooth(0.7)  // Large jump

        // Should use anti-boost (slower improvement)
        XCTAssertGreaterThan(value3, value2)
        XCTAssertLessThan(value3, 0.7)  // Anti-boosted
    }

    func testNormalImprovementFastRecovery() {
        let config = SmootherConfig(
            jitterBand: 0.05,
            antiBoostFactor: 0.3,
            normalImproveFactor: 0.7,
            degradeFactor: 1.0,
            maxConsecutiveInvalid: 5,
            worstCaseFallback: 0.0
        )
        let smoother = SmartAntiBoostSmoother(config: config)

        smoother.addAndSmooth(0.3)
        let value1 = smoother.addAndSmooth(0.35)  // Normal improvement

        // Should recover faster than anti-boost
        XCTAssertGreaterThan(value1, 0.32)  // Faster than 0.3 + 0.05 * 0.3
    }

    func testKConsecutiveInvalid() {
        let config = SmootherConfig(
            jitterBand: 0.05,
            antiBoostFactor: 0.3,
            normalImproveFactor: 0.7,
            degradeFactor: 1.0,
            maxConsecutiveInvalid: 3,  // Low threshold for test
            worstCaseFallback: 0.0
        )
        let smoother = SmartAntiBoostSmoother(config: config)

        smoother.addAndSmooth(0.5)
        smoother.addAndSmooth(Double.nan)  // Invalid 1
        smoother.addAndSmooth(Double.nan)  // Invalid 2
        smoother.addAndSmooth(Double.nan)  // Invalid 3

        let result = smoother.addAndSmooth(Double.nan)  // Invalid 4 (exceeds threshold)
        XCTAssertEqual(result, config.worstCaseFallback)
    }

    func testNoStuckAtOldGood() {
        let config = SmootherConfig.default
        let smoother = SmartAntiBoostSmoother(config: config)

        // Add good value
        smoother.addAndSmooth(0.8)

        // Add bad value
        let badValue = smoother.addAndSmooth(0.2)

        // Should degrade immediately (not stuck at 0.8)
        XCTAssertLessThan(badValue, 0.8)
    }
}
