// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZFloatCanonTests.swift
// Aether3D
//
// PR1 PIZ Detection - Float Canonicalization Tests
//
// Tests for float quantization and -0.0 normalization.
// **Rule ID:** PIZ_FLOAT_CANON_001, PIZ_NUMERIC_FORMAT_001

import XCTest
@testable import Aether3DCore

final class PIZFloatCanonTests: XCTestCase {
    
    /// Test -0.0 normalization to +0.0.
    /// **Rule ID:** PIZ_NUMERIC_FORMAT_001
    func testNegativeZeroNormalization() {
        let negativeZero = -0.0
        let quantized = PIZFloatCanon.quantize(negativeZero)
        
        // Should normalize to +0.0
        XCTAssertEqual(quantized, 0.0)
        XCTAssertEqual(quantized.sign, .plus)
    }
    
    /// Test quantization uses ROUND_HALF_AWAY_FROM_ZERO.
    /// **Rule ID:** PIZ_FLOAT_CANON_001
    func testQuantizationRounding() {
        let precision = PIZThresholds.JSON_CANON_QUANTIZATION_PRECISION
        
        // Test value that rounds to half
        let value = precision * 2.5 // Should round to 3 * precision (away from zero)
        let quantized = PIZFloatCanon.quantize(value)
        let expected = 3.0 * precision
        XCTAssertEqual(quantized, expected, accuracy: 1e-10)
        
        // Test negative value
        let negativeValue = -precision * 2.5 // Should round to -3 * precision (away from zero)
        let quantizedNegative = PIZFloatCanon.quantize(negativeValue)
        let expectedNegative = -3.0 * precision
        XCTAssertEqual(quantizedNegative, expectedNegative, accuracy: 1e-10)
    }
    
    /// Test quantization precision.
    func testQuantizationPrecision() {
        let precision = PIZThresholds.JSON_CANON_QUANTIZATION_PRECISION
        
        // Test value within precision
        let value = 0.123456789
        let quantized = PIZFloatCanon.quantize(value)
        
        // Should be quantized to precision
        let scaled = value / precision
        let rounded = round(scaled)
        let expected = rounded * precision
        
        XCTAssertEqual(quantized, expected, accuracy: 1e-10)
    }
}
