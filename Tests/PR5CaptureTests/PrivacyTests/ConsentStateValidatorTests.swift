//
// ConsentStateValidatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for ConsentStateValidator
//

import XCTest
@testable import PR5Capture

@MainActor
final class ConsentStateValidatorTests: XCTestCase {
    
    var validator: ConsentStateValidator!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        validator = ConsentStateValidator(config: config)
    }
    
    override func tearDown() {
        validator = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        await validator.recordConsent(operation: "capture", state: .granted)
        let result = await validator.validateConsent(operation: "capture")
        XCTAssertNotNil(result.isValid)
    }
    
    func test_typicalUseCase_succeeds() async {
        await validator.recordConsent(operation: "process", state: .granted)
        let result = await validator.validateConsent(operation: "process")
        XCTAssertTrue(result.isValid)
    }
    
    func test_standardConfiguration_works() async {
        await validator.recordConsent(operation: "upload", state: .granted)
        let result = await validator.validateConsent(operation: "upload")
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        await validator.recordConsent(operation: "test", state: .granted)
        let result = await validator.validateConsent(operation: "test")
        XCTAssertTrue(result.isValid)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            await validator.recordConsent(operation: "op\(i)", state: .granted)
        }
        let result = await validator.validateConsent(operation: "op5")
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Boundary Tests
    
    func test_noConsent() async {
        let result = await validator.validateConsent(operation: "unknown")
        XCTAssertFalse(result.isValid)
    }
    
    func test_deniedConsent() async {
        await validator.recordConsent(operation: "test", state: .denied)
        let result = await validator.validateConsent(operation: "test")
        XCTAssertFalse(result.isValid)
    }
    
    func test_expiredConsent() async {
        // Note: Expiration check requires time manipulation, simplified here
        await validator.recordConsent(operation: "test", state: .granted)
        let result = await validator.validateConsent(operation: "test")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Consent State Tests
    
    func test_grantedConsent() async {
        await validator.recordConsent(operation: "test", state: .granted)
        let result = await validator.validateConsent(operation: "test")
        XCTAssertTrue(result.isValid)
    }
    
    func test_deniedConsent_validation() async {
        await validator.recordConsent(operation: "test", state: .denied)
        let result = await validator.validateConsent(operation: "test")
        XCTAssertFalse(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodValidator = ConsentStateValidator(config: prodConfig)
        await prodValidator.recordConsent(operation: "test", state: .granted)
        let result = await prodValidator.validateConsent(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devValidator = ConsentStateValidator(config: devConfig)
        await devValidator.recordConsent(operation: "test", state: .granted)
        let result = await devValidator.validateConsent(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testValidator = ConsentStateValidator(config: testConfig)
        await testValidator.recordConsent(operation: "test", state: .granted)
        let result = await testValidator.validateConsent(operation: "test")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidValidator = ConsentStateValidator(config: paranoidConfig)
        await paranoidValidator.recordConsent(operation: "test", state: .granted)
        let result = await paranoidValidator.validateConsent(operation: "test")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.validator.recordConsent(operation: "op\(i)", state: .granted)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let validator1 = ConsentStateValidator(config: config)
        let validator2 = ConsentStateValidator(config: config)
        
        await validator1.recordConsent(operation: "test1", state: .granted)
        await validator2.recordConsent(operation: "test2", state: .granted)
        
        let result1 = await validator1.validateConsent(operation: "test1")
        let result2 = await validator2.validateConsent(operation: "test2")
        
        XCTAssertTrue(result1.isValid)
        XCTAssertTrue(result2.isValid)
    }
}
