// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoverageVisualizationConstantsTests.swift
// Aether3D
//
// Tests for CoverageVisualizationConstants.
//

import XCTest
@testable import Aether3DCore

final class CoverageVisualizationConstantsTests: XCTestCase {
    
    func testS0BorderWidthPx() {
        XCTAssertEqual(CoverageVisualizationConstants.s0BorderWidthPx, 1.0, accuracy: 0.001)
    }
    
    func testS4MinThetaSpanDeg() {
        XCTAssertEqual(CoverageVisualizationConstants.s4MinThetaSpanDeg, 16.0)
    }
    
    func testS4MinL2PlusCount() {
        XCTAssertEqual(CoverageVisualizationConstants.s4MinL2PlusCount, 7)
    }
    
    func testS4MinL3Count() {
        XCTAssertEqual(CoverageVisualizationConstants.s4MinL3Count, 3)
    }
    
    func testS4MaxReprojRmsPx() {
        XCTAssertEqual(CoverageVisualizationConstants.s4MaxReprojRmsPx, 1.0)
    }
    
    func testS4MaxEdgeRmsPx() {
        XCTAssertEqual(CoverageVisualizationConstants.s4MaxEdgeRmsPx, 0.5)
    }
    
    func testPatchSizeMinM() {
        XCTAssertEqual(CoverageVisualizationConstants.patchSizeMinM, 0.005)
    }
    
    func testPatchSizeMaxM() {
        XCTAssertEqual(CoverageVisualizationConstants.patchSizeMaxM, 0.5)
    }
    
    func testPatchSizeFallbackM() {
        XCTAssertEqual(CoverageVisualizationConstants.patchSizeFallbackM, 0.05)
    }
    
    func testAllSpecsCount() {
        XCTAssertEqual(CoverageVisualizationConstants.allSpecs.count, 9)
    }
}

