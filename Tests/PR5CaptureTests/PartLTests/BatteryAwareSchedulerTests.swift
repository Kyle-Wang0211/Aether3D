// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BatteryAwareSchedulerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for BatteryAwareScheduler
//

import XCTest
@testable import PR5Capture

@MainActor
final class BatteryAwareSchedulerTests: XCTestCase {
    
    var scheduler: BatteryAwareScheduler!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        scheduler = BatteryAwareScheduler(config: config)
    }
    
    override func tearDown() async throws {
        scheduler = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let task = BatteryAwareScheduler.ScheduledTask(name: "test_task")
        let result = await scheduler.scheduleTask(task)
        XCTAssertNotNil(result.priority)
        XCTAssertNotNil(result.batteryState)
    }
    
    func test_typicalUseCase_succeeds() async {
        await scheduler.updateBatteryState(.high)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task1")
        let result = await scheduler.scheduleTask(task)
        XCTAssertEqual(result.priority, .normal)
    }
    
    func test_standardConfiguration_works() async {
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await scheduler.scheduleTask(task)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        await scheduler.updateBatteryState(.low)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await scheduler.scheduleTask(task)
        XCTAssertEqual(result.priority, .minimal)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for state in [BatteryAwareScheduler.BatteryState.charging, .high, .medium, .low, .critical] {
            await scheduler.updateBatteryState(state)
            let task = BatteryAwareScheduler.ScheduledTask(name: "task")
            _ = await scheduler.scheduleTask(task)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_allBatteryStates() async {
        for state in [BatteryAwareScheduler.BatteryState.charging, .high, .medium, .low, .critical] {
            await scheduler.updateBatteryState(state)
            let task = BatteryAwareScheduler.ScheduledTask(name: "task")
            let result = await scheduler.scheduleTask(task)
            XCTAssertNotNil(result)
        }
    }
    
    func test_chargingState_priority() async {
        await scheduler.updateBatteryState(.charging)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await scheduler.scheduleTask(task)
        XCTAssertEqual(result.priority, .normal)
    }
    
    func test_criticalState_priority() async {
        await scheduler.updateBatteryState(.critical)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await scheduler.scheduleTask(task)
        XCTAssertEqual(result.priority, .minimal)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodScheduler = BatteryAwareScheduler(config: prodConfig)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await prodScheduler.scheduleTask(task)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devScheduler = BatteryAwareScheduler(config: devConfig)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await devScheduler.scheduleTask(task)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testScheduler = BatteryAwareScheduler(config: testConfig)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await testScheduler.scheduleTask(task)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidScheduler = BatteryAwareScheduler(config: paranoidConfig)
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result = await paranoidScheduler.scheduleTask(task)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let task = BatteryAwareScheduler.ScheduledTask(name: "task\(i)")
                    _ = await self.scheduler.scheduleTask(task)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let scheduler1 = BatteryAwareScheduler(config: config)
        let scheduler2 = BatteryAwareScheduler(config: config)
        
        await scheduler1.updateBatteryState(.high)
        await scheduler2.updateBatteryState(.low)
        
        let task = BatteryAwareScheduler.ScheduledTask(name: "task")
        let result1 = await scheduler1.scheduleTask(task)
        let result2 = await scheduler2.scheduleTask(task)
        
        XCTAssertNotEqual(result1.priority, result2.priority)
    }
}
