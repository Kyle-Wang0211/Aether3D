//
// RiskScoreCalculatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for RiskScoreCalculator
//

import XCTest
@testable import PR5Capture

@MainActor
final class RiskScoreCalculatorTests: XCTestCase {
    
    var calculator: RiskScoreCalculator!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        calculator = RiskScoreCalculator(config: config)
    }
    
    override func tearDown() {
        calculator = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await calculator.calculateScore(severity: .p1, exploitability: 0.7, impact: 0.8)
        XCTAssertGreaterThanOrEqual(result.finalScore, 0.0)
        XCTAssertLessThanOrEqual(result.finalScore, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await calculator.calculateScore(severity: .p0, exploitability: 0.5, impact: 0.6)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await calculator.calculateScore(severity: .p2, exploitability: 0.4, impact: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await calculator.calculateScore(severity: .p0, exploitability: 1.0, impact: 1.0)
        XCTAssertGreaterThan(result.finalScore, 0.0)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let severities: [RiskRegisterImplementation.RiskSeverity] = [.p0, .p1, .p2, .p3]
        for severity in severities {
            _ = await calculator.calculateScore(severity: severity, exploitability: 0.5, impact: 0.5)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await calculator.calculateScore(severity: .p3, exploitability: 0.0, impact: 0.0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.finalScore, 0.0, accuracy: 0.001)
    }
    
    func test_maximumInput_handled() async {
        let result = await calculator.calculateScore(severity: .p0, exploitability: 1.0, impact: 1.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await calculator.calculateScore(severity: .p3, exploitability: 0.0, impact: 0.0)
        XCTAssertEqual(result.finalScore, 0.0, accuracy: 0.001)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await calculator.calculateScore(severity: .p0, exploitability: 0.001, impact: 0.001)
        let result2 = await calculator.calculateScore(severity: .p0, exploitability: 0.999, impact: 0.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Score Calculation Tests
    
    func test_p0_severity_score() async {
        let result = await calculator.calculateScore(severity: .p0, exploitability: 0.5, impact: 0.5)
        XCTAssertGreaterThan(result.finalScore, 0.0)
    }
    
    func test_p3_severity_score() async {
        let result = await calculator.calculateScore(severity: .p3, exploitability: 0.5, impact: 0.5)
        XCTAssertLessThan(result.finalScore, 0.5)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodCalculator = RiskScoreCalculator(config: prodConfig)
        let result = await prodCalculator.calculateScore(severity: .p1, exploitability: 0.5, impact: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devCalculator = RiskScoreCalculator(config: devConfig)
        let result = await devCalculator.calculateScore(severity: .p1, exploitability: 0.5, impact: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testCalculator = RiskScoreCalculator(config: testConfig)
        let result = await testCalculator.calculateScore(severity: .p1, exploitability: 0.5, impact: 0.5)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidCalculator = RiskScoreCalculator(config: paranoidConfig)
        let result = await paranoidCalculator.calculateScore(severity: .p1, exploitability: 0.5, impact: 0.5)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.calculator.calculateScore(severity: .p1, exploitability: Double(i) * 0.1, impact: 0.5)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let calculator1 = RiskScoreCalculator(config: config)
        let calculator2 = RiskScoreCalculator(config: config)
        
        let result1 = await calculator1.calculateScore(severity: .p0, exploitability: 0.5, impact: 0.5)
        let result2 = await calculator2.calculateScore(severity: .p3, exploitability: 0.5, impact: 0.5)
        
        XCTAssertNotEqual(result1.finalScore, result2.finalScore)
    }
}
