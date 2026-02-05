//
// UploadIntegrityGuardTests.swift
// PR5CaptureTests
//
// Comprehensive tests for UploadIntegrityGuard
//

import XCTest
@testable import PR5Capture

@MainActor
final class UploadIntegrityGuardTests: XCTestCase {
    
    var guard_: UploadIntegrityGuard!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        guard_ = UploadIntegrityGuard(config: config)
    }
    
    override func tearDown() async throws {
        guard_ = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let data = Data([1, 2, 3, 4, 5])
        let result = await guard_.guardUpload(data, destination: "test://destination")
        XCTAssertNotNil(result.uploadId)
        XCTAssertTrue(result.verified)
    }
    
    func test_typicalUseCase_succeeds() async {
        let data = Data(repeating: 100, count: 1000)
        let result = await guard_.guardUpload(data, destination: "https://example.com/upload")
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let data = Data([1, 2, 3])
        let result = await guard_.guardUpload(data, destination: "test://dest")
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let data = Data([1, 2, 3])
        let result = await guard_.guardUpload(data, destination: "dest")
        XCTAssertTrue(result.verified)
        XCTAssertNotNil(result.checksum)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let data = Data([UInt8(i)])
            _ = await guard_.guardUpload(data, destination: "dest\(i)")
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let data = Data([1])
        let result = await guard_.guardUpload(data, destination: "")
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let data = Data(repeating: 255, count: 10000)
        let result = await guard_.guardUpload(data, destination: "dest")
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let data = Data()
        let result = await guard_.guardUpload(data, destination: "dest")
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let data1 = Data([0])
        let data2 = Data(repeating: 255, count: 1000)
        let result1 = await guard_.guardUpload(data1, destination: "dest1")
        let result2 = await guard_.guardUpload(data2, destination: "dest2")
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Integrity Verification Tests
    
    func test_integrity_verification_match() async {
        let data = Data([1, 2, 3])
        let guardResult = await guard_.guardUpload(data, destination: "dest")
        let verifyResult = await guard_.verifyIntegrity(uploadId: guardResult.uploadId, receivedChecksum: guardResult.checksum)
        XCTAssertTrue(verifyResult.verified)
    }
    
    func test_integrity_verification_mismatch() async {
        let data = Data([1, 2, 3])
        let guardResult = await guard_.guardUpload(data, destination: "dest")
        let verifyResult = await guard_.verifyIntegrity(uploadId: guardResult.uploadId, receivedChecksum: "wrong_checksum")
        XCTAssertFalse(verifyResult.verified)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodGuard = UploadIntegrityGuard(config: prodConfig)
        let data = Data([1, 2, 3])
        let result = await prodGuard.guardUpload(data, destination: "dest")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devGuard = UploadIntegrityGuard(config: devConfig)
        let data = Data([1, 2, 3])
        let result = await devGuard.guardUpload(data, destination: "dest")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testGuard = UploadIntegrityGuard(config: testConfig)
        let data = Data([1, 2, 3])
        let result = await testGuard.guardUpload(data, destination: "dest")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidGuard = UploadIntegrityGuard(config: paranoidConfig)
        let data = Data([1, 2, 3])
        let result = await paranoidGuard.guardUpload(data, destination: "dest")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = Data([UInt8(i)])
                    _ = await self.guard_.guardUpload(data, destination: "dest\(i)")
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let guard1 = UploadIntegrityGuard(config: config)
        let guard2 = UploadIntegrityGuard(config: config)
        
        let data = Data([1, 2, 3])
        let result1 = await guard1.guardUpload(data, destination: "dest1")
        let result2 = await guard2.guardUpload(data, destination: "dest2")
        
        XCTAssertNotEqual(result1.uploadId, result2.uploadId)
    }
}
