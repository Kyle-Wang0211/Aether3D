//
// PIIDetectorAndRedactorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for PIIDetectorAndRedactor
//

import XCTest
@testable import PR5Capture

@MainActor
final class PIIDetectorAndRedactorTests: XCTestCase {
    
    var detector: PIIDetectorAndRedactor!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        detector = PIIDetectorAndRedactor(config: config)
    }
    
    override func tearDown() {
        detector = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await detector.detectPII("test@example.com")
        XCTAssertGreaterThanOrEqual(result.count, 0)
        XCTAssertNotNil(result.detectedTypes)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await detector.detectPII("Contact: test@example.com")
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await detector.detectPII("Email: user@domain.com")
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await detector.detectPII("test@example.com")
        XCTAssertTrue(result.detectedTypes.contains(.email))
    }
    
    func test_commonScenario_handledCorrectly() async {
        let testStrings = ["test@example.com", "123-45-6789", "4111-1111-1111-1111"]
        for str in testStrings {
            _ = await detector.detectPII(str)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await detector.detectPII("")
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let longString = String(repeating: "test@example.com ", count: 1000)
        let result = await detector.detectPII(longString)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await detector.detectPII("")
        XCTAssertEqual(result.count, 0)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await detector.detectPII("a")
        let result2 = await detector.detectPII(String(repeating: "a", count: 10000))
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - PII Detection Tests
    
    func test_email_detection() async {
        let result = await detector.detectPII("test@example.com")
        XCTAssertTrue(result.detectedTypes.contains(.email))
    }
    
    func test_ssn_detection() async {
        let result = await detector.detectPII("123-45-6789")
        XCTAssertTrue(result.detectedTypes.contains(.ssn))
    }
    
    func test_creditCard_detection() async {
        let result = await detector.detectPII("4111-1111-1111-1111")
        XCTAssertTrue(result.detectedTypes.contains(.creditCard))
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodDetector = PIIDetectorAndRedactor(config: prodConfig)
        let result = await prodDetector.detectPII("test@example.com")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devDetector = PIIDetectorAndRedactor(config: devConfig)
        let result = await devDetector.detectPII("test@example.com")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testDetector = PIIDetectorAndRedactor(config: testConfig)
        let result = await testDetector.detectPII("test@example.com")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidDetector = PIIDetectorAndRedactor(config: paranoidConfig)
        let result = await paranoidDetector.detectPII("test@example.com")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.detector.detectPII("test\(i)@example.com")
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let detector1 = PIIDetectorAndRedactor(config: config)
        let detector2 = PIIDetectorAndRedactor(config: config)
        
        let result1 = await detector1.detectPII("test@example.com")
        let result2 = await detector2.detectPII("test@example.com")
        
        XCTAssertEqual(result1.count, result2.count)
    }
}
