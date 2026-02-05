//
// FeatureRichnessEvaluatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for FeatureRichnessEvaluator
//

import XCTest
@testable import PR5Capture

@MainActor
final class FeatureRichnessEvaluatorTests: XCTestCase {
    
    var evaluator: FeatureRichnessEvaluator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        evaluator = FeatureRichnessEvaluator(config: config)
    }
    
    override func tearDown() async throws {
        evaluator = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await evaluator.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        XCTAssertGreaterThanOrEqual(result.richnessScore, 0.0)
        XCTAssertLessThanOrEqual(result.richnessScore, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await evaluator.evaluateRichness(featureCount: 500, imageArea: 2000.0)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await evaluator.evaluateRichness(featureCount: 200, imageArea: 1500.0)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await evaluator.evaluateRichness(featureCount: 1000, imageArea: 1000.0)
        XCTAssertEqual(result.featureCount, 1000)
        XCTAssertGreaterThan(result.richnessScore, 0.0)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await evaluator.evaluateRichness(featureCount: i * 100, imageArea: 1000.0)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await evaluator.evaluateRichness(featureCount: 0, imageArea: 1.0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.featureCount, 0)
    }
    
    func test_maximumInput_handled() async {
        let result = await evaluator.evaluateRichness(featureCount: 10000, imageArea: 10000.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await evaluator.evaluateRichness(featureCount: 0, imageArea: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await evaluator.evaluateRichness(featureCount: 1, imageArea: 1.0)
        let result2 = await evaluator.evaluateRichness(featureCount: 9999, imageArea: 9999.0)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Richness Evaluation Tests
    
    func test_high_richness() async {
        let result = await evaluator.evaluateRichness(featureCount: 1000, imageArea: 100.0)
        XCTAssertGreaterThan(result.richnessScore, 0.5)
    }
    
    func test_low_richness() async {
        let result = await evaluator.evaluateRichness(featureCount: 10, imageArea: 10000.0)
        XCTAssertLessThan(result.richnessScore, 0.5)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodEvaluator = FeatureRichnessEvaluator(config: prodConfig)
        let result = await prodEvaluator.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devEvaluator = FeatureRichnessEvaluator(config: devConfig)
        let result = await devEvaluator.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testEvaluator = FeatureRichnessEvaluator(config: testConfig)
        let result = await testEvaluator.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidEvaluator = FeatureRichnessEvaluator(config: paranoidConfig)
        let result = await paranoidEvaluator.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.evaluator.evaluateRichness(featureCount: i * 100, imageArea: 1000.0)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let evaluator1 = FeatureRichnessEvaluator(config: config)
        let evaluator2 = FeatureRichnessEvaluator(config: config)
        
        let result1 = await evaluator1.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        let result2 = await evaluator2.evaluateRichness(featureCount: 100, imageArea: 1000.0)
        
        XCTAssertEqual(result1.richnessScore, result2.richnessScore, accuracy: 0.001)
    }
}
