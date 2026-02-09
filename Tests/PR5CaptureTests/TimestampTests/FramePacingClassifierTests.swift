// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FramePacingClassifierTests.swift
// PR5CaptureTests
//
// Tests for FramePacingClassifier
//

import XCTest
@testable import PR5Capture

@MainActor
final class FramePacingClassifierTests: XCTestCase {
    
    var classifier: FramePacingClassifier!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        classifier = FramePacingClassifier(config: config)
    }
    
    override func tearDown() async throws {
        classifier = nil
        config = nil
    }
    
    func test30FPSClassification() async {
        // Record frames at 30fps (33.33ms intervals)
        let startTime = Date()
        for i in 0..<30 {
            let timestamp = startTime.addingTimeInterval(Double(i) * 0.03333)
            await classifier.recordFrame(timestamp)
        }
        
        let frameRate = await classifier.getClassifiedFrameRate()
        XCTAssertEqual(frameRate, .fps30)
    }
    
    func test60FPSClassification() async {
        // Record frames at 60fps (16.67ms intervals)
        let startTime = Date()
        for i in 0..<60 {
            let timestamp = startTime.addingTimeInterval(Double(i) * 0.01667)
            await classifier.recordFrame(timestamp)
        }
        
        let frameRate = await classifier.getClassifiedFrameRate()
        XCTAssertEqual(frameRate, .fps60)
    }
    
    func testRegularRhythm() async {
        // Record regular frames
        let startTime = Date()
        for i in 0..<30 {
            let timestamp = startTime.addingTimeInterval(Double(i) * 0.03333)
            await classifier.recordFrame(timestamp)
        }
        
        let rhythm = await classifier.getClassifiedPacingRhythm()
        XCTAssertEqual(rhythm, .regular)
    }
    
    func testDroppedFrames() async {
        // Record frames with occasional drops
        let startTime = Date()
        var frameIndex = 0
        for i in 0..<30 {
            var interval = 0.03333
            if i % 5 == 0 && i > 0 {
                interval *= 2.0  // Simulate drop
            }
            frameIndex += 1
            let timestamp = startTime.addingTimeInterval(Double(frameIndex) * interval)
            await classifier.recordFrame(timestamp)
        }
        
        let rhythm = await classifier.getClassifiedPacingRhythm()
        XCTAssertTrue(rhythm == .dropped || rhythm == .stuttering)
    }
}
