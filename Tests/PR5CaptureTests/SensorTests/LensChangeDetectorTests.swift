//
// LensChangeDetectorTests.swift
// PR5CaptureTests
//
// Tests for LensChangeDetector
//

import XCTest
@testable import PR5Capture

@MainActor
final class LensChangeDetectorTests: XCTestCase {
    
    var detector: LensChangeDetector!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        detector = LensChangeDetector(config: config)
    }
    
    override func tearDown() {
        detector = nil
        config = nil
        super.tearDown()
    }
    
    func testFirstLensDetection() async {
        let intrinsics = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        
        let result = await detector.detectLensChange(intrinsics: intrinsics, deviceId: "device1")
        
        XCTAssertFalse(result.changed)  // First lens, not a change
        XCTAssertTrue(result.isFirstLens)
        XCTAssertNotNil(result.toLens)
    }
    
    func testLensChangeDetection() async {
        let intrinsics1 = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        
        // First lens
        _ = await detector.detectLensChange(intrinsics: intrinsics1, deviceId: "device1")
        
        // Different lens (different focal length)
        let intrinsics2 = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 24.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        
        let result = await detector.detectLensChange(intrinsics: intrinsics2, deviceId: "device1")
        
        XCTAssertTrue(result.changed)
        XCTAssertNotNil(result.fromLens)
        XCTAssertNotNil(result.toLens)
    }
    
    func testSessionSegments() async {
        let intrinsics1 = IntrinsicsDriftMonitor.CameraIntrinsics(
            focalLength: 50.0,
            principalPointX: 320.0,
            principalPointY: 240.0
        )
        
        _ = await detector.detectLensChange(intrinsics: intrinsics1, deviceId: "device1")
        
        let segments = await detector.getSessionSegments()
        XCTAssertEqual(segments.count, 1)
    }
}
