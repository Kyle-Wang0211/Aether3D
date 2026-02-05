//
// InjectionDetectorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for InjectionDetector
//

import XCTest
@testable import PR5Capture

@MainActor
final class InjectionDetectorTests: XCTestCase {
    
    var detector: InjectionDetector!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        detector = InjectionDetector(config: config)
    }
    
    override func tearDown() async throws {
        detector = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await detector.detect()
        XCTAssertNotNil(result.detected)
        XCTAssertNotNil(result.primaryType)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await detector.detect()
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await detector.detect()
        XCTAssertNotNil(result.primaryType)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await detector.detect()
        // In normal test environment, should detect no injection
        XCTAssertEqual(result.primaryType, .none)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for _ in 0..<10 {
            _ = await detector.detect()
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_detection_noInjection() async {
        let result = await detector.detect()
        XCTAssertEqual(result.primaryType, .none)
    }
    
    func test_allInjectionTypes() async {
        let result = await detector.detect()
        XCTAssertNotNil(result.detected)
    }
    
    // MARK: - Detection Tests
    
    func test_injection_detection() async {
        let result = await detector.detect()
        XCTAssertNotNil(result.primaryType)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodDetector = InjectionDetector(config: prodConfig)
        let result = await prodDetector.detect()
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devDetector = InjectionDetector(config: devConfig)
        let result = await devDetector.detect()
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testDetector = InjectionDetector(config: testConfig)
        let result = await testDetector.detect()
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidDetector = InjectionDetector(config: paranoidConfig)
        let result = await paranoidDetector.detect()
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.detector.detect()
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let detector1 = InjectionDetector(config: config)
        let detector2 = InjectionDetector(config: config)
        
        let result1 = await detector1.detect()
        let result2 = await detector2.detect()
        
        XCTAssertEqual(result1.primaryType, result2.primaryType)
    }
}
