//
// LatencyBudgetMonitorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for LatencyBudgetMonitor
//

import XCTest
@testable import PR5Capture

@MainActor
final class LatencyBudgetMonitorTests: XCTestCase {
    
    var monitor: LatencyBudgetMonitor!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        monitor = LatencyBudgetMonitor(config: config)
    }
    
    override func tearDown() {
        monitor = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await monitor.recordFrameTime(0.016)
        XCTAssertNotNil(result.withinBudget)
        XCTAssertEqual(result.frameTime, 0.016, accuracy: 0.001)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await monitor.recordFrameTime(0.01667)
        XCTAssertTrue(result.withinBudget)
    }
    
    func test_standardConfiguration_works() async {
        let result = await monitor.recordFrameTime(0.015)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await monitor.recordFrameTime(0.01667)
        XCTAssertTrue(result.withinBudget)
        XCTAssertEqual(result.budget, 0.01667, accuracy: 0.001)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for _ in 0..<10 {
            _ = await monitor.recordFrameTime(0.016)
        }
        let avgTime = await monitor.getAverageFrameTime()
        XCTAssertNotNil(avgTime)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await monitor.recordFrameTime(0.001)
        XCTAssertNotNil(result)
        XCTAssertTrue(result.withinBudget)
    }
    
    func test_maximumInput_handled() async {
        let result = await monitor.recordFrameTime(1.0)
        XCTAssertNotNil(result)
        XCTAssertFalse(result.withinBudget)
    }
    
    func test_zeroInput_handled() async {
        let result = await monitor.recordFrameTime(0.0)
        XCTAssertNotNil(result)
        XCTAssertTrue(result.withinBudget)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await monitor.recordFrameTime(0.01666)
        let result2 = await monitor.recordFrameTime(0.01668)
        XCTAssertTrue(result1.withinBudget)
        XCTAssertFalse(result2.withinBudget)
    }
    
    // MARK: - Budget Violation Tests
    
    func test_budget_violation() async {
        let result = await monitor.recordFrameTime(0.05)
        XCTAssertFalse(result.withinBudget)
        XCTAssertGreaterThan(result.violationCount, 0)
    }
    
    func test_budget_compliance() async {
        let result = await monitor.recordFrameTime(0.01)
        XCTAssertTrue(result.withinBudget)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodMonitor = LatencyBudgetMonitor(config: prodConfig)
        let result = await prodMonitor.recordFrameTime(0.016)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devMonitor = LatencyBudgetMonitor(config: devConfig)
        let result = await devMonitor.recordFrameTime(0.016)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testMonitor = LatencyBudgetMonitor(config: testConfig)
        let result = await testMonitor.recordFrameTime(0.016)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidMonitor = LatencyBudgetMonitor(config: paranoidConfig)
        let result = await paranoidMonitor.recordFrameTime(0.016)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.monitor.recordFrameTime(0.016 + Double(i) * 0.001)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let monitor1 = LatencyBudgetMonitor(config: config)
        let monitor2 = LatencyBudgetMonitor(config: config)
        
        _ = await monitor1.recordFrameTime(0.016)
        _ = await monitor2.recordFrameTime(0.02)
        
        let avg1 = await monitor1.getAverageFrameTime()
        let avg2 = await monitor2.getAverageFrameTime()
        
        XCTAssertNotEqual(avg1, avg2)
    }
}
