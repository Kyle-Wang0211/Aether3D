// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CorePortabilitySmokeTests.swift
//  Aether3D
//
//  Created for PR#4 Capture Recording - Core Portability Verification
//
//  CI-HARDENED: This test verifies Core/Constants can compile on non-Apple platforms.
//  It imports ONLY Foundation (no AVFoundation, no iOS-only APIs).
//

import XCTest
import Foundation
import Aether3DCore

final class CorePortabilitySmokeTests: XCTestCase {
    
    func test_coreConstantsCompileOnNonApplePlatforms() {
        // Verify CaptureRecordingConstants can be accessed without AVFoundation
        // This test will fail to compile if Core imports AVFoundation or uses iOS-only types
        
        // Test duration constants
        let minDuration = CaptureRecordingConstants.minDurationSeconds
        let maxDuration = CaptureRecordingConstants.maxDurationSeconds
        XCTAssertGreaterThan(maxDuration, minDuration, "maxDuration must be greater than minDuration")
        
        // Test size constants
        let maxBytes = CaptureRecordingConstants.maxBytes
        XCTAssertGreaterThan(maxBytes, 0, "maxBytes must be positive")
        
        // Test CMTime timescale constant (Int32, Foundation-only type)
        let timescale = CaptureRecordingConstants.cmTimePreferredTimescale
        XCTAssertEqual(timescale, 600, "cmTimePreferredTimescale must be 600")
        XCTAssertGreaterThan(timescale, 0, "timescale must be positive")
        
        // Test bitrate estimation (deterministic function)
        // ResolutionTier is now defined in Core/Constants/ResolutionTier.swift
        // Verify we can call bitrate functions with Core types
        let tier = ResolutionTier.t1080p
        let bitrate = CaptureRecordingConstants.estimatedBitrate(tier: tier, fps: 30.0)
        XCTAssertGreaterThan(bitrate, 0, "estimatedBitrate must return positive value")
        
        // Test polling constants
        let pollSmall = CaptureRecordingConstants.fileSizePollIntervalSmallFile
        let pollLarge = CaptureRecordingConstants.fileSizePollIntervalLargeFile
        XCTAssertGreaterThan(pollSmall, 0, "pollSmall must be positive")
        XCTAssertGreaterThan(pollLarge, 0, "pollLarge must be positive")
        
        // Test threshold constant
        let threshold = CaptureRecordingConstants.fileSizeLargeThresholdBytes
        XCTAssertGreaterThan(threshold, 0, "threshold must be positive")
    }
    
    func test_coreConstantsUseFoundationTypesOnly() {
        // Verify all constants use Foundation types (TimeInterval, Int, Int32, Int64, String)
        // This is a compile-time check - if the test compiles, types are correct
        
        let duration: TimeInterval = CaptureRecordingConstants.maxDurationSeconds
        let bytes: Int64 = CaptureRecordingConstants.maxBytes
        let timescale: Int32 = CaptureRecordingConstants.cmTimePreferredTimescale
        let threshold: Int64 = CaptureRecordingConstants.fileSizeLargeThresholdBytes
        
        // If we get here, types are Foundation-only (test passes)
        XCTAssertNotNil(duration)
        XCTAssertNotNil(bytes)
        XCTAssertNotNil(timescale)
        XCTAssertNotNil(threshold)
    }
}

