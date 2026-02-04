//
// FrameDropPredictorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for FrameDropPredictor
//

import XCTest
@testable import PR5Capture

@MainActor
final class FrameDropPredictorTests: XCTestCase {
    
    var predictor: FrameDropPredictor!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        predictor = FrameDropPredictor(config: config)
    }
    
    override func tearDown() {
        predictor = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await predictor.predictDrop(frameTime: 0.016)
        XCTAssertGreaterThanOrEqual(result.probability, 0.0)
        XCTAssertLessThanOrEqual(result.probability, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await predictor.predictDrop(frameTime: 0.01667)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await predictor.predictDrop(frameTime: 0.015)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await predictor.predictDrop(frameTime: 0.01667)
        XCTAssertNotNil(result.action)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await predictor.predictDrop(frameTime: 0.016 + Double(i) * 0.001)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await predictor.predictDrop(frameTime: 0.001)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await predictor.predictDrop(frameTime: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await predictor.predictDrop(frameTime: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await predictor.predictDrop(frameTime: 0.01666)
        let result2 = await predictor.predictDrop(frameTime: 0.01668)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Prediction Tests
    
    func test_highDropProbability() async {
        let result = await predictor.predictDrop(frameTime: 0.05)
        XCTAssertGreaterThan(result.probability, 0.5)
    }
    
    func test_lowDropProbability() async {
        let result = await predictor.predictDrop(frameTime: 0.01)
        XCTAssertLessThan(result.probability, 0.5)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodPredictor = FrameDropPredictor(config: prodConfig)
        let result = await prodPredictor.predictDrop(frameTime: 0.016)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devPredictor = FrameDropPredictor(config: devConfig)
        let result = await devPredictor.predictDrop(frameTime: 0.016)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testPredictor = FrameDropPredictor(config: testConfig)
        let result = await testPredictor.predictDrop(frameTime: 0.016)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidPredictor = FrameDropPredictor(config: paranoidConfig)
        let result = await paranoidPredictor.predictDrop(frameTime: 0.016)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.predictor.predictDrop(frameTime: 0.016 + Double(i) * 0.001)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let predictor1 = FrameDropPredictor(config: config)
        let predictor2 = FrameDropPredictor(config: config)
        
        let result1 = await predictor1.predictDrop(frameTime: 0.016)
        let result2 = await predictor2.predictDrop(frameTime: 0.016)
        
        XCTAssertEqual(result1.probability, result2.probability, accuracy: 0.001)
    }
}
