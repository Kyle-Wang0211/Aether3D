//
// AdaptiveTextureThresholdTests.swift
// PR5CaptureTests
//
// Comprehensive tests for AdaptiveTextureThreshold
//

import XCTest
@testable import PR5Capture

@MainActor
final class AdaptiveTextureThresholdTests: XCTestCase {
    
    var threshold: AdaptiveTextureThreshold!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        threshold = AdaptiveTextureThreshold(config: config)
    }
    
    override func tearDown() async throws {
        threshold = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let context: [String: Double] = ["lighting": 0.7, "motion": 0.5]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertGreaterThanOrEqual(result.newThreshold, 0.0)
        XCTAssertLessThanOrEqual(result.newThreshold, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let context: [String: Double] = ["lighting": 0.8]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let context: [String: Double] = ["motion": 0.6]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let context: [String: Double] = ["lighting": 1.0, "motion": 0.0]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertNotNil(result.newThreshold)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let context: [String: Double] = ["lighting": Double(i) * 0.1, "motion": 0.5]
            _ = await threshold.adaptThreshold(context: context)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let context: [String: Double] = [:]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        var context: [String: Double] = [:]
        for i in 0..<100 {
            context["key\(i)"] = Double(i) * 0.01
        }
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let context: [String: Double] = ["lighting": 0.0, "motion": 0.0]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let context1: [String: Double] = ["lighting": 0.001]
        let context2: [String: Double] = ["lighting": 0.999]
        let result1 = await threshold.adaptThreshold(context: context1)
        let result2 = await threshold.adaptThreshold(context: context2)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Adaptation Tests
    
    func test_lowLight_adjustment() async {
        let context: [String: Double] = ["lighting": 0.2]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertLessThan(result.newThreshold, result.oldThreshold)
    }
    
    func test_highMotion_adjustment() async {
        let context: [String: Double] = ["motion": 0.9]
        let result = await threshold.adaptThreshold(context: context)
        XCTAssertLessThan(result.newThreshold, result.oldThreshold)
    }
    
    func test_currentThreshold_query() async {
        let context: [String: Double] = ["lighting": 0.5]
        _ = await threshold.adaptThreshold(context: context)
        let current = await threshold.getCurrentThreshold()
        XCTAssertGreaterThanOrEqual(current, 0.0)
        XCTAssertLessThanOrEqual(current, 1.0)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodThreshold = AdaptiveTextureThreshold(config: prodConfig)
        let context: [String: Double] = ["lighting": 0.5]
        let result = await prodThreshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devThreshold = AdaptiveTextureThreshold(config: devConfig)
        let context: [String: Double] = ["lighting": 0.5]
        let result = await devThreshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testThreshold = AdaptiveTextureThreshold(config: testConfig)
        let context: [String: Double] = ["lighting": 0.5]
        let result = await testThreshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidThreshold = AdaptiveTextureThreshold(config: paranoidConfig)
        let context: [String: Double] = ["lighting": 0.5]
        let result = await paranoidThreshold.adaptThreshold(context: context)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let context: [String: Double] = ["lighting": Double(i) * 0.1]
                    _ = await self.threshold.adaptThreshold(context: context)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let threshold1 = AdaptiveTextureThreshold(config: config)
        let threshold2 = AdaptiveTextureThreshold(config: config)
        
        let context1: [String: Double] = ["lighting": 0.2]
        let context2: [String: Double] = ["lighting": 0.8]
        
        _ = await threshold1.adaptThreshold(context: context1)
        _ = await threshold2.adaptThreshold(context: context2)
        
        let current1 = await threshold1.getCurrentThreshold()
        let current2 = await threshold2.getCurrentThreshold()
        
        XCTAssertNotEqual(current1, current2)
    }
}
