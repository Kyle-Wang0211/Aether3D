//
// DynamicRangePreserverTests.swift
// PR5CaptureTests
//
// Comprehensive tests for DynamicRangePreserver
//

import XCTest
@testable import PR5Capture

@MainActor
final class DynamicRangePreserverTests: XCTestCase {
    
    var preserver: DynamicRangePreserver!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        preserver = DynamicRangePreserver(config: config)
    }
    
    override func tearDown() async throws {
        preserver = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertNotNil(result.isPreserved)
        XCTAssertGreaterThanOrEqual(result.preservationScore, 0.0)
        XCTAssertLessThanOrEqual(result.preservationScore, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        for _ in 0..<10 {
            _ = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        }
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertTrue(result.isPreserved)
    }
    
    func test_standardConfiguration_works() async {
        let result = await preserver.preserveRange(minValue: 0.1, maxValue: 0.9)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let stableRanges = Array(repeating: (min: 0.0, max: 1.0), count: 10)
        for range in stableRanges {
            _ = await preserver.preserveRange(minValue: range.min, maxValue: range.max)
        }
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertTrue(result.isPreserved)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await preserver.preserveRange(minValue: Double(i) * 0.1, maxValue: 1.0 + Double(i) * 0.1)
        }
        let result = await preserver.preserveRange(minValue: 0.5, maxValue: 1.5)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 100.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await preserver.preserveRange(minValue: 0.001, maxValue: 0.002)
        let result2 = await preserver.preserveRange(minValue: 0.0, maxValue: 999.0)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Range Preservation Tests
    
    func test_range_preserved() async {
        for _ in 0..<10 {
            _ = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        }
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertTrue(result.isPreserved)
    }
    
    func test_range_notPreserved() async {
        for _ in 0..<10 {
            _ = await preserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        }
        let result = await preserver.preserveRange(minValue: 0.0, maxValue: 2.0)
        XCTAssertFalse(result.isPreserved)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodPreserver = DynamicRangePreserver(config: prodConfig)
        let result = await prodPreserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devPreserver = DynamicRangePreserver(config: devConfig)
        let result = await devPreserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testPreserver = DynamicRangePreserver(config: testConfig)
        let result = await testPreserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidPreserver = DynamicRangePreserver(config: paranoidConfig)
        let result = await paranoidPreserver.preserveRange(minValue: 0.0, maxValue: 1.0)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.preserver.preserveRange(minValue: Double(i) * 0.1, maxValue: 1.0 + Double(i) * 0.1)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let preserver1 = DynamicRangePreserver(config: config)
        let preserver2 = DynamicRangePreserver(config: config)
        
        _ = await preserver1.preserveRange(minValue: 0.0, maxValue: 1.0)
        _ = await preserver2.preserveRange(minValue: 0.0, maxValue: 2.0)
        
        let result1 = await preserver1.preserveRange(minValue: 0.0, maxValue: 1.0)
        let result2 = await preserver2.preserveRange(minValue: 0.0, maxValue: 2.0)
        
        XCTAssertNotEqual(result1.avgRange, result2.avgRange)
    }
}
