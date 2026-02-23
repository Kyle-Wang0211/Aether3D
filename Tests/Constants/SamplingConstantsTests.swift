// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SamplingConstantsTests.swift
// Aether3D
//
// Tests for SamplingConstants.
//

import XCTest
@testable import Aether3DCore

final class SamplingConstantsTests: XCTestCase {
    
    func testMinVideoDurationSeconds() {
        XCTAssertEqual(SamplingConstants.minVideoDurationSeconds, 2.0)
    }
    
    func testMaxVideoDurationSeconds() {
        XCTAssertEqual(SamplingConstants.maxVideoDurationSeconds, 900)
    }
    
    func testMinFrameCount() {
        XCTAssertEqual(SamplingConstants.minFrameCount, 30)
    }
    
    func testMaxFrameCount() {
        XCTAssertEqual(SamplingConstants.maxFrameCount, 1800)
    }
    
    func testJpegQuality() {
        XCTAssertEqual(SamplingConstants.jpegQuality, 0.85, accuracy: 0.001)
    }
    
    func testMaxImageLongEdge() {
        XCTAssertEqual(SamplingConstants.maxImageLongEdge, 1920)
    }
    
    func testAllSpecsCount() {
        XCTAssertEqual(SamplingConstants.allSpecs.count, 6)
    }
}

