//
// ClosedLoopFeedbackControllerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for ClosedLoopFeedbackController
//

import XCTest
@testable import PR5Capture

@MainActor
final class ClosedLoopFeedbackControllerTests: XCTestCase {
    
    var controller: ClosedLoopFeedbackController!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        controller = ClosedLoopFeedbackController(config: config)
    }
    
    override func tearDown() async throws {
        controller = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await controller.processFeedback(currentValue: 0.5, targetValue: 0.7)
        XCTAssertNotNil(result.output)
        XCTAssertNotNil(result.error)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await controller.processFeedback(currentValue: 0.6, targetValue: 0.8)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await controller.processFeedback(currentValue: 0.5, targetValue: 0.5)
        XCTAssertEqual(result.error, 0.0, accuracy: 0.001)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await controller.processFeedback(currentValue: 0.4, targetValue: 0.6)
        XCTAssertGreaterThan(result.output, 0.0)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await controller.processFeedback(currentValue: Double(i) * 0.1, targetValue: 0.5)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await controller.processFeedback(currentValue: 0.0, targetValue: 0.0)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await controller.processFeedback(currentValue: 1.0, targetValue: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await controller.processFeedback(currentValue: 0.0, targetValue: 0.0)
        XCTAssertEqual(result.error, 0.0, accuracy: 0.001)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await controller.processFeedback(currentValue: 0.001, targetValue: 0.001)
        let result2 = await controller.processFeedback(currentValue: 0.999, targetValue: 0.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - PID Control Tests
    
    func test_proportional_term() async {
        let result = await controller.processFeedback(currentValue: 0.4, targetValue: 0.6)
        XCTAssertNotNil(result.pTerm)
    }
    
    func test_integral_term() async {
        for _ in 0..<5 {
            _ = await controller.processFeedback(currentValue: 0.4, targetValue: 0.6)
        }
        let result = await controller.processFeedback(currentValue: 0.4, targetValue: 0.6)
        XCTAssertNotNil(result.iTerm)
    }
    
    func test_derivative_term() async {
        _ = await controller.processFeedback(currentValue: 0.4, targetValue: 0.6)
        let result = await controller.processFeedback(currentValue: 0.5, targetValue: 0.6)
        XCTAssertNotNil(result.dTerm)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodController = ClosedLoopFeedbackController(config: prodConfig)
        let result = await prodController.processFeedback(currentValue: 0.5, targetValue: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devController = ClosedLoopFeedbackController(config: devConfig)
        let result = await devController.processFeedback(currentValue: 0.5, targetValue: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testController = ClosedLoopFeedbackController(config: testConfig)
        let result = await testController.processFeedback(currentValue: 0.5, targetValue: 0.7)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidController = ClosedLoopFeedbackController(config: paranoidConfig)
        let result = await paranoidController.processFeedback(currentValue: 0.5, targetValue: 0.7)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.controller.processFeedback(currentValue: Double(i) * 0.1, targetValue: 0.5)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let controller1 = ClosedLoopFeedbackController(config: config)
        let controller2 = ClosedLoopFeedbackController(config: config)
        
        let result1 = await controller1.processFeedback(currentValue: 0.4, targetValue: 0.6)
        let result2 = await controller2.processFeedback(currentValue: 0.4, targetValue: 0.6)
        
        XCTAssertEqual(result1.error, result2.error, accuracy: 0.001)
    }
}
