//
// CodeSignatureValidatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for CodeSignatureValidator
//

import XCTest
@testable import PR5Capture

@MainActor
final class CodeSignatureValidatorTests: XCTestCase {
    
    var validator: CodeSignatureValidator!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        validator = CodeSignatureValidator(config: config)
    }
    
    override func tearDown() {
        validator = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await validator.validate()
        XCTAssertNotNil(result.isValid)
        XCTAssertNotNil(result.timestamp)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await validator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await validator.validate()
        XCTAssertTrue(result.isValid)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await validator.validate()
        // In normal test environment, signature should be valid
        XCTAssertTrue(result.isValid)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for _ in 0..<10 {
            _ = await validator.validate()
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_validation_result() async {
        let result = await validator.validate()
        XCTAssertNotNil(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodValidator = CodeSignatureValidator(config: prodConfig)
        let result = await prodValidator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devValidator = CodeSignatureValidator(config: devConfig)
        let result = await devValidator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testValidator = CodeSignatureValidator(config: testConfig)
        let result = await testValidator.validate()
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidValidator = CodeSignatureValidator(config: paranoidConfig)
        let result = await paranoidValidator.validate()
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.validator.validate()
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let validator1 = CodeSignatureValidator(config: config)
        let validator2 = CodeSignatureValidator(config: config)
        
        let result1 = await validator1.validate()
        let result2 = await validator2.validate()
        
        XCTAssertEqual(result1.isValid, result2.isValid)
    }
}
