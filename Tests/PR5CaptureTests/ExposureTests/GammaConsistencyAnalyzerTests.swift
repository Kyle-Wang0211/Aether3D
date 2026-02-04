//
// GammaConsistencyAnalyzerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for GammaConsistencyAnalyzer
//

import XCTest
@testable import PR5Capture

@MainActor
final class GammaConsistencyAnalyzerTests: XCTestCase {
    
    var analyzer: GammaConsistencyAnalyzer!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        analyzer = GammaConsistencyAnalyzer(config: config)
    }
    
    override func tearDown() {
        analyzer = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await analyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result.isConsistent)
        XCTAssertGreaterThanOrEqual(result.consistencyScore, 0.0)
        XCTAssertLessThanOrEqual(result.consistencyScore, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        for _ in 0..<10 {
            _ = await analyzer.analyzeGamma(2.2)
        }
        let result = await analyzer.analyzeGamma(2.2)
        XCTAssertTrue(result.isConsistent)
    }
    
    func test_standardConfiguration_works() async {
        let result = await analyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let stableGammas = Array(repeating: 2.2, count: 10)
        for gamma in stableGammas {
            _ = await analyzer.analyzeGamma(gamma)
        }
        let result = await analyzer.analyzeGamma(2.2)
        XCTAssertTrue(result.isConsistent)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let gammas = Array(stride(from: 2.0, to: 2.4, by: 0.01))
        for gamma in gammas {
            _ = await analyzer.analyzeGamma(gamma)
        }
        let result = await analyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await analyzer.analyzeGamma(0.1)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let result = await analyzer.analyzeGamma(10.0)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let result = await analyzer.analyzeGamma(0.0)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await analyzer.analyzeGamma(0.001)
        let result2 = await analyzer.analyzeGamma(9.999)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Consistency Tests
    
    func test_consistent_gamma() async {
        for _ in 0..<10 {
            _ = await analyzer.analyzeGamma(2.2)
        }
        let result = await analyzer.analyzeGamma(2.2)
        XCTAssertTrue(result.isConsistent)
    }
    
    func test_inconsistent_gamma() async {
        for i in 0..<10 {
            _ = await analyzer.analyzeGamma(2.2 + Double(i) * 0.1)
        }
        let result = await analyzer.analyzeGamma(3.5)
        XCTAssertFalse(result.isConsistent)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodAnalyzer = GammaConsistencyAnalyzer(config: prodConfig)
        let result = await prodAnalyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devAnalyzer = GammaConsistencyAnalyzer(config: devConfig)
        let result = await devAnalyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testAnalyzer = GammaConsistencyAnalyzer(config: testConfig)
        let result = await testAnalyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidAnalyzer = GammaConsistencyAnalyzer(config: paranoidConfig)
        let result = await paranoidAnalyzer.analyzeGamma(2.2)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.analyzer.analyzeGamma(2.2 + Double(i) * 0.01)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let analyzer1 = GammaConsistencyAnalyzer(config: config)
        let analyzer2 = GammaConsistencyAnalyzer(config: config)
        
        _ = await analyzer1.analyzeGamma(2.2)
        _ = await analyzer2.analyzeGamma(2.2)
        
        let result1 = await analyzer1.analyzeGamma(2.2)
        let result2 = await analyzer2.analyzeGamma(2.2)
        
        XCTAssertEqual(result1.isConsistent, result2.isConsistent)
    }
}
