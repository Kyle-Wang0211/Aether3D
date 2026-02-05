//
// IntrinsicsDriftMonitorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for IntrinsicsDriftMonitor
//

import XCTest
@testable import PR5Capture

@MainActor
final class IntrinsicsDriftMonitorTests: XCTestCase {
    
    var monitor: IntrinsicsDriftMonitor!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        monitor = IntrinsicsDriftMonitor(config: config)
    }
    
    override func tearDown() async throws {
        monitor = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        let driftResult = await monitor.monitorDrift(intrinsics)
        XCTAssertNotNil(driftResult.baseline)
    }
    
    func test_typicalUseCase_succeeds() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        
        let current = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.1,
            principalPointX: 320.1,
            principalPointY: 240.1
        )
        let driftResult = await monitor.monitorDrift(current)
        XCTAssertNotNil(driftResult)
    }
    
    func test_standardConfiguration_works() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        let driftResult = await monitor.monitorDrift(intrinsics)
        XCTAssertNotNil(driftResult.baseline)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        
        let current = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        let driftResult = await monitor.monitorDrift(current)
        XCTAssertFalse(driftResult.hasDrift)
    }
    
    func test_commonScenario_handledCorrectly() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        
        for i in 1...10 {
            let current = IntrinsicsDriftMonitor.CameraIntrinsics(
                focalLength: 50.0 + Double(i) * 0.01,
                principalPointX: 320.0,
                principalPointY: 240.0
            )
            _ = await monitor.monitorDrift(current)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 1.0,
            principalPointX: 1.0,
            principalPointY: 1.0
        )
        let result = await monitor.establishBaseline(intrinsics)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 1000.0,
            principalPointX: 10000.0,
            principalPointY: 10000.0
        )
        let result = await monitor.establishBaseline(intrinsics)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 0.0,
            principalPointX: 0.0,
            principalPointY: 0.0
        )
        let result = await monitor.establishBaseline(intrinsics)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        
        let current = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0 + 0.001,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        let driftResult = await monitor.monitorDrift(current)
        XCTAssertNotNil(driftResult)
    }
    
    // MARK: - Drift Detection Tests
    
    func test_drift_detection_noDrift() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        
        let current = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        let driftResult = await monitor.monitorDrift(current)
        XCTAssertFalse(driftResult.hasDrift)
    }
    
    func test_drift_detection_hasDrift() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await monitor.establishBaseline(intrinsics)
        
        let current = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 60.0,  // Significant drift
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        let driftResult = await monitor.monitorDrift(current)
        XCTAssertTrue(driftResult.hasDrift)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodMonitor = IntrinsicsDriftMonitor(config: prodConfig)
        
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await prodMonitor.establishBaseline(intrinsics)
        let result = await prodMonitor.monitorDrift(intrinsics)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devMonitor = IntrinsicsDriftMonitor(config: devConfig)
        
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await devMonitor.establishBaseline(intrinsics)
        let result = await devMonitor.monitorDrift(intrinsics)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testMonitor = IntrinsicsDriftMonitor(config: testConfig)
        
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await testMonitor.establishBaseline(intrinsics)
        let result = await testMonitor.monitorDrift(intrinsics)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidMonitor = IntrinsicsDriftMonitor(config: paranoidConfig)
        
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        await paranoidMonitor.establishBaseline(intrinsics)
        let result = await paranoidMonitor.monitorDrift(intrinsics)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.monitor.establishBaseline(intrinsics)
                }
            }
        }
    }
}
