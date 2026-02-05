//
// DualTimestampRecorderTests.swift
// PR5CaptureTests
//
// Tests for DualTimestampRecorder
//

import XCTest
@testable import PR5Capture

@MainActor
final class DualTimestampRecorderTests: XCTestCase {
    
    var recorder: DualTimestampRecorder!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        recorder = DualTimestampRecorder(config: config)
    }
    
    override func tearDown() async throws {
        recorder = nil
        config = nil
    }
    
    func testTimestampRecording() async {
        let callbackTime = Date()
        let captureTime = callbackTime.addingTimeInterval(-0.01)  // 10ms earlier
        
        await recorder.recordTimestamps(callbackTime: callbackTime, captureTime: captureTime)
        
        let avgDelay = await recorder.getAverageDelay()
        XCTAssertNotNil(avgDelay)
        XCTAssertEqual(avgDelay!, 0.01, accuracy: 0.001)
    }
    
    func testDelayWarning() async {
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Timestamp.dualTimestampMaxDelayMs,
            profile: .standard
        ) / 1000.0
        
        let callbackTime = Date()
        let captureTime = callbackTime.addingTimeInterval(-(threshold + 0.1))  // Exceeds threshold
        
        await recorder.recordTimestamps(callbackTime: callbackTime, captureTime: captureTime)
        
        let warnings = await recorder.getDelayWarnings()
        XCTAssertFalse(warnings.isEmpty)
    }
    
    func testDeferredCaptureTime() async {
        let callbackTime = Date()
        let token = await recorder.recordCallbackTime(callbackTime)
        
        let captureTime = callbackTime.addingTimeInterval(-0.01)
        await recorder.recordCaptureTime(token, captureTime: captureTime)
        
        let avgDelay = await recorder.getAverageDelay()
        XCTAssertNotNil(avgDelay)
    }
}
