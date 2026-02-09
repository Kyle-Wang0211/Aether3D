// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CrossPlatformNormalizerTests.swift
// PR5CaptureTests
//
// Tests for CrossPlatformNormalizer
//

import XCTest
@testable import PR5Capture

@MainActor
final class CrossPlatformNormalizerTests: XCTestCase {
    
    var normalizer: CrossPlatformNormalizer!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        normalizer = CrossPlatformNormalizer(config: config)
    }
    
    override func tearDown() async throws {
        normalizer = nil
        config = nil
    }
    
    func testNormalize() async {
        let value = 0.123456789012345
        let normalized = await normalizer.normalize(value)
        XCTAssertNotEqual(value, normalized)  // Should be rounded
    }
    
    func testAreEqual() async {
        let a = 0.123456789012345
        let b = 0.123456789012346
        let equal = await normalizer.areEqual(a, b)
        XCTAssertTrue(equal)  // Should be equal after normalization
    }
}
