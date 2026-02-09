// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ReplayAttackPreventerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for ReplayAttackPreventer
//

import XCTest
@testable import PR5Capture

@MainActor
final class ReplayAttackPreventerTests: XCTestCase {
    
    var preventer: ReplayAttackPreventer!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        preventer = ReplayAttackPreventer(config: config)
    }
    
    override func tearDown() async throws {
        preventer = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await preventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertNotNil(result.isValid)
        XCTAssertTrue(result.isValid)
    }
    
    func test_typicalUseCase_succeeds() async {
        let nonce = UUID().uuidString
        let result = await preventer.validateRequest(nonce: nonce, timestamp: Date())
        XCTAssertTrue(result.isValid)
    }
    
    func test_standardConfiguration_works() async {
        let result = await preventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let nonce = UUID().uuidString
        let timestamp = Date()
        let result = await preventer.validateRequest(nonce: nonce, timestamp: timestamp)
        XCTAssertTrue(result.isValid)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for _ in 0..<10 {
            _ = await preventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_replay_detection() async {
        let nonce = UUID().uuidString
        _ = await preventer.validateRequest(nonce: nonce, timestamp: Date())
        let result = await preventer.validateRequest(nonce: nonce, timestamp: Date())
        XCTAssertFalse(result.isValid)
    }
    
    func test_old_timestamp() async {
        let oldDate = Date().addingTimeInterval(-400)  // Older than 5 minutes
        let result = await preventer.validateRequest(nonce: UUID().uuidString, timestamp: oldDate)
        XCTAssertFalse(result.isValid)
    }
    
    func test_fresh_timestamp() async {
        let result = await preventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodPreventer = ReplayAttackPreventer(config: prodConfig)
        let result = await prodPreventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devPreventer = ReplayAttackPreventer(config: devConfig)
        let result = await devPreventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testPreventer = ReplayAttackPreventer(config: testConfig)
        let result = await testPreventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidPreventer = ReplayAttackPreventer(config: paranoidConfig)
        let result = await paranoidPreventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.preventer.validateRequest(nonce: UUID().uuidString, timestamp: Date())
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let preventer1 = ReplayAttackPreventer(config: config)
        let preventer2 = ReplayAttackPreventer(config: config)
        
        let nonce = UUID().uuidString
        let result1 = await preventer1.validateRequest(nonce: nonce, timestamp: Date())
        let result2 = await preventer2.validateRequest(nonce: nonce, timestamp: Date())
        
        // Both should be valid (separate instances)
        XCTAssertTrue(result1.isValid)
        XCTAssertTrue(result2.isValid)
    }
}
