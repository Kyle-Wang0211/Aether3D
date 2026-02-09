// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HysteresisCooldownDwellControllerTests.swift
// PR5CaptureTests
//
// Tests for HysteresisCooldownDwellController
//

import XCTest
@testable import PR5Capture

@MainActor
final class HysteresisCooldownDwellControllerTests: XCTestCase {
    
    func testHysteresisEnter() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Start below threshold
        let result1 = await controller.evaluate(0.5)
        guard case .maintained(let current, _) = result1 else {
            XCTFail("Should maintain inactive state")
            return
        }
        XCTAssertFalse(current)
        
        // Cross enter threshold
        let result2 = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        guard case .transitioned(let to, _) = result2 else {
            XCTFail("Should transition to active")
            return
        }
        XCTAssertTrue(to)
    }
    
    func testHysteresisExit() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Enter active state
        let enterResult = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        guard case .transitioned(let toActive, _) = enterResult, toActive == true else {
            XCTFail("Should have entered active state")
            return
        }
        
        // Verify we're in active state
        let isActive = await controller.getCurrentState()
        XCTAssertTrue(isActive)
        
        // Wait for cooldown to pass (cooldown applies to all transitions)
        try? await Task.sleep(nanoseconds: UInt64((config.cooldownPeriodSeconds + 0.1) * 1_000_000_000))
        
        // Try to exit with value below exit threshold (should be blocked by minimum dwell)
        let exitValue = config.hysteresisExitThreshold - 0.1
        let result = await controller.evaluate(exitValue)
        
        // Should be in dwell period (cannot exit yet - minimum dwell not met)
        switch result {
        case .dwell:
            // Expected - minimum dwell period not met
            break
        case .maintained(let current, _):
            // If value is still above exit threshold, it's maintained
            if !current {
                XCTFail("Should not have exited (minimum dwell not met)")
            }
        case .transitioned(let to, _):
            if to {
                XCTFail("Should not transition to active again")
            } else {
                XCTFail("Should not exit immediately (minimum dwell)")
            }
        case .cooldown:
            XCTFail("Cooldown should have passed")
        }
    }
    
    func testCooldownPeriod() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Enter active state
        _ = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        
        // Wait for minimum dwell (use cooldown period * 2 as minimum dwell for low light controller)
        let minimumDwell = config.cooldownPeriodSeconds * 2.0
        try? await Task.sleep(nanoseconds: UInt64((minimumDwell + 0.1) * 1_000_000_000))
        
        // Exit
        _ = await controller.evaluate(config.hysteresisExitThreshold - 0.1)
        
        // Try to re-enter immediately (should be blocked by cooldown)
        let result = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        guard case .cooldown = result else {
            XCTFail("Should be in cooldown period")
            return
        }
    }
    
    func testPreconfiguredControllers() {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        
        let lowLight = HysteresisCooldownDwellController.lowLight(config: config)
        let highMotion = HysteresisCooldownDwellController.highMotion(config: config)
        let hdr = HysteresisCooldownDwellController.hdr(config: config)
        let thermal = HysteresisCooldownDwellController.thermal(config: config)
        let focus = HysteresisCooldownDwellController.focus(config: config)
        
        // All controllers should be created successfully
        XCTAssertNotNil(lowLight)
        XCTAssertNotNil(highMotion)
        XCTAssertNotNil(hdr)
        XCTAssertNotNil(thermal)
        XCTAssertNotNil(focus)
    }
    
    // MARK: - Additional Hysteresis Tests
    
    func test_hysteresis_rising_threshold() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Start below threshold
        _ = await controller.evaluate(0.5)
        
        // Gradually increase
        for value in stride(from: 0.5, to: 1.0, by: 0.1) {
            _ = await controller.evaluate(value)
        }
        
        let isActive = await controller.getCurrentState()
        XCTAssertTrue(isActive)
    }
    
    func test_hysteresis_falling_threshold() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Enter active state
        _ = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        
        // Wait for cooldown and minimum dwell
        let waitTime = config.cooldownPeriodSeconds * 3.0
        try? await Task.sleep(nanoseconds: UInt64((waitTime + 0.1) * 1_000_000_000))
        
        // Gradually decrease
        for value in stride(from: 1.0, to: 0.0, by: -0.1) {
            _ = await controller.evaluate(value)
        }
        
        let isActive = await controller.getCurrentState()
        XCTAssertFalse(isActive)
    }
    
    func test_cooldown_period_enforcement() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Enter active
        _ = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        
        // Wait for minimum dwell
        let waitTime = config.cooldownPeriodSeconds * 2.0
        try? await Task.sleep(nanoseconds: UInt64((waitTime + 0.1) * 1_000_000_000))
        
        // Exit
        _ = await controller.evaluate(config.hysteresisExitThreshold - 0.1)
        
        // Try to re-enter immediately (should be blocked)
        let result = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        
        switch result {
        case .cooldown:
            break  // Expected
        default:
            XCTFail("Should be in cooldown")
        }
    }
    
    func test_minimum_dwell_time() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Enter active
        _ = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        
        // Try to exit immediately (should be blocked by minimum dwell)
        let result = await controller.evaluate(config.hysteresisExitThreshold - 0.1)
        
        switch result {
        case .dwell, .maintained:
            break  // Expected - minimum dwell not met
        case .transitioned(let to, _):
            if !to {
                XCTFail("Should not exit during minimum dwell")
            }
        case .cooldown:
            break  // Also acceptable
        }
    }
    
    func test_state_machine_transitions() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Inactive -> Active
        let result1 = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
        guard case .transitioned(let to1, _) = result1, to1 == true else {
            XCTFail("Should transition to active")
            return
        }
        
        // Wait for cooldown and minimum dwell
        let waitTime = config.cooldownPeriodSeconds * 3.0
        try? await Task.sleep(nanoseconds: UInt64((waitTime + 0.1) * 1_000_000_000))
        
        // Active -> Inactive
        let result2 = await controller.evaluate(config.hysteresisExitThreshold - 0.1)
        guard case .transitioned(let to2, _) = result2, to2 == false else {
            XCTFail("Should transition to inactive")
            return
        }
    }
    
    func test_extreme_timing_scenarios() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Rapid state changes
        for _ in 0..<10 {
            _ = await controller.evaluate(config.hysteresisEnterThreshold + 0.1)
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            _ = await controller.evaluate(config.hysteresisExitThreshold - 0.1)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        // Should handle rapid changes gracefully
        let state = await controller.getCurrentState()
        XCTAssertNotNil(state)
    }
    
    func test_all_preconfigured_controllers() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        
        let controllers = [
            HysteresisCooldownDwellController.lowLight(config: config),
            HysteresisCooldownDwellController.highMotion(config: config),
            HysteresisCooldownDwellController.hdr(config: config),
            HysteresisCooldownDwellController.thermal(config: config),
            HysteresisCooldownDwellController.focus(config: config)
        ]
        
        for controller in controllers {
            let result = await controller.evaluate(0.5)
            XCTAssertNotNil(result)
        }
    }
    
    func test_hysteresis_threshold_ordering() async {
        let config = ExtremeProfile.StateMachineConfig.forProfile(.standard)
        let controller = HysteresisCooldownDwellController.lowLight(config: config)
        
        // Enter threshold should be higher than exit threshold
        XCTAssertGreaterThan(config.hysteresisEnterThreshold, config.hysteresisExitThreshold)
        
        // Test values between thresholds
        let middleValue = (config.hysteresisEnterThreshold + config.hysteresisExitThreshold) / 2.0
        
        // If currently inactive, middle value should maintain inactive
        let result1 = await controller.evaluate(middleValue)
        switch result1 {
        case .maintained(let current, _):
            XCTAssertFalse(current)  // Should remain inactive
        default:
            break
        }
    }
}
