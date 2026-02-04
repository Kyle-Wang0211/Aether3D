//
// FramePacingNormalizerTests.swift
// PR5CaptureTests
//
// Tests for FramePacingNormalizer
//

import XCTest
@testable import PR5Capture

@MainActor
final class FramePacingNormalizerTests: XCTestCase {
    
    var normalizer: FramePacingNormalizer!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        normalizer = FramePacingNormalizer(config: config)
    }
    
    override func tearDown() {
        normalizer = nil
        config = nil
        super.tearDown()
    }
    
    func testFPSEstimation() async {
        // Record frames at 30fps
        let startTime = Date()
        for i in 0..<30 {
            let timestamp = startTime.addingTimeInterval(Double(i) * 0.03333)
            await normalizer.recordFrame(timestamp)
        }
        
        let fps = await normalizer.getEstimatedFPS()
        XCTAssertNotNil(fps)
        if let fps = fps {
            XCTAssertEqual(fps, 30.0, accuracy: 2.0)  // Allow ±2fps tolerance
        }
    }
    
    func testFrameDropDetection() async {
        // Record frames with a drop
        let startTime = Date()
        var frameIndex = 0
        for i in 0..<30 {
            var interval = 0.03333
            if i == 15 {
                interval *= 2.0  // Simulate drop
            }
            frameIndex += 1
            let timestamp = startTime.addingTimeInterval(Double(frameIndex) * interval)
            await normalizer.recordFrame(timestamp)
        }
        
        let dropCount = await normalizer.getFrameDropCount()
        XCTAssertGreaterThan(dropCount, 0)
    }
    
    func testTimeWindowNormalization() async {
        // Record frames to establish FPS
        let startTime = Date()
        for i in 0..<30 {
            let timestamp = startTime.addingTimeInterval(Double(i) * 0.03333)
            await normalizer.recordFrame(timestamp)
        }
        
        // Normalize 1 second window
        let frameWindow = await normalizer.normalizeTimeWindow(1.0)
        XCTAssertNotNil(frameWindow)
        if let window = frameWindow {
            XCTAssertEqual(window, 30, accuracy: 2)  // ~30 frames for 1 second at 30fps
        }
    }
    
    func testDenormalizeFrameWindow() async {
        // Record frames to establish FPS
        let startTime = Date()
        for i in 0..<30 {
            let timestamp = startTime.addingTimeInterval(Double(i) * 0.03333)
            await normalizer.recordFrame(timestamp)
        }
        
        // Denormalize 30 frames
        let timeWindow = await normalizer.denormalizeFrameWindow(30)
        XCTAssertNotNil(timeWindow)
        if let window = timeWindow {
            XCTAssertEqual(window, 1.0, accuracy: 0.1)  // ~1 second for 30 frames at 30fps
        }
    }
}
