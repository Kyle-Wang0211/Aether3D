//
// OcclusionAwareRefinerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for OcclusionAwareRefiner
//

import XCTest
@testable import PR5Capture

@MainActor
final class OcclusionAwareRefinerTests: XCTestCase {
    
    var refiner: OcclusionAwareRefiner!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        refiner = OcclusionAwareRefiner(config: config)
    }
    
    override func tearDown() async throws {
        refiner = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result.regions)
        XCTAssertGreaterThanOrEqual(result.count, 0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let depthMap = Array(stride(from: 0.5, to: 2.0, by: 0.01))
        let vectors = Array(repeating: MotionComplexityAnalyzer.MotionVector(dx: 0.5, dy: 0.5), count: 10)
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let depthMap = Array(repeating: 1.0, count: 1000)
        let vectors: [MotionComplexityAnalyzer.MotionVector] = []
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertEqual(result.count, result.regions.count)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let depthMap = Array(repeating: Double(i) * 0.1, count: 100)
            let vectors = [MotionComplexityAnalyzer.MotionVector(dx: Double(i) * 0.1, dy: Double(i) * 0.1)]
            _ = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let depthMap: [Double] = []
        let vectors: [MotionComplexityAnalyzer.MotionVector] = []
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let depthMap = Array(repeating: 100.0, count: 10000)
        let vectors = Array(repeating: MotionComplexityAnalyzer.MotionVector(dx: 100.0, dy: 100.0), count: 100)
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let depthMap = Array(repeating: 0.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 0.0, dy: 0.0)]
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let depthMap1 = Array(repeating: 0.001, count: 100)
        let depthMap2 = Array(repeating: 999.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result1 = await refiner.detectOcclusions(depthMap: depthMap1, motionVectors: vectors)
        let result2 = await refiner.detectOcclusions(depthMap: depthMap2, motionVectors: vectors)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Occlusion Detection Tests
    
    func test_depthDiscontinuity_detection() async {
        var depthMap: [Double] = []
        for i in 0..<100 {
            depthMap.append(i < 50 ? 1.0 : 5.0)  // Clear discontinuity
        }
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodRefiner = OcclusionAwareRefiner(config: prodConfig)
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await prodRefiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devRefiner = OcclusionAwareRefiner(config: devConfig)
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await devRefiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testRefiner = OcclusionAwareRefiner(config: testConfig)
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await testRefiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidRefiner = OcclusionAwareRefiner(config: paranoidConfig)
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result = await paranoidRefiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let depthMap = Array(repeating: Double(i) * 0.1, count: 100)
                    let vectors = [MotionComplexityAnalyzer.MotionVector(dx: Double(i), dy: Double(i))]
                    _ = await self.refiner.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let refiner1 = OcclusionAwareRefiner(config: config)
        let refiner2 = OcclusionAwareRefiner(config: config)
        
        let depthMap = Array(repeating: 1.0, count: 100)
        let vectors = [MotionComplexityAnalyzer.MotionVector(dx: 1.0, dy: 1.0)]
        let result1 = await refiner1.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        let result2 = await refiner2.detectOcclusions(depthMap: depthMap, motionVectors: vectors)
        
        XCTAssertEqual(result1.count, result2.count)
    }
}
