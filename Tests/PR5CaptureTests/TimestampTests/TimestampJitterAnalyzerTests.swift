//
// TimestampJitterAnalyzerTests.swift
// PR5CaptureTests
//
// Tests for TimestampJitterAnalyzer
//

import XCTest
@testable import PR5Capture

@MainActor
final class TimestampJitterAnalyzerTests: XCTestCase {
    
    var analyzer: TimestampJitterAnalyzer!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        analyzer = TimestampJitterAnalyzer(config: config)
    }
    
    override func tearDown() {
        analyzer = nil
        config = nil
        super.tearDown()
    }
    
    func testCameraTimestampRecording() async {
        await analyzer.recordCameraTimestamp(0.0)
        await analyzer.recordCameraTimestamp(0.033)  // ~30fps
        
        let result = await analyzer.analyzeJitter()
        XCTAssertNotNil(result.cameraJitter)
    }
    
    func testIMUTimestampRecording() async {
        await analyzer.recordIMUTimestamp(0.0)
        await analyzer.recordIMUTimestamp(0.01)  // 100Hz IMU
        
        let result = await analyzer.analyzeJitter()
        XCTAssertNotNil(result.imuJitter)
    }
    
    func testTimestampPairRecording() async {
        await analyzer.recordTimestampPair(camera: 0.0, imu: 0.0)
        await analyzer.recordTimestampPair(camera: 0.033, imu: 0.033)
        
        let result = await analyzer.analyzeJitter()
        XCTAssertNotNil(result.deltaJitter)
    }
    
    func testJitterAnalysis() async {
        // Record regular timestamps (30fps)
        for i in 0..<10 {
            await analyzer.recordCameraTimestamp(Double(i) * 0.033)
        }
        
        let result = await analyzer.analyzeJitter()
        XCTAssertFalse(result.hasExcessiveJitter)  // Regular timing should not exceed threshold
    }
}
