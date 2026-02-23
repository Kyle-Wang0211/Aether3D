// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicQuantizationHalfAwayFromZeroBoundaryTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Quantization Boundary Tests
//
// This test file validates ROUND_HALF_AWAY_FROM_ZERO behavior at boundaries.
//

import XCTest
@testable import Aether3DCore

/// Tests for quantization half-away-from-zero boundary behavior.
///
/// **Rule ID:** A4
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - +/-0.5 rounds correctly
/// - Boundary values (0.499999999, 0.500000001) round correctly
/// - Both precisions (geomId, patchId) behave consistently
final class DeterministicQuantizationHalfAwayFromZeroBoundaryTests: XCTestCase {
    
    func test_halfAwayFromZero_positiveHalf() {
        // Test +0.5 rounds to +1 (away from zero)
        // quantizeForGeomId divides by 1e-3, so 0.5 -> 500 -> rounds to 500
        // But we test the rounding behavior: 0.5 / 1e-3 = 500, which should round to 500 (no change)
        // Actually, we need to test the rounding at the half boundary after division
        // For geomId precision 1e-3: value 0.0005 -> 0.0005 / 1e-3 = 0.5 -> rounds to 1
        let result = DeterministicQuantization.quantizeForGeomId(0.0005)
        XCTAssertEqual(result.quantized, 1, "0.0005 at geomId precision should round to 1 (0.5 -> 1 away from zero)")
        XCTAssertTrue(result.edgeCasesTriggered.isEmpty, "0.0005 should not trigger edge cases")
    }
    
    func test_halfAwayFromZero_negativeHalf() {
        // Test -0.5 rounds to -1 (away from zero)
        // For geomId precision: -0.0005 -> -0.0005 / 1e-3 = -0.5 -> rounds to -1
        let result = DeterministicQuantization.quantizeForGeomId(-0.0005)
        XCTAssertEqual(result.quantized, -1, "-0.0005 at geomId precision should round to -1 (away from zero)")
        XCTAssertTrue(result.edgeCasesTriggered.isEmpty, "-0.0005 should not trigger edge cases")
    }
    
    func test_halfAwayFromZero_positiveOneAndHalf() {
        // Test +1.5 rounds to +2
        // For geomId: 0.0015 -> 0.0015 / 1e-3 = 1.5 -> rounds to 2
        let result = DeterministicQuantization.quantizeForGeomId(0.0015)
        XCTAssertEqual(result.quantized, 2, "0.0015 at geomId precision should round to 2")
    }
    
    func test_halfAwayFromZero_negativeOneAndHalf() {
        // Test -1.5 rounds to -2
        // For geomId: -0.0015 -> -0.0015 / 1e-3 = -1.5 -> rounds to -2
        let result = DeterministicQuantization.quantizeForGeomId(-0.0015)
        XCTAssertEqual(result.quantized, -2, "-0.0015 at geomId precision should round to -2")
    }
    
    func test_boundaryJustBelowHalf() {
        // Test value just below 0.5 boundary after division
        // For geomId: 0.000499 -> 0.000499 / 1e-3 = 0.499 -> rounds to 0
        let value = 0.000499
        let result = DeterministicQuantization.quantizeForGeomId(value)
        XCTAssertEqual(result.quantized, 0, "0.000499 at geomId precision should round to 0")
    }
    
    func test_boundaryJustAboveHalf() {
        // Test value just above 0.5 boundary after division
        // For geomId: 0.000501 -> 0.000501 / 1e-3 = 0.501 -> rounds to 1
        let value = 0.000501
        let result = DeterministicQuantization.quantizeForGeomId(value)
        XCTAssertEqual(result.quantized, 1, "0.000501 at geomId precision should round to 1")
    }
    
    func test_patchIdPrecision_boundary() {
        // Test patchId precision (0.1mm = 1e-4) boundary
        // 0.00005 should round to 0.0001 (scaled: 0.5 -> 1)
        let result = DeterministicQuantization.quantizeForPatchId(0.00005)
        XCTAssertEqual(result.quantized, 1, "0.00005 at patchId precision should round to 1")
    }
    
    func test_geomIdPrecision_boundary() {
        // Test geomId precision (1mm = 1e-3) boundary
        // 0.0005 should round to 0.001 (scaled: 0.5 -> 1)
        let result = DeterministicQuantization.quantizeForGeomId(0.0005)
        XCTAssertEqual(result.quantized, 1, "0.0005 at geomId precision should round to 1")
    }
}
