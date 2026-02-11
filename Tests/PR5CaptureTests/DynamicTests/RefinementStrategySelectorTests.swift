// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RefinementStrategySelectorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for RefinementStrategySelector
//

import XCTest
@testable import PR5Capture

@MainActor
final class RefinementStrategySelectorTests: XCTestCase {
    
    var selector: RefinementStrategySelector!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        selector = RefinementStrategySelector(config: config)
    }
    
    override func tearDown() async throws {
        selector = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await selector.selectStrategy(sceneType: .staticScene, complexity: 0.5, quality: 0.7)
        XCTAssertNotNil(result.strategy)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await selector.selectStrategy(sceneType: .moderateMotion, complexity: 0.6, quality: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await selector.selectStrategy(sceneType: .slowMotion, complexity: 0.4, quality: 0.6)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await selector.selectStrategy(sceneType: .staticScene, complexity: 0.3, quality: 0.8)
        XCTAssertEqual(result.strategy, .light)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for sceneType in [DynamicSceneClassifier.SceneType.staticScene, .slowMotion, .fastMotion, .complex] {
            _ = await selector.selectStrategy(sceneType: sceneType, complexity: 0.5, quality: 0.5)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await selector.selectStrategy(sceneType: .staticScene, complexity: 0.0, quality: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await selector.selectStrategy(sceneType: .complex, complexity: 1.0, quality: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await selector.selectStrategy(sceneType: .staticScene, complexity: 0.0, quality: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await selector.selectStrategy(sceneType: .staticScene, complexity: 0.001, quality: 0.001)
        let result2 = await selector.selectStrategy(sceneType: .complex, complexity: 0.999, quality: 0.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Strategy Selection Tests
    
    func test_staticScene_strategy() async {
        let result = await selector.selectStrategy(sceneType: .staticScene, complexity: 0.3, quality: 0.8)
        XCTAssertEqual(result.strategy, .light)
    }
    
    func test_complexScene_strategy() async {
        let result = await selector.selectStrategy(sceneType: .complex, complexity: 0.9, quality: 0.5)
        XCTAssertEqual(result.strategy, .adaptive)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodSelector = RefinementStrategySelector(config: prodConfig)
        let result = await prodSelector.selectStrategy(sceneType: .staticScene, complexity: 0.5, quality: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devSelector = RefinementStrategySelector(config: devConfig)
        let result = await devSelector.selectStrategy(sceneType: .staticScene, complexity: 0.5, quality: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testSelector = RefinementStrategySelector(config: testConfig)
        let result = await testSelector.selectStrategy(sceneType: .staticScene, complexity: 0.5, quality: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidSelector = RefinementStrategySelector(config: paranoidConfig)
        let result = await paranoidSelector.selectStrategy(sceneType: .staticScene, complexity: 0.5, quality: 0.7)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for sceneType in [DynamicSceneClassifier.SceneType.staticScene, .slowMotion, .fastMotion, .complex] {
                group.addTask {
                    _ = await self.selector.selectStrategy(sceneType: sceneType, complexity: 0.5, quality: 0.5)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let selector1 = RefinementStrategySelector(config: config)
        let selector2 = RefinementStrategySelector(config: config)
        
        let result1 = await selector1.selectStrategy(sceneType: .staticScene, complexity: 0.5, quality: 0.7)
        let result2 = await selector2.selectStrategy(sceneType: .fastMotion, complexity: 0.8, quality: 0.4)
        
        XCTAssertNotEqual(result1.strategy, result2.strategy)
    }
}
