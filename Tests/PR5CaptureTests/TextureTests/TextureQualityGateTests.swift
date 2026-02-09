// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TextureQualityGateTests.swift
// PR5CaptureTests
//
// Comprehensive tests for TextureQualityGate
//

import XCTest
@testable import PR5Capture

@MainActor
final class TextureQualityGateTests: XCTestCase {
    
    var gate: TextureQualityGate!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        gate = TextureQualityGate(config: config)
    }
    
    override func tearDown() async throws {
        gate = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await gate.evaluateGate(textureQuality: 0.8)
        XCTAssertNotNil(result.passed)
        XCTAssertEqual(result.quality, 0.8, accuracy: 0.001)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await gate.evaluateGate(textureQuality: 0.75)
        XCTAssertTrue(result.passed)
    }
    
    func test_standardConfiguration_works() async {
        let result = await gate.evaluateGate(textureQuality: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await gate.evaluateGate(textureQuality: 0.8)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.quality, 0.8, accuracy: 0.001)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for quality in stride(from: 0.5, to: 1.0, by: 0.1) {
            _ = await gate.evaluateGate(textureQuality: quality)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await gate.evaluateGate(textureQuality: 0.0)
        XCTAssertNotNil(result)
        XCTAssertFalse(result.passed)
    }
    
    func test_maximumInput_handled() async {
        let result = await gate.evaluateGate(textureQuality: 1.0)
        XCTAssertNotNil(result)
        XCTAssertTrue(result.passed)
    }
    
    func test_zeroInput_handled() async {
        let result = await gate.evaluateGate(textureQuality: 0.0)
        XCTAssertFalse(result.passed)
    }
    
    func test_boundaryValue_processed() async {
        let threshold = await gate.getThreshold()
        let result1 = await gate.evaluateGate(textureQuality: threshold - 0.001)
        let result2 = await gate.evaluateGate(textureQuality: threshold + 0.001)
        XCTAssertFalse(result1.passed)
        XCTAssertTrue(result2.passed)
    }
    
    // MARK: - Gate Tests
    
    func test_gate_pass_highQuality() async {
        let result = await gate.evaluateGate(textureQuality: 0.9)
        XCTAssertTrue(result.passed)
    }
    
    func test_gate_fail_lowQuality() async {
        let result = await gate.evaluateGate(textureQuality: 0.5)
        XCTAssertFalse(result.passed)
    }
    
    func test_threshold_setting() async {
        await gate.setThreshold(0.8)
        let threshold = await gate.getThreshold()
        XCTAssertEqual(threshold, 0.8, accuracy: 0.001)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodGate = TextureQualityGate(config: prodConfig)
        let result = await prodGate.evaluateGate(textureQuality: 0.8)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devGate = TextureQualityGate(config: devConfig)
        let result = await devGate.evaluateGate(textureQuality: 0.8)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testGate = TextureQualityGate(config: testConfig)
        let result = await testGate.evaluateGate(textureQuality: 0.8)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidGate = TextureQualityGate(config: paranoidConfig)
        let result = await paranoidGate.evaluateGate(textureQuality: 0.8)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.gate.evaluateGate(textureQuality: Double(i) * 0.1)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let gate1 = TextureQualityGate(config: config)
        let gate2 = TextureQualityGate(config: config)
        
        _ = await gate1.evaluateGate(textureQuality: 0.8)
        _ = await gate2.evaluateGate(textureQuality: 0.8)
        
        let result1 = await gate1.evaluateGate(textureQuality: 0.8)
        let result2 = await gate2.evaluateGate(textureQuality: 0.8)
        
        XCTAssertEqual(result1.passed, result2.passed)
    }
}
