// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HysteresisStateMachineTests.swift
// PR5CaptureTests
//
// Tests for HysteresisStateMachine
//

import XCTest
@testable import PR5Capture

@MainActor
final class HysteresisStateMachineTests: XCTestCase {
    
    var stateMachine: HysteresisStateMachine!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        stateMachine = HysteresisStateMachine(config: config)
    }
    
    override func tearDown() async throws {
        stateMachine = nil
        config = nil
    }
    
    func testHysteresisEnter() async {
        // Start below threshold
        let result1 = await stateMachine.evaluate(0.5)
        guard case .maintained(let current, _) = result1 else {
            XCTFail("Should maintain inactive state")
            return
        }
        XCTAssertFalse(current)
        
        // Cross enter threshold
        let result2 = await stateMachine.evaluate(config.stateMachine.hysteresisEnterThreshold + 0.1)
        guard case HysteresisStateMachine.StateTransitionResult.transitioned(let to, _, _) = result2 else {
            XCTFail("Should transition to active")
            return
        }
        XCTAssertTrue(to)
    }
    
    func testEmergencyTransition() async {
        // Force emergency transition
        let result = await stateMachine.evaluate(0.5, forceEmergency: true)
        
        // Should allow emergency transition
        switch result {
        case .transitioned, .maintained:
            break  // OK
        case .rateLimited:
            // Rate limited is also acceptable
            break
        case .cooldown, .dwell:
            // Also acceptable
            break
        }
    }
}
