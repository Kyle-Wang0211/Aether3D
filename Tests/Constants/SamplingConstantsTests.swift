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
    
 pr/1-system-layer

    func testMaxUploadSizeBytes() {
        XCTAssertEqual(SamplingConstants.maxUploadSizeBytes, 1_161_527_296)
    }
    
 main
    func testJpegQuality() {
        XCTAssertEqual(SamplingConstants.jpegQuality, 0.85, accuracy: 0.001)
    }
    
    func testMaxImageLongEdge() {
        XCTAssertEqual(SamplingConstants.maxImageLongEdge, 1920)
    }
    
    func testAllSpecsCount() {
 pr/1-system-layer
        XCTAssertEqual(SamplingConstants.allSpecs.count, 6)

        XCTAssertEqual(SamplingConstants.allSpecs.count, 7)
 main
    }
}

