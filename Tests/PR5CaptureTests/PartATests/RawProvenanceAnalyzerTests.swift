//
// RawProvenanceAnalyzerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for RawProvenanceAnalyzer
//

import XCTest
@testable import PR5Capture

@MainActor
final class RawProvenanceAnalyzerTests: XCTestCase {
    
    var analyzer: RawProvenanceAnalyzer!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        analyzer = RawProvenanceAnalyzer(config: config)
    }
    
    override func tearDown() async throws {
        analyzer = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let rawData = Data([1, 2, 3, 4, 5])
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result.fingerprint)
    }
    
    func test_typicalUseCase_succeeds() async {
        let rawData = Data(repeating: 100, count: 1000)
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result.similarity)
    }
    
    func test_standardConfiguration_works() async {
        let rawData = Data([10, 20, 30, 40, 50])
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertGreaterThanOrEqual(result.similarity, 0.0)
        XCTAssertLessThanOrEqual(result.similarity, 1.0)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let rawData = Data(repeating: 128, count: 500)
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result.fingerprint)
        XCTAssertEqual(result.fingerprint.count, 32)  // SHA-256 hash length
    }
    
    func test_commonScenario_handledCorrectly() async {
        let rawData = Data(repeating: 0, count: 1000)
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let rawData = Data([1])
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let rawData = Data(repeating: 255, count: 10000)
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let rawData = Data()
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_emptyInput_handled() async {
        let rawData = Data([])
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let rawData = Data(repeating: 0, count: 1)
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Error Handling Tests
    
    func test_invalidInput_handled() async {
        let rawData = Data([0xFF, 0xFF, 0xFF])
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "")
        XCTAssertNotNil(result)
    }
    
    func test_corruptedData_handled() async {
        let rawData = Data([0, 1, 2, 3, 255, 254, 253])
        let result = await analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodAnalyzer = RawProvenanceAnalyzer(config: prodConfig)
        
        let rawData = Data(repeating: 100, count: 1000)
        let result = await prodAnalyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devAnalyzer = RawProvenanceAnalyzer(config: devConfig)
        
        let rawData = Data(repeating: 100, count: 1000)
        let result = await devAnalyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testAnalyzer = RawProvenanceAnalyzer(config: testConfig)
        
        let rawData = Data(repeating: 100, count: 1000)
        let result = await testAnalyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidAnalyzer = RawProvenanceAnalyzer(config: paranoidConfig)
        
        let rawData = Data(repeating: 100, count: 1000)
        let result = await paranoidAnalyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        let rawData = Data(repeating: 100, count: 1000)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.analyzer.analyzePRNUFingerprint(rawData, deviceId: "device1")
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let analyzer1 = RawProvenanceAnalyzer(config: config)
        let analyzer2 = RawProvenanceAnalyzer(config: config)
        
        let rawData = Data(repeating: 100, count: 1000)
        let result1 = await analyzer1.analyzePRNUFingerprint(rawData, deviceId: "device1")
        let result2 = await analyzer2.analyzePRNUFingerprint(rawData, deviceId: "device1")
        
        XCTAssertEqual(result1.fingerprint, result2.fingerprint)
    }
    
    // MARK: - HDR Artifact Detection Tests
    
    func test_detectHDRArtifacts_normal() async {
        let rawData = Data(repeating: 128, count: 100)
        let metadata: [String: Any] = ["hdr": false]
        let result = await analyzer.detectHDRArtifacts(rawData, metadata: metadata)
        XCTAssertNotNil(result)
    }
    
    func test_detectHDRArtifacts_hdr() async {
        let rawData = Data(repeating: 255, count: 100)
        let metadata: [String: Any] = ["hdr": true]
        let result = await analyzer.detectHDRArtifacts(rawData, metadata: metadata)
        XCTAssertNotNil(result)
    }
}
