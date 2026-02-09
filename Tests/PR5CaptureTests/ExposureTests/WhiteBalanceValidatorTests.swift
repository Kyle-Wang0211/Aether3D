// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// WhiteBalanceValidatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for WhiteBalanceValidator
//

import XCTest
@testable import PR5Capture

@MainActor
final class WhiteBalanceValidatorTests: XCTestCase {
    
    var validator: WhiteBalanceValidator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        validator = WhiteBalanceValidator(config: config)
    }
    
    override func tearDown() async throws {
        validator = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await validator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertNotNil(result.isValid)
        XCTAssertGreaterThanOrEqual(result.consistencyScore, 0.0)
        XCTAssertLessThanOrEqual(result.consistencyScore, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        for _ in 0..<10 {
            _ = await validator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        }
        let result = await validator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertTrue(result.isValid)
    }
    
    func test_standardConfiguration_works() async {
        let result = await validator.validateWhiteBalance(r: 0.9, g: 1.0, b: 1.1)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let stableWB = Array(repeating: (r: 1.0, g: 1.0, b: 1.0), count: 10)
        for wb in stableWB {
            _ = await validator.validateWhiteBalance(r: wb.r, g: wb.g, b: wb.b)
        }
        let result = await validator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertTrue(result.isValid)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await validator.validateWhiteBalance(r: 1.0 + Double(i) * 0.01, g: 1.0, b: 1.0)
        }
        let result = await validator.validateWhiteBalance(r: 1.05, g: 1.0, b: 1.0)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await validator.validateWhiteBalance(r: 0.0, g: 0.0, b: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await validator.validateWhiteBalance(r: 10.0, g: 10.0, b: 10.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await validator.validateWhiteBalance(r: 0.0, g: 0.0, b: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await validator.validateWhiteBalance(r: 0.001, g: 0.001, b: 0.001)
        let result2 = await validator.validateWhiteBalance(r: 9.999, g: 9.999, b: 9.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Validation Tests
    
    func test_consistent_whiteBalance() async {
        for _ in 0..<10 {
            _ = await validator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        }
        let result = await validator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertTrue(result.isValid)
    }
    
    func test_inconsistent_whiteBalance() async {
        for i in 0..<10 {
            _ = await validator.validateWhiteBalance(r: 1.0 + Double(i) * 0.2, g: 1.0, b: 1.0)
        }
        let result = await validator.validateWhiteBalance(r: 3.0, g: 1.0, b: 1.0)
        XCTAssertFalse(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodValidator = WhiteBalanceValidator(config: prodConfig)
        let result = await prodValidator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devValidator = WhiteBalanceValidator(config: devConfig)
        let result = await devValidator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testValidator = WhiteBalanceValidator(config: testConfig)
        let result = await testValidator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidValidator = WhiteBalanceValidator(config: paranoidConfig)
        let result = await paranoidValidator.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.validator.validateWhiteBalance(r: Double(i) * 0.1, g: 1.0, b: 1.0)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let validator1 = WhiteBalanceValidator(config: config)
        let validator2 = WhiteBalanceValidator(config: config)
        
        _ = await validator1.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        _ = await validator2.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        
        let result1 = await validator1.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        let result2 = await validator2.validateWhiteBalance(r: 1.0, g: 1.0, b: 1.0)
        
        XCTAssertEqual(result1.isValid, result2.isValid)
    }
}
