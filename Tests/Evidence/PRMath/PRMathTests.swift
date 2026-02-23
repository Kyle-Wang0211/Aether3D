// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PRMathTests.swift
// Aether3D
//
// PR3 - PRMath Facade Tests
//

import XCTest
@testable import Aether3DCore

final class PRMathTests: XCTestCase {

    func testSigmoidCanonical() {
        let context = TierContext.forTesting  // canonical
        let result = PRMath.sigmoid(0.0, context: context)
        XCTAssertEqual(result, 0.5, accuracy: 1e-10)
    }

    func testSigmoid01FromThreshold() {
        let context = TierContext.forTesting
        // Test at threshold: should be ~0.5
        let result = PRMath.sigmoid01FromThreshold(
            0.48,
            threshold: 0.48,
            transitionWidth: 0.44,
            context: context
        )
        XCTAssertEqual(result, 0.5, accuracy: 0.1)
    }

    func testSigmoidInverted01FromThreshold() {
        let context = TierContext.forTesting
        // Test inverted: lower is better
        let result = PRMath.sigmoidInverted01FromThreshold(
            0.20,  // Low error (good)
            threshold: 0.48,
            transitionWidth: 0.44,
            context: context
        )
        XCTAssertGreaterThan(result, 0.8)  // Should be high
    }

    func testExpSafe() {
        let result = PRMath.expSafe(0.0)
        XCTAssertEqual(result, 1.0, accuracy: 1e-10)

        // Test clamping
        let largeResult = PRMath.expSafe(1000.0)
        XCTAssertTrue(largeResult.isFinite)
    }

    func testClamp01() {
        XCTAssertEqual(PRMath.clamp01(0.5), 0.5)
        XCTAssertEqual(PRMath.clamp01(-0.1), 0.0)
        XCTAssertEqual(PRMath.clamp01(1.5), 1.0)
    }

    func testClamp() {
        XCTAssertEqual(PRMath.clamp(5.0, 0.0, 10.0), 5.0)
        XCTAssertEqual(PRMath.clamp(-1.0, 0.0, 10.0), 0.0)
        XCTAssertEqual(PRMath.clamp(15.0, 0.0, 10.0), 10.0)
    }

    func testIsUsable() {
        XCTAssertTrue(PRMath.isUsable(1.0))
        XCTAssertFalse(PRMath.isUsable(Double.nan))
        XCTAssertFalse(PRMath.isUsable(Double.infinity))
    }
}
