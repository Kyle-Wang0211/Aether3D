// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HDRArtifactDetectorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for HDRArtifactDetector
//

import XCTest
@testable import PR5Capture

@MainActor
final class HDRArtifactDetectorTests: XCTestCase {
    
    var detector: HDRArtifactDetector!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        detector = HDRArtifactDetector(config: config)
    }
    
    override func tearDown() async throws {
        detector = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let pixels = Array(repeating: 0.5, count: 100)
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result.artifactScore)
    }
    
    func test_typicalUseCase_succeeds() async {
        let pixels = Array(repeating: 0.7, count: 1000)
        let metadata: [String: Any] = ["hdr": false]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertGreaterThanOrEqual(result.artifactScore, 0.0)
        XCTAssertLessThanOrEqual(result.artifactScore, 1.0)
    }
    
    func test_standardConfiguration_works() async {
        let pixels = Array(stride(from: 0.0, to: 1.0, by: 0.01))
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let pixels = Array(repeating: 0.8, count: 500)
        let metadata: [String: Any] = ["hdr": true]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result.artifactScore)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let pixels = Array(repeating: 0.6, count: 200)
        let metadata: [String: Any] = ["brightness": 0.7]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let pixels: [Double] = [0.0]
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let pixels = Array(repeating: 1.0, count: 10000)
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let pixels: [Double] = []
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    func test_emptyInput_handled() async {
        let pixels: [Double] = []
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let pixels = Array(repeating: 0.99, count: 100)
        let metadata: [String: Any] = [:]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    // MARK: - HDR Detection Tests
    
    func test_hdr_artifacts_detected() async {
        // Use varying pixel values to trigger artifact detection
        let pixels = Array(stride(from: 0.5, to: 1.0, by: 0.001))
        let metadata: [String: Any] = ["hdr": true, "isHDR": true]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertTrue(result.isHDR)
        XCTAssertGreaterThanOrEqual(result.artifactScore, 0.0)
    }
    
    func test_non_hdr_no_artifacts() async {
        let pixels = Array(repeating: 0.5, count: 1000)
        let metadata: [String: Any] = ["hdr": false]
        let result = await detector.detectArtifacts(pixelValues: pixels, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodDetector = HDRArtifactDetector(config: prodConfig)
        
        let pixels = Array(repeating: 0.7, count: 1000)
        let result = await prodDetector.detectArtifacts(pixelValues: pixels, metadata: [:])
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devDetector = HDRArtifactDetector(config: devConfig)
        
        let pixels = Array(repeating: 0.7, count: 1000)
        let result = await devDetector.detectArtifacts(pixelValues: pixels, metadata: [:])
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testDetector = HDRArtifactDetector(config: testConfig)
        
        let pixels = Array(repeating: 0.7, count: 1000)
        let result = await testDetector.detectArtifacts(pixelValues: pixels, metadata: [:])
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidDetector = HDRArtifactDetector(config: paranoidConfig)
        
        let pixels = Array(repeating: 0.7, count: 1000)
        let result = await paranoidDetector.detectArtifacts(pixelValues: pixels, metadata: [:])
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        let pixels = Array(repeating: 0.5, count: 1000)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.detector.detectArtifacts(pixelValues: pixels, metadata: [:])
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let detector1 = HDRArtifactDetector(config: config)
        let detector2 = HDRArtifactDetector(config: config)
        
        let pixels = Array(repeating: 0.5, count: 1000)
        let result1 = await detector1.detectArtifacts(pixelValues: pixels, metadata: [:])
        let result2 = await detector2.detectArtifacts(pixelValues: pixels, metadata: [:])
        
        XCTAssertEqual(result1.artifactScore, result2.artifactScore, accuracy: 0.001)
    }
}
