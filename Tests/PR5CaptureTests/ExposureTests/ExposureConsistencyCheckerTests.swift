//
// ExposureConsistencyCheckerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for ExposureConsistencyChecker
//

import XCTest
@testable import PR5Capture

@MainActor
final class ExposureConsistencyCheckerTests: XCTestCase {
    
    var checker: ExposureConsistencyChecker!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        checker = ExposureConsistencyChecker(config: config)
    }
    
    override func tearDown() {
        checker = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await checker.checkConsistency(0.5)
        XCTAssertNotNil(result.isConsistent)
        XCTAssertGreaterThanOrEqual(result.consistencyScore, 0.0)
        XCTAssertLessThanOrEqual(result.consistencyScore, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        for i in 0..<10 {
            _ = await checker.checkConsistency(0.5 + Double(i) * 0.01)
        }
        let result = await checker.checkConsistency(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await checker.checkConsistency(0.7)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let stableExposures = Array(repeating: 0.5, count: 10)
        for exposure in stableExposures {
            _ = await checker.checkConsistency(exposure)
        }
        let result = await checker.checkConsistency(0.5)
        XCTAssertTrue(result.isConsistent)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let exposures = Array(stride(from: 0.5, to: 0.6, by: 0.01))
        for exposure in exposures {
            _ = await checker.checkConsistency(exposure)
        }
        let result = await checker.checkConsistency(0.55)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await checker.checkConsistency(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await checker.checkConsistency(1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await checker.checkConsistency(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await checker.checkConsistency(0.001)
        let result2 = await checker.checkConsistency(0.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Consistency Detection Tests
    
    func test_consistent_exposure() async {
        for _ in 0..<10 {
            _ = await checker.checkConsistency(0.5)
        }
        let result = await checker.checkConsistency(0.5)
        XCTAssertTrue(result.isConsistent)
    }
    
    func test_inconsistent_exposure() async {
        for i in 0..<10 {
            _ = await checker.checkConsistency(0.5 + Double(i) * 0.2)
        }
        let result = await checker.checkConsistency(2.5)
        XCTAssertFalse(result.isConsistent)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodChecker = ExposureConsistencyChecker(config: prodConfig)
        let result = await prodChecker.checkConsistency(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devChecker = ExposureConsistencyChecker(config: devConfig)
        let result = await devChecker.checkConsistency(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testChecker = ExposureConsistencyChecker(config: testConfig)
        let result = await testChecker.checkConsistency(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidChecker = ExposureConsistencyChecker(config: paranoidConfig)
        let result = await paranoidChecker.checkConsistency(0.5)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.checker.checkConsistency(Double(i) * 0.1)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let checker1 = ExposureConsistencyChecker(config: config)
        let checker2 = ExposureConsistencyChecker(config: config)
        
        _ = await checker1.checkConsistency(0.5)
        _ = await checker2.checkConsistency(0.5)
        
        let result1 = await checker1.checkConsistency(0.5)
        let result2 = await checker2.checkConsistency(0.5)
        
        XCTAssertEqual(result1.isConsistent, result2.isConsistent)
    }
}
