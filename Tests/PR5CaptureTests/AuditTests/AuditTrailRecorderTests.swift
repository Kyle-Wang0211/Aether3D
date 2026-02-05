//
// AuditTrailRecorderTests.swift
// PR5CaptureTests
//
// Comprehensive tests for AuditTrailRecorder
//

import XCTest
@testable import PR5Capture

@MainActor
final class AuditTrailRecorderTests: XCTestCase {
    
    var recorder: AuditTrailRecorder!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        recorder = AuditTrailRecorder(config: config)
    }
    
    override func tearDown() async throws {
        recorder = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(),
            operation: "test_operation",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry)
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_typicalUseCase_succeeds() async {
        let entry = AuditTrailRecorder.AuditEntry(
            operation: "capture",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry)
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_standardConfiguration_works() async {
        let entry = AuditTrailRecorder.AuditEntry(
            operation: "process",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry)
        let result = await recorder.verifyIntegrity()
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(), operation: "test",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry)
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.invalidEntries.count, 0)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let entry = AuditTrailRecorder.AuditEntry(
                operation: "operation\(i)",
                userId: "user1",
                result: "success"
            )
            await recorder.recordEntry(entry)
        }
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Boundary Tests
    
    func test_emptyTrail() async {
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_singleEntry() async {
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(), operation: "test",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry)
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_largeTrail() async {
        for i in 0..<100 {
            let entry = AuditTrailRecorder.AuditEntry(
                operation: "operation\(i)",
                userId: "user1",
                result: "success"
            )
            await recorder.recordEntry(entry)
        }
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Integrity Tests
    
    func test_integrity_verification() async {
        let entry1 = AuditTrailRecorder.AuditEntry(
            operation: "operation1",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry1)
        
        let entry2 = AuditTrailRecorder.AuditEntry(
            operation: "operation2",
            userId: "user1",
            result: "success"
        )
        await recorder.recordEntry(entry2)
        
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodRecorder = AuditTrailRecorder(config: prodConfig)
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(), operation: "test",
            userId: "user1",
            result: "success"
        )
        await prodRecorder.recordEntry(entry)
        let result = await prodRecorder.verifyIntegrity()
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devRecorder = AuditTrailRecorder(config: devConfig)
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(), operation: "test",
            userId: "user1",
            result: "success"
        )
        await devRecorder.recordEntry(entry)
        let result = await devRecorder.verifyIntegrity()
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testRecorder = AuditTrailRecorder(config: testConfig)
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(), operation: "test",
            userId: "user1",
            result: "success"
        )
        await testRecorder.recordEntry(entry)
        let result = await testRecorder.verifyIntegrity()
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidRecorder = AuditTrailRecorder(config: paranoidConfig)
        let entry = AuditTrailRecorder.AuditEntry(
            timestamp: Date(), operation: "test",
            userId: "user1",
            result: "success"
        )
        await paranoidRecorder.recordEntry(entry)
        let result = await paranoidRecorder.verifyIntegrity()
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let entry = AuditTrailRecorder.AuditEntry(
                        operation: "operation\(i)",
                        userId: "user1",
                        result: "success"
                    )
                    await self.recorder.recordEntry(entry)
                }
            }
        }
        let result = await recorder.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_multipleInstances_independent() async {
        let recorder1 = AuditTrailRecorder(config: config)
        let recorder2 = AuditTrailRecorder(config: config)
        
        let entry1 = AuditTrailRecorder.AuditEntry(
            operation: "operation1",
            userId: "user1",
            result: "success"
        )
        let entry2 = AuditTrailRecorder.AuditEntry(
            operation: "operation2",
            userId: "user2",
            result: "success"
        )
        
        await recorder1.recordEntry(entry1)
        await recorder2.recordEntry(entry2)
        
        let result1 = await recorder1.verifyIntegrity()
        let result2 = await recorder2.verifyIntegrity()
        
        XCTAssertTrue(result1.isValid)
        XCTAssertTrue(result2.isValid)
    }
}
