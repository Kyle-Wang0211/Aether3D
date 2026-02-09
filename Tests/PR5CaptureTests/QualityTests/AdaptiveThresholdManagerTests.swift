// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AdaptiveThresholdManagerTests.swift
// PR5CaptureTests
//
// Tests for AdaptiveThresholdManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class AdaptiveThresholdManagerTests: XCTestCase {
    
    var manager: AdaptiveThresholdManager!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        manager = AdaptiveThresholdManager(config: config)
    }
    
    override func tearDown() async throws {
        manager = nil
        config = nil
    }
    
    func testThresholdAdaptation() async {
        let context = [
            "lighting": 0.3,  // Low light
            "motion": 0.5,
            "complexity": 0.7
        ]
        
        let result = await manager.adaptThresholds(context: context)
        XCTAssertFalse(result.changes.isEmpty)  // Should adapt thresholds
    }
    
    func testGetThreshold() async {
        let threshold = await manager.getThreshold(for: "quality")
        XCTAssertGreaterThan(threshold, 0.0)
        XCTAssertLessThanOrEqual(threshold, 1.0)
    }
}
