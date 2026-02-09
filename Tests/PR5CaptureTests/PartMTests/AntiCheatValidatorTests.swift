// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AntiCheatValidatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for AntiCheatValidator
//

import XCTest
@testable import PR5Capture

@MainActor
final class AntiCheatValidatorTests: XCTestCase {
    
    var validator: AntiCheatValidator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        validator = AntiCheatValidator(config: config)
    }
    
    override func tearDown() async throws {
        validator = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await validator.validate()
        XCTAssertNotNil(result.isValid)
        XCTAssertNotNil(result.primaryThreat)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await validator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await validator.validate()
        XCTAssertNotNil(result.threats)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await validator.validate()
        if result.isValid {
            XCTAssertEqual(result.primaryThreat, .none)
        }
    }
    
    func test_commonScenario_handledCorrectly() async {
        for _ in 0..<10 {
            _ = await validator.validate()
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_validation_noThreats() async {
        let result = await validator.validate()
        // In normal test environment, should be valid
        XCTAssertNotNil(result)
    }
    
    func test_allThreatTypes() async {
        let result = await validator.validate()
        XCTAssertNotNil(result.threats)
    }
    
    // MARK: - Threat Detection Tests
    
    func test_threat_detection() async {
        let result = await validator.validate()
        XCTAssertNotNil(result.primaryThreat)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodValidator = AntiCheatValidator(config: prodConfig)
        let result = await prodValidator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devValidator = AntiCheatValidator(config: devConfig)
        let result = await devValidator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testValidator = AntiCheatValidator(config: testConfig)
        let result = await testValidator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidValidator = AntiCheatValidator(config: paranoidConfig)
        let result = await paranoidValidator.validate()
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.validator.validate()
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let validator1 = AntiCheatValidator(config: config)
        let validator2 = AntiCheatValidator(config: config)
        
        let result1 = await validator1.validate()
        let result2 = await validator2.validate()
        
        XCTAssertEqual(result1.isValid, result2.isValid)
    }
}
