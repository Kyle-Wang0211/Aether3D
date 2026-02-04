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
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        calculator = RobustnessScoreCalculator(config: config)
    }
    
    override func tearDown() {
        calculator = nil
        config = nil
        super.tearDown()
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
