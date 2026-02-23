// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RetryConstantsTests.swift
// Aether3D
//
// Tests for RetryConstants.
//

import XCTest
@testable import Aether3DCore

final class RetryConstantsTests: XCTestCase {
    
    func testMaxRetryCount() {
        XCTAssertEqual(RetryConstants.maxRetryCount, 10)
    }
    
    func testRetryIntervalSeconds() {
        XCTAssertEqual(RetryConstants.retryIntervalSeconds, 10.0)
    }
    
    func testUploadTimeoutSeconds() {
        XCTAssertEqual(RetryConstants.uploadTimeoutSeconds, .infinity)
    }
    
    func testDownloadMaxRetryCount() {
        XCTAssertEqual(RetryConstants.downloadMaxRetryCount, 3)
    }
    
    func testArtifactTTLSeconds() {
        XCTAssertEqual(RetryConstants.artifactTTLSeconds, 1800)
    }
    
    func testHeartbeatIntervalSeconds() {
        XCTAssertEqual(RetryConstants.heartbeatIntervalSeconds, 30.0)
    }
    
    func testPollingIntervalSeconds() {
        XCTAssertEqual(RetryConstants.pollingIntervalSeconds, 3.0)
    }
    
    func testStallDetectionSeconds() {
        XCTAssertEqual(RetryConstants.stallDetectionSeconds, 300)
    }
    
    func testStallHeartbeatFailureCount() {
        XCTAssertEqual(RetryConstants.stallHeartbeatFailureCount, 10)
    }
    
    func testAllSpecsCount() {
        XCTAssertEqual(RetryConstants.allSpecs.count, 9)
    }
}

