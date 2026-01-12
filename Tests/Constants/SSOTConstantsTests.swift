//
// SSOTConstantsTests.swift
// Aether3D
//
// Basic tests for SSOT constant accessibility and values.
//

import XCTest
@testable import Aether3DCore

final class SSOTConstantsTests: XCTestCase {
    func testSystemConstantsValues() {
        XCTAssertEqual(SystemConstants.maxFrames, 5000)
        XCTAssertEqual(SystemConstants.minFrames, 10)
        XCTAssertEqual(SystemConstants.maxGaussians, 1000000)
    }
    
    func testConversionConstantsValues() {
        XCTAssertEqual(ConversionConstants.bytesPerKB, 1024)
        XCTAssertEqual(ConversionConstants.bytesPerMB, 1048576)
    }
    
    func testQualityThresholdsValues() {
        XCTAssertEqual(QualityThresholds.sfmRegistrationMinRatio, 0.75, accuracy: 0.001)
        XCTAssertEqual(QualityThresholds.psnrMinDb, 30.0, accuracy: 0.001)
        XCTAssertEqual(QualityThresholds.psnrWarnDb, 32.0, accuracy: 0.001)
    }
    
    func testConstantsHaveSpecs() {
        XCTAssertFalse(SystemConstants.allSpecs.isEmpty)
        XCTAssertFalse(ConversionConstants.allSpecs.isEmpty)
        XCTAssertFalse(QualityThresholds.allSpecs.isEmpty)
    }
}

