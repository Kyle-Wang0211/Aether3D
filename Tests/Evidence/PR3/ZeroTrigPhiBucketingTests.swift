// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ZeroTrigPhiBucketingTests.swift
// Aether3D
//
// PR3 - Zero-Trig Phi Bucketing Tests
//

import XCTest
@testable import Aether3DCore

final class ZeroTrigPhiBucketingTests: XCTestCase {

    func testPhiBucketBoundaries() {
        // Test bucket boundaries match expected sin values
        XCTAssertEqual(ZeroTrigPhiBucketing.phiBucket(dy: -1.0), 0)   // sin(-90°)
        XCTAssertEqual(ZeroTrigPhiBucketing.phiBucket(dy: 0.0), 6)    // sin(0°)
        XCTAssertEqual(ZeroTrigPhiBucketing.phiBucket(dy: 1.0), 11)   // sin(90°)
    }

    func testPhiBucketClamps() {
        // Test clamping to [-1, 1]
        let below = ZeroTrigPhiBucketing.phiBucket(dy: -2.0)
        XCTAssertEqual(below, 0)

        let above = ZeroTrigPhiBucketing.phiBucket(dy: 2.0)
        XCTAssertEqual(above, 11)
    }

    func testPhiBucketMatchesShadowTrig() {
        #if DEBUG
        // Test that zero-trig matches shadow trig verifier
        let testCases: [Double] = [-1.0, -0.5, 0.0, 0.5, 1.0]

        for dy in testCases {
            let bucket = ZeroTrigPhiBucketing.phiBucket(dy: dy)
            let matches = ShadowTrigVerifier.verifyPhiBucket(dy: dy, canonicalBucket: bucket)
            XCTAssertTrue(matches, "Phi bucket mismatch for dy=\(dy)")
        }
        #endif
    }
}
