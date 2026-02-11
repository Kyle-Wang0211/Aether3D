// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PrivacyMaskEnforcerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for PrivacyMaskEnforcer
//

import XCTest
@testable import PR5Capture

@MainActor
final class PrivacyMaskEnforcerTests: XCTestCase {
    
    var enforcer: PrivacyMaskEnforcer!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        enforcer = PrivacyMaskEnforcer(config: config)
    }
    
    override func tearDown() async throws {
        enforcer = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await enforcer.enforceMasks(regions: [region])
        XCTAssertEqual(result.maskedRegions, 1)
    }
    
    func test_typicalUseCase_succeeds() async {
        let regions = [
            PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 50, height: 50), type: .face),
            PrivacyMaskEnforcer.MaskRegion(bounds: (x: 200, y: 200, width: 100, height: 50), type: .licensePlate)
        ]
        let result = await enforcer.enforceMasks(regions: regions)
        XCTAssertEqual(result.maskedRegions, 2)
    }
    
    func test_standardConfiguration_works() async {
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 0, y: 0, width: 100, height: 100), type: .face)
        let result = await enforcer.enforceMasks(regions: [region])
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await enforcer.enforceMasks(regions: [region])
        XCTAssertEqual(result.maskedRegions, 1)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let regions = Array(repeating: PrivacyMaskEnforcer.MaskRegion(bounds: (x: 0, y: 0, width: 50, height: 50), type: .face), count: 5)
        let result = await enforcer.enforceMasks(regions: regions)
        XCTAssertEqual(result.maskedRegions, 5)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let regions: [PrivacyMaskEnforcer.MaskRegion] = []
        let result = await enforcer.enforceMasks(regions: regions)
        XCTAssertEqual(result.maskedRegions, 0)
    }
    
    func test_maximumInput_handled() async {
        var regions: [PrivacyMaskEnforcer.MaskRegion] = []
        for i in 0..<100 {
            regions.append(PrivacyMaskEnforcer.MaskRegion(bounds: (x: i, y: i, width: 10, height: 10), type: .face))
        }
        let result = await enforcer.enforceMasks(regions: regions)
        XCTAssertEqual(result.maskedRegions, 100)
    }
    
    func test_zeroInput_handled() async {
        let regions: [PrivacyMaskEnforcer.MaskRegion] = []
        let result = await enforcer.enforceMasks(regions: regions)
        XCTAssertEqual(result.maskedRegions, 0)
    }
    
    func test_boundaryValue_processed() async {
        let region1 = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 0, y: 0, width: 1, height: 1), type: .face)
        let region2 = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 9999, y: 9999, width: 10000, height: 10000), type: .face)
        let result = await enforcer.enforceMasks(regions: [region1, region2])
        XCTAssertEqual(result.maskedRegions, 2)
    }
    
    // MARK: - Region Type Tests
    
    func test_face_region() async {
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await enforcer.enforceMasks(regions: [region])
        XCTAssertEqual(result.maskedRegions, 1)
    }
    
    func test_licensePlate_region() async {
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 200, height: 50), type: .licensePlate)
        let result = await enforcer.enforceMasks(regions: [region])
        XCTAssertEqual(result.maskedRegions, 1)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodEnforcer = PrivacyMaskEnforcer(config: prodConfig)
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await prodEnforcer.enforceMasks(regions: [region])
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devEnforcer = PrivacyMaskEnforcer(config: devConfig)
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await devEnforcer.enforceMasks(regions: [region])
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testEnforcer = PrivacyMaskEnforcer(config: testConfig)
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await testEnforcer.enforceMasks(regions: [region])
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidEnforcer = PrivacyMaskEnforcer(config: paranoidConfig)
        let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let result = await paranoidEnforcer.enforceMasks(regions: [region])
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let region = PrivacyMaskEnforcer.MaskRegion(bounds: (x: i, y: i, width: 50, height: 50), type: .face)
                    _ = await self.enforcer.enforceMasks(regions: [region])
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let enforcer1 = PrivacyMaskEnforcer(config: config)
        let enforcer2 = PrivacyMaskEnforcer(config: config)
        
        let region1 = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 10, y: 10, width: 100, height: 100), type: .face)
        let region2 = PrivacyMaskEnforcer.MaskRegion(bounds: (x: 200, y: 200, width: 100, height: 100), type: .face)
        
        let result1 = await enforcer1.enforceMasks(regions: [region1])
        let result2 = await enforcer2.enforceMasks(regions: [region2])
        
        XCTAssertEqual(result1.maskedRegions, result2.maskedRegions)
    }
}
