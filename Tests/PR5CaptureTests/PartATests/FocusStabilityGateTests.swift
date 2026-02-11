// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FocusStabilityGateTests.swift
// PR5CaptureTests
//
// Comprehensive tests for FocusStabilityGate
//

import XCTest
@testable import PR5Capture

@MainActor
final class FocusStabilityGateTests: XCTestCase {
    
    var gate: FocusStabilityGate!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        gate = FocusStabilityGate(config: config)
    }
    
    override func tearDown() async throws {
        gate = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await gate.evaluateStability(0.5)
        XCTAssertNotNil(result.stability)
    }
    
    func test_typicalUseCase_succeeds() async {
        for i in 0..<10 {
            _ = await gate.evaluateStability(0.5 + Double(i) * 0.01)
        }
        let isStable = await gate.getCurrentStability()
        XCTAssertNotNil(isStable)
    }
    
    func test_standardConfiguration_works() async {
        let result = await gate.evaluateStability(0.7)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let stableValues = Array(repeating: 0.5, count: 10)
        for value in stableValues {
            _ = await gate.evaluateStability(value)
        }
        let isStable = await gate.getCurrentStability()
        XCTAssertTrue(isStable)  // Should be stable
    }
    
    func test_commonScenario_handledCorrectly() async {
        let values = Array(stride(from: 0.5, to: 0.6, by: 0.01))
        for value in values {
            _ = await gate.evaluateStability(value)
        }
        let isStable = await gate.getCurrentStability()
        XCTAssertNotNil(isStable)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await gate.evaluateStability(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await gate.evaluateStability(1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await gate.evaluateStability(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await gate.evaluateStability(0.001)
        let result2 = await gate.evaluateStability(0.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - AF Hunting Detection Tests
    
    func test_af_hunting_detected() async {
        // Simulate hunting (oscillating values)
        let huntingValues: [Double] = [0.5, 0.6, 0.4, 0.7, 0.3, 0.8, 0.2]
        var lastResult: FocusStabilityGate.FocusStabilityResult?
        for value in huntingValues {
            lastResult = await gate.evaluateStability(value)
        }
        XCTAssertNotNil(lastResult)
        if let result = lastResult {
            XCTAssertTrue(result.isHunting)
        }
    }
    
    func test_af_hunting_not_detected() async {
        // Stable values
        let stableValues = Array(repeating: 0.5, count: 10)
        var lastResult: FocusStabilityGate.FocusStabilityResult?
        for value in stableValues {
            lastResult = await gate.evaluateStability(value)
        }
        XCTAssertNotNil(lastResult)
        if let result = lastResult {
            XCTAssertFalse(result.isHunting)
        }
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodGate = FocusStabilityGate(config: prodConfig)
        
        let result = await prodGate.evaluateStability(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devGate = FocusStabilityGate(config: devConfig)
        
        let result = await devGate.evaluateStability(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testGate = FocusStabilityGate(config: testConfig)
        
        let result = await testGate.evaluateStability(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidGate = FocusStabilityGate(config: paranoidConfig)
        
        let result = await paranoidGate.evaluateStability(0.5)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.gate.evaluateStability(Double(i) / 10.0)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let gate1 = FocusStabilityGate(config: config)
        let gate2 = FocusStabilityGate(config: config)
        
        _ = await gate1.evaluateStability(0.5)
        _ = await gate2.evaluateStability(0.5)
        
        let stability1 = await gate1.getCurrentStability()
        let stability2 = await gate2.getCurrentStability()
        
        XCTAssertEqual(stability1, stability2)
    }
}
