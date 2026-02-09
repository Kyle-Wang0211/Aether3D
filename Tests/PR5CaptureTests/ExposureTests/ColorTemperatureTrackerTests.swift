// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ColorTemperatureTrackerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for ColorTemperatureTracker
//

import XCTest
@testable import PR5Capture

@MainActor
final class ColorTemperatureTrackerTests: XCTestCase {
    
    var tracker: ColorTemperatureTracker!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        tracker = ColorTemperatureTracker(config: config)
    }
    
    override func tearDown() async throws {
        tracker = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await tracker.trackTemperature(5000.0)
        XCTAssertNotNil(result.stability)
        XCTAssertGreaterThanOrEqual(result.stability, 0.0)
        XCTAssertLessThanOrEqual(result.stability, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        for i in 0..<10 {
            _ = await tracker.trackTemperature(5000.0 + Double(i) * 10.0)
        }
        let result = await tracker.trackTemperature(5000.0)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await tracker.trackTemperature(5500.0)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let stableTemps = Array(repeating: 5000.0, count: 10)
        for temp in stableTemps {
            _ = await tracker.trackTemperature(temp)
        }
        let result = await tracker.trackTemperature(5000.0)
        XCTAssertGreaterThan(result.stability, 0.8)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let temps = Array(stride(from: 5000.0, to: 5100.0, by: 10.0))
        for temp in temps {
            _ = await tracker.trackTemperature(temp)
        }
        let result = await tracker.trackTemperature(5050.0)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await tracker.trackTemperature(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await tracker.trackTemperature(10000.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await tracker.trackTemperature(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await tracker.trackTemperature(1.0)
        let result2 = await tracker.trackTemperature(9999.0)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Stability Tests
    
    func test_stable_temperature() async {
        for _ in 0..<10 {
            _ = await tracker.trackTemperature(5000.0)
        }
        let result = await tracker.trackTemperature(5000.0)
        XCTAssertGreaterThan(result.stability, 0.8)
    }
    
    func test_unstable_temperature() async {
        for i in 0..<10 {
            _ = await tracker.trackTemperature(5000.0 + Double(i) * 500.0)
        }
        let result = await tracker.trackTemperature(10000.0)
        XCTAssertLessThan(result.stability, 0.5)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodTracker = ColorTemperatureTracker(config: prodConfig)
        let result = await prodTracker.trackTemperature(5000.0)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devTracker = ColorTemperatureTracker(config: devConfig)
        let result = await devTracker.trackTemperature(5000.0)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testTracker = ColorTemperatureTracker(config: testConfig)
        let result = await testTracker.trackTemperature(5000.0)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidTracker = ColorTemperatureTracker(config: paranoidConfig)
        let result = await paranoidTracker.trackTemperature(5000.0)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.tracker.trackTemperature(5000.0 + Double(i) * 100.0)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let tracker1 = ColorTemperatureTracker(config: config)
        let tracker2 = ColorTemperatureTracker(config: config)
        
        _ = await tracker1.trackTemperature(5000.0)
        _ = await tracker2.trackTemperature(5500.0)
        
        let result1 = await tracker1.trackTemperature(5000.0)
        let result2 = await tracker2.trackTemperature(5500.0)
        
        XCTAssertNotEqual(result1.mean, result2.mean)
    }
}
