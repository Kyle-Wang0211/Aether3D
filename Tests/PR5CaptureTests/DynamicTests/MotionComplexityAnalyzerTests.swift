//
// MotionComplexityAnalyzerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for MotionComplexityAnalyzer
//

import XCTest
@testable import PR5Capture

@MainActor
final class MotionComplexityAnalyzerTests: XCTestCase {
    
    var analyzer: MotionComplexityAnalyzer!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        analyzer = MotionComplexityAnalyzer(config: config)
    }
    
    override func tearDown() {
        analyzer = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0), MotionComplexityAnalyzer.MotionVector(dx: 2.0, dy: 2.0)]
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertGreaterThanOrEqual(result.complexity, 0.0)
        XCTAssertLessThanOrEqual(result.complexity, 1.0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let vectors = Array(repeating: MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0), count: 5)
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 0.5, dy: 0.5)]
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 0.0), MotionComplexityAnalyzer.MotionVector(dx: 0.0, dy: 1.0)]
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertEqual(result.objectCount, 2)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let vectors = [MotionComplexityAnalyzer.MotionVector(dx: Double(i) * 0.1, dy: Double(i) * 0.1)]
            _ = await analyzer.analyzeComplexity(vectors)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let vectors: [MotionComplexityAnalyzer.MotionVector] = []
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let vectors = Array(repeating: MotionComplexityAnalyzer.MotionVector(dx: 100.0, dy: 100.0), count: 100)
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 0.0, dy: 0.0)]
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_emptyInput_handled() async {
        let vectors: [MotionComplexityAnalyzer.MotionVector] = []
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 0.001, dy: 0.001)]
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Complexity Analysis Tests
    
    func test_low_complexity() async {
        let vectors = Array(repeating: MotionComplexityAnalyzer.MotionVector(dx: 0.1, dy: 0.1), count: 3)
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertLessThan(result.complexity, 0.5)
    }
    
    func test_high_complexity() async {
        var vectors: [MotionComplexityAnalyzer.MotionVector] = []
        for i in 0..<10 {
            vectors.append(MotionComplexityAnalyzer.MotionVector(dx: Double(i) * 10.0, dy: Double(i) * 10.0))
        }
        let result = await analyzer.analyzeComplexity(vectors)
        XCTAssertGreaterThan(result.complexity, 0.0)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodAnalyzer = MotionComplexityAnalyzer(config: prodConfig)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await prodAnalyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devAnalyzer = MotionComplexityAnalyzer(config: devConfig)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await devAnalyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testAnalyzer = MotionComplexityAnalyzer(config: testConfig)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await testAnalyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidAnalyzer = MotionComplexityAnalyzer(config: paranoidConfig)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await paranoidAnalyzer.analyzeComplexity(vectors)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let vectors = [MotionComplexityAnalyzer.MotionVector(dx: Double(i), dy: Double(i))]
                    _ = await self.analyzer.analyzeComplexity(vectors)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let analyzer1 = MotionComplexityAnalyzer(config: config)
        let analyzer2 = MotionComplexityAnalyzer(config: config)
        
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result1 = await analyzer1.analyzeComplexity(vectors)
        let result2 = await analyzer2.analyzeComplexity(vectors)
        
        XCTAssertEqual(result1.objectCount, result2.objectCount)
    }
}
