// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ZeroTrigThetaBucketingTests.swift
// Aether3D
//
// PR3 - Zero-Trig Theta Bucketing Tests
//

import XCTest
@testable import Aether3DCore

final class ZeroTrigThetaBucketingTests: XCTestCase {

    func testThetaBucketDegenerateCase() {
        // Test degenerate case (looking straight up/down)
        let bucket = ZeroTrigThetaBucketing.thetaBucket(dx: 0.0, dz: 0.0)
        XCTAssertEqual(bucket, 0)  // Deterministic fallback
    }

    func testThetaBucketOptimized() {
        // Test optimized version produces same result
        let dx = 0.5
        let dz = 0.8660254037844387  // ~30° from +Z

        let bucket1 = ZeroTrigThetaBucketing.thetaBucket(dx: dx, dz: dz)
        let bucket2 = ZeroTrigThetaBucketing.thetaBucketOptimized(dx: dx, dz: dz)

        XCTAssertEqual(bucket1, bucket2)
    }

    func testThetaBucketMatchesShadowTrig() {
        #if DEBUG
        // Test that zero-trig matches shadow trig verifier
        let testCases: [(dx: Double, dz: Double)] = [
            (0.0, 1.0),      // 0°
            (1.0, 0.0),      // 90°
            (0.0, -1.0),     // 180°
            (-1.0, 0.0)      // 270°
        ]

        for (dx, dz) in testCases {
            let bucket = ZeroTrigThetaBucketing.thetaBucket(dx: dx, dz: dz)
            let matches = ShadowTrigVerifier.verifyThetaBucket(dx: dx, dz: dz, canonicalBucket: bucket)
            XCTAssertTrue(matches, "Theta bucket mismatch for dx=\(dx), dz=\(dz)")
        }
        #endif
    }
}
