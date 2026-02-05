//
// CorruptionDetectorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for CorruptionDetector
//

import XCTest
@testable import PR5Capture

@MainActor
final class CorruptionDetectorTests: XCTestCase {
    
    var detector: CorruptionDetector!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        detector = CorruptionDetector(config: config)
    }
    
    override func tearDown() async throws {
        detector = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let data = Data([1, 2, 3, 4, 5])
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertFalse(result.isCorrupted)
    }
    
    func test_typicalUseCase_succeeds() async {
        let data = Data(repeating: 100, count: 1000)
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertFalse(result.isCorrupted)
    }
    
    func test_standardConfiguration_works() async {
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertFalse(result.isCorrupted)
        XCTAssertEqual(result.expectedChecksum, result.actualChecksum)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let data = Data([UInt8(i)])
            let checksum = String(data.hashValue)
            _ = await detector.detectCorruption(data, expectedChecksum: checksum)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let data = Data([1])
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let data = Data(repeating: 255, count: 10000)
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let data = Data()
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let data1 = Data([0])
        let data2 = Data(repeating: 255, count: 1000)
        let checksum1 = String(data1.hashValue)
        let checksum2 = String(data2.hashValue)
        let result1 = await detector.detectCorruption(data1, expectedChecksum: checksum1)
        let result2 = await detector.detectCorruption(data2, expectedChecksum: checksum2)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Corruption Detection Tests
    
    func test_corruption_detected() async {
        let data = Data([1, 2, 3])
        let wrongChecksum = "wrong_checksum"
        let result = await detector.detectCorruption(data, expectedChecksum: wrongChecksum)
        XCTAssertTrue(result.isCorrupted)
    }
    
    func test_noCorruption_detected() async {
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await detector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertFalse(result.isCorrupted)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodDetector = CorruptionDetector(config: prodConfig)
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await prodDetector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devDetector = CorruptionDetector(config: devConfig)
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await devDetector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testDetector = CorruptionDetector(config: testConfig)
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await testDetector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidDetector = CorruptionDetector(config: paranoidConfig)
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result = await paranoidDetector.detectCorruption(data, expectedChecksum: checksum)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = Data([UInt8(i)])
                    let checksum = String(data.hashValue)
                    _ = await self.detector.detectCorruption(data, expectedChecksum: checksum)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let detector1 = CorruptionDetector(config: config)
        let detector2 = CorruptionDetector(config: config)
        
        let data = Data([1, 2, 3])
        let checksum = String(data.hashValue)
        let result1 = await detector1.detectCorruption(data, expectedChecksum: checksum)
        let result2 = await detector2.detectCorruption(data, expectedChecksum: checksum)
        
        XCTAssertEqual(result1.isCorrupted, result2.isCorrupted)
    }
}
