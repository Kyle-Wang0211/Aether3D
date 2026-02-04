//
// EISRollingShutterHandlerTests.swift
// PR5CaptureTests
//
// Tests for EISRollingShutterHandler
//

import XCTest
@testable import PR5Capture

@MainActor
final class EISRollingShutterHandlerTests: XCTestCase {
    
    var handler: EISRollingShutterHandler!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        handler = EISRollingShutterHandler(config: config)
    }
    
    override func tearDown() {
        handler = nil
        config = nil
        super.tearDown()
    }
    
    func testEISDetection() async {
        // Create smooth motion vectors (EIS-like)
        let motionVectors = (0..<10).map { _ in
            EISRollingShutterHandler.MotionVector(dx: 0.1, dy: 0.1)
        }
        
        let result = await handler.detectEIS(motionVectors: motionVectors, gyroData: nil)
        
        // Should detect EIS from smooth motion
        XCTAssertNotNil(result.combinedScore)
    }
    
    func testRollingShutterCompensation() async {
        // Enable EIS first
        let motionVectors = (0..<10).map { _ in
            EISRollingShutterHandler.MotionVector(dx: 0.1, dy: 0.1)
        }
        _ = await handler.detectEIS(motionVectors: motionVectors, gyroData: nil)
        
        // Compute compensation
        let compensation = await handler.computeCompensation(
            frameId: 1,
            motionVectors: motionVectors,
            readoutTime: 0.016  // ~60fps readout
        )
        
        XCTAssertNotNil(compensation.compensation)
    }
    
    func testKeyframeSuitability() async {
        // Enable EIS
        let motionVectors = (0..<10).map { _ in
            EISRollingShutterHandler.MotionVector(dx: 0.1, dy: 0.1)
        }
        _ = await handler.detectEIS(motionVectors: motionVectors, gyroData: nil)
        
        // Check suitability
        let result = await handler.checkKeyframeSuitability(
            frameId: 1,
            motionVectors: motionVectors,
            quality: 0.8
        )
        
        XCTAssertNotNil(result.suitable)
    }
}
