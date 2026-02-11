// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RobustnessScoreCalculatorTests.swift
// PR5CaptureTests
//
// Tests for RobustnessScoreCalculator
//

import XCTest
@testable import PR5Capture

@MainActor
final class RobustnessScoreCalculatorTests: XCTestCase {
    
    var calculator: RobustnessScoreCalculator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        calculator = RobustnessScoreCalculator(config: config)
    }
    
    override func tearDown() async throws {
        calculator = nil
        config = nil
    }
    
    func testRobustnessCalculation() async {
        // Record consistent quality scores
        for _ in 0..<10 {
            _ = await calculator.calculateRobustness(0.8)
        }
        
        let avgRobustness = await calculator.getAverageRobustness()
        XCTAssertNotNil(avgRobustness)
        XCTAssertGreaterThan(avgRobustness!, 0.0)
    }
    
    func testStability() async {
        // Record stable scores
        for _ in 0..<10 {
            _ = await calculator.calculateRobustness(0.8)
        }
        
        let result = await calculator.calculateRobustness(0.8)
        XCTAssertGreaterThan(result.stability, 0.0)
    }
}
