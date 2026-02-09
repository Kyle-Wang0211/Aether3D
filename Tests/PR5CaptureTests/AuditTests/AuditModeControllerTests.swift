// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuditModeControllerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for AuditModeController
//

import XCTest
@testable import PR5Capture

@MainActor
final class AuditModeControllerTests: XCTestCase {
    
    var controller: AuditModeController!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        controller = AuditModeController(config: config)
    }
    
    override func tearDown() async throws {
        controller = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        await controller.setLevel(.standard)
        let level = await controller.getCurrentLevel()
        XCTAssertEqual(level, .standard)
    }
    
    func test_typicalUseCase_succeeds() async {
        await controller.setLevel(.detailed)
        let shouldAudit = await controller.shouldAudit(operation: "critical_operation")
        XCTAssertTrue(shouldAudit)
    }
    
    func test_standardConfiguration_works() async {
        await controller.setLevel(.standard)
        let result = await controller.shouldAudit(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        await controller.setLevel(.comprehensive)
        let shouldAudit = await controller.shouldAudit(operation: "any_operation")
        XCTAssertTrue(shouldAudit)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let levels: [AuditModeController.AuditLevel] = [.none, .minimal, .standard, .detailed, .comprehensive]
        for level in levels {
            await controller.setLevel(level)
            _ = await controller.shouldAudit(operation: "test")
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_allAuditLevels() async {
        let levels: [AuditModeController.AuditLevel] = [.none, .minimal, .standard, .detailed, .comprehensive]
        for level in levels {
            await controller.setLevel(level)
            let current = await controller.getCurrentLevel()
            XCTAssertEqual(current, level)
        }
    }
    
    func test_noneLevel_noAudit() async {
        await controller.setLevel(.none)
        let shouldAudit = await controller.shouldAudit(operation: "test")
        XCTAssertFalse(shouldAudit)
    }
    
    func test_comprehensiveLevel_alwaysAudit() async {
        await controller.setLevel(.comprehensive)
        let shouldAudit = await controller.shouldAudit(operation: "any")
        XCTAssertTrue(shouldAudit)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodController = AuditModeController(config: prodConfig)
        await prodController.setLevel(.standard)
        let result = await prodController.shouldAudit(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devController = AuditModeController(config: devConfig)
        await devController.setLevel(.standard)
        let result = await devController.shouldAudit(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testController = AuditModeController(config: testConfig)
        await testController.setLevel(.standard)
        let result = await testController.shouldAudit(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidController = AuditModeController(config: paranoidConfig)
        await paranoidController.setLevel(.comprehensive)
        let result = await paranoidController.shouldAudit(operation: "test")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        let levels: [AuditModeController.AuditLevel] = [.none, .minimal, .standard, .detailed, .comprehensive]
        await withTaskGroup(of: Void.self) { group in
            for level in levels {
                group.addTask {
                    await self.controller.setLevel(level)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let controller1 = AuditModeController(config: config)
        let controller2 = AuditModeController(config: config)
        
        await controller1.setLevel(.minimal)
        await controller2.setLevel(.comprehensive)
        
        let level1 = await controller1.getCurrentLevel()
        let level2 = await controller2.getCurrentLevel()
        
        XCTAssertNotEqual(level1, level2)
    }
}
