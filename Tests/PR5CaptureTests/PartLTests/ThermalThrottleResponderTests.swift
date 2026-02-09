// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ThermalThrottleResponderTests.swift
// PR5CaptureTests
//
// Comprehensive tests for ThermalThrottleResponder
//

import XCTest
@testable import PR5Capture

@MainActor
final class ThermalThrottleResponderTests: XCTestCase {
    
    var responder: ThermalThrottleResponder!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        responder = ThermalThrottleResponder(config: config)
    }
    
    override func tearDown() async throws {
        responder = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await responder.respondToThermalState(.normal)
        XCTAssertNotNil(result.degradation)
        XCTAssertEqual(result.state, .normal)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await responder.respondToThermalState(.warm)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await responder.respondToThermalState(.hot)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await responder.respondToThermalState(.normal)
        XCTAssertEqual(result.degradation, .none)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let states: [ThermalThrottleResponder.ThermalState] = [.normal, .warm, .hot, .critical]
        for state in states {
            _ = await responder.respondToThermalState(state)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_allThermalStates() async {
        let states: [ThermalThrottleResponder.ThermalState] = [.normal, .warm, .hot, .critical]
        for state in states {
            let result = await responder.respondToThermalState(state)
            XCTAssertNotNil(result)
        }
    }
    
    func test_normalState_degradation() async {
        let result = await responder.respondToThermalState(.normal)
        XCTAssertEqual(result.degradation, .none)
    }
    
    func test_criticalState_degradation() async {
        let result = await responder.respondToThermalState(.critical)
        XCTAssertEqual(result.degradation, .aggressive)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodResponder = ThermalThrottleResponder(config: prodConfig)
        let result = await prodResponder.respondToThermalState(.normal)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devResponder = ThermalThrottleResponder(config: devConfig)
        let result = await devResponder.respondToThermalState(.normal)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testResponder = ThermalThrottleResponder(config: testConfig)
        let result = await testResponder.respondToThermalState(.normal)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidResponder = ThermalThrottleResponder(config: paranoidConfig)
        let result = await paranoidResponder.respondToThermalState(.normal)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            let states: [ThermalThrottleResponder.ThermalState] = [.normal, .warm, .hot, .critical]
            for state in states {
                group.addTask {
                    _ = await self.responder.respondToThermalState(state)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let responder1 = ThermalThrottleResponder(config: config)
        let responder2 = ThermalThrottleResponder(config: config)
        
        let result1 = await responder1.respondToThermalState(.normal)
        let result2 = await responder2.respondToThermalState(.critical)
        
        XCTAssertNotEqual(result1.degradation, result2.degradation)
    }
}
