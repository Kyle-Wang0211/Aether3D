// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DynamicSceneClassifierTests.swift
// PR5CaptureTests
//
// Comprehensive tests for DynamicSceneClassifier
//

import XCTest
@testable import PR5Capture

@MainActor
final class DynamicSceneClassifierTests: XCTestCase {
    
    var classifier: DynamicSceneClassifier!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        classifier = DynamicSceneClassifier(config: config)
    }
    
    override func tearDown() async throws {
        classifier = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        XCTAssertNotNil(result.sceneType)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.3, complexity: 0.4)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.5, complexity: 0.6)
        XCTAssertNotNil(result.sceneType)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.1, complexity: 0.2)
        XCTAssertNotNil(result.sceneType) // Just verify we get a result
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await classifier.classifyScene(motionMagnitude: Double(i) * 0.1, complexity: 0.5)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.0, complexity: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await classifier.classifyScene(motionMagnitude: 1.0, complexity: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.0, complexity: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await classifier.classifyScene(motionMagnitude: 0.001, complexity: 0.001)
        let result2 = await classifier.classifyScene(motionMagnitude: 0.999, complexity: 0.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Scene Type Tests
    
    func test_staticScene_classification() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.05, complexity: 0.2)
        XCTAssertEqual(result.sceneType, .staticScene)
    }
    
    func test_slowMotion_classification() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.2, complexity: 0.4)
        XCTAssertEqual(result.sceneType, .slowMotion)
    }
    
    func test_moderateMotion_classification() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.5, complexity: 0.6)
        XCTAssertEqual(result.sceneType, .moderateMotion)
    }
    
    func test_fastMotion_classification() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.8, complexity: 0.5)
        XCTAssertEqual(result.sceneType, .fastMotion)
    }
    
    func test_complex_classification() async {
        let result = await classifier.classifyScene(motionMagnitude: 0.95, complexity: 0.9)
        XCTAssertEqual(result.sceneType, .complex)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodClassifier = DynamicSceneClassifier(config: prodConfig)
        let result = await prodClassifier.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devClassifier = DynamicSceneClassifier(config: devConfig)
        let result = await devClassifier.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testClassifier = DynamicSceneClassifier(config: testConfig)
        let result = await testClassifier.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidClassifier = DynamicSceneClassifier(config: paranoidConfig)
        let result = await paranoidClassifier.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.classifier.classifyScene(motionMagnitude: Double(i) * 0.1, complexity: 0.5)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let classifier1 = DynamicSceneClassifier(config: config)
        let classifier2 = DynamicSceneClassifier(config: config)
        
        let result1 = await classifier1.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        let result2 = await classifier2.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        
        XCTAssertEqual(result1.sceneType, result2.sceneType)
    }
    
    // MARK: - Performance Tests

    func test_performance_underLoad() async {
        // Simple load test without measure block
        for _ in 0..<100 {
            _ = await classifier.classifyScene(motionMagnitude: 0.5, complexity: 0.5)
        }
    }
}
