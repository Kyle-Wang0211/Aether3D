// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZThresholdsTests.swift
// Aether3D
//
// PR1 PIZ Detection - SSOT Threshold Constants Tests
//
// Tests for derived constants and defensive preconditions.
// **Rule ID:** PIZ_MAX_REGIONS_DERIVED_001, PIZ_NUMERIC_FORMAT_001, PIZ_COVERED_CELL_001

import XCTest
@testable import Aether3DCore

final class PIZThresholdsTests: XCTestCase {
    
    /// Test derived constants match expected values.
    /// **Rule ID:** PIZ_MAX_REGIONS_DERIVED_001, PIZ_NUMERIC_FORMAT_001
    func testDerivedConstants() {
        XCTAssertEqual(PIZThresholds.TOTAL_GRID_CELLS, 1024)
        XCTAssertEqual(PIZThresholds.MAX_REPORTED_REGIONS, 128)
        XCTAssertEqual(PIZThresholds.JSON_CANON_DECIMAL_PLACES, 6)
    }
    
    /// Test that JSON_CANON_DECIMAL_PLACES derivation is integer.
    /// **Rule ID:** PIZ_NUMERIC_FORMAT_001
    func testDecimalPlacesIsInteger() {
        let precision = PIZThresholds.JSON_CANON_QUANTIZATION_PRECISION
        let decimalPlaces = -log10(precision)
        let rounded = Int(decimalPlaces.rounded())
        
        // Verify it's an integer (defensive precondition)
        let difference = abs(decimalPlaces - Double(rounded))
        XCTAssertTrue(difference < 1e-10, "JSON_CANON_QUANTIZATION_PRECISION must yield integer decimalPlaces")
        XCTAssertEqual(PIZThresholds.JSON_CANON_DECIMAL_PLACES, rounded)
    }
    
    /// Test MAX_REPORTED_REGIONS derivation formula.
    /// **Rule ID:** PIZ_MAX_REGIONS_DERIVED_001
    func testMaxRegionsDerivation() {
        let expected = PIZThresholds.TOTAL_GRID_CELLS / PIZThresholds.MIN_REGION_PIXELS
        XCTAssertEqual(PIZThresholds.MAX_REPORTED_REGIONS, expected)
        XCTAssertEqual(PIZThresholds.MAX_REPORTED_REGIONS, 128)
    }
    
    /// Test grid constants.
    func testGridConstants() {
        XCTAssertEqual(PIZThresholds.GRID_SIZE, 32)
        XCTAssertEqual(PIZThresholds.TOTAL_GRID_CELLS, PIZThresholds.GRID_SIZE * PIZThresholds.GRID_SIZE)
    }
    
    /// Test COVERED_CELL_MIN is defined.
    /// **Rule ID:** PIZ_COVERED_CELL_001
    func testCoveredCellMin() {
        XCTAssertEqual(PIZThresholds.COVERED_CELL_MIN, 0.5)
    }
    
    /// Test tolerance constants are defined.
    /// **Rule ID:** PIZ_TOLERANCE_SSOT_001
    func testToleranceConstants() {
        XCTAssertEqual(PIZThresholds.COVERAGE_RELATIVE_TOLERANCE, 1e-4, accuracy: 1e-10)
        XCTAssertEqual(PIZThresholds.LAB_COLOR_ABSOLUTE_TOLERANCE, 1e-3, accuracy: 1e-10)
        XCTAssertEqual(PIZThresholds.JSON_CANON_QUANTIZATION_PRECISION, 1e-6, accuracy: 1e-10)
    }
}
