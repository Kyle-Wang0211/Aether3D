//
// FrameQualityConstantsTests.swift
// Aether3D
//
// Tests for FrameQualityConstants.
//

import XCTest
@testable import Aether3DCore

final class FrameQualityConstantsTests: XCTestCase {
    
    func testBlurThresholdLaplacian() {
        XCTAssertEqual(FrameQualityConstants.blurThresholdLaplacian, 200.0)
    }
    
    func testDarkThresholdBrightness() {
        XCTAssertEqual(FrameQualityConstants.darkThresholdBrightness, 60.0)
    }
    
    func testBrightThresholdBrightness() {
        XCTAssertEqual(FrameQualityConstants.brightThresholdBrightness, 200.0)
    }
    
    func testMaxFrameSimilarity() {
        XCTAssertEqual(FrameQualityConstants.maxFrameSimilarity, 0.92)
    }
    
    func testMinFrameSimilarity() {
        XCTAssertEqual(FrameQualityConstants.minFrameSimilarity, 0.50)
    }
    
    func testAllSpecsCount() {
        XCTAssertEqual(FrameQualityConstants.allSpecs.count, 5)
    }
}

