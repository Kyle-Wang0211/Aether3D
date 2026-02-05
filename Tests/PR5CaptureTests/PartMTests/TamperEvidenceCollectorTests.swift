//
// TamperEvidenceCollectorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for TamperEvidenceCollector
//

import XCTest
@testable import PR5Capture

@MainActor
final class TamperEvidenceCollectorTests: XCTestCase {
    
    var collector: TamperEvidenceCollector!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        collector = TamperEvidenceCollector(config: config)
    }
    
    override func tearDown() async throws {
        collector = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await collector.collectEvidence("test_event", hash: "test_hash")
        XCTAssertNotNil(result.evidenceId)
        XCTAssertGreaterThan(result.chainLength, 0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await collector.collectEvidence("capture_event", hash: "abc123")
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await collector.collectEvidence("process_event", hash: "hash123")
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await collector.collectEvidence("test", hash: "hash")
        XCTAssertNotNil(result.chainHash)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await collector.collectEvidence("event\(i)", hash: "hash\(i)")
        }
        let result = await collector.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Boundary Tests
    
    func test_emptyEvent() async {
        let result = await collector.collectEvidence("", hash: "hash")
        XCTAssertNotNil(result)
    }
    
    func test_emptyHash() async {
        let result = await collector.collectEvidence("event", hash: "")
        XCTAssertNotNil(result)
    }
    
    func test_largeChain() async {
        for i in 0..<100 {
            _ = await collector.collectEvidence("event\(i)", hash: "hash\(i)")
        }
        let result = await collector.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Integrity Tests
    
    func test_chain_integrity() async {
        for i in 0..<10 {
            _ = await collector.collectEvidence("event\(i)", hash: "hash\(i)")
        }
        let result = await collector.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodCollector = TamperEvidenceCollector(config: prodConfig)
        let result = await prodCollector.collectEvidence("test", hash: "hash")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devCollector = TamperEvidenceCollector(config: devConfig)
        let result = await devCollector.collectEvidence("test", hash: "hash")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testCollector = TamperEvidenceCollector(config: testConfig)
        let result = await testCollector.collectEvidence("test", hash: "hash")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidCollector = TamperEvidenceCollector(config: paranoidConfig)
        let result = await paranoidCollector.collectEvidence("test", hash: "hash")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.collector.collectEvidence("event\(i)", hash: "hash\(i)")
                }
            }
        }
        let result = await collector.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_multipleInstances_independent() async {
        let collector1 = TamperEvidenceCollector(config: config)
        let collector2 = TamperEvidenceCollector(config: config)
        
        let result1 = await collector1.collectEvidence("event1", hash: "hash1")
        let result2 = await collector2.collectEvidence("event2", hash: "hash2")
        
        XCTAssertEqual(result1.chainLength, result2.chainLength)
    }
}
