// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicRNGManagerTests.swift
// PR5CaptureTests
//
// Tests for DeterministicRNGManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class DeterministicRNGManagerTests: XCTestCase {
    
    var rng: DeterministicRNGManager!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        rng = DeterministicRNGManager(config: config, seed: 12345)
    }
    
    override func tearDown() async throws {
        rng = nil
        config = nil
    }
    
    func testDeterministicSequence() async {
        let value1 = await rng.next()
        await rng.reset()
        let value2 = await rng.next()
        XCTAssertEqual(value1, value2)  // Should be deterministic
    }
    
    func testNextDouble() async {
        let value = await rng.nextDouble()
        XCTAssertGreaterThanOrEqual(value, 0.0)
        XCTAssertLessThan(value, 1.0)
    }
}
