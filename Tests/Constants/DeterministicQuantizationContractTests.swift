// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicQuantizationContractTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Deterministic Quantization Contract Tests (A3 + A4)
//
// This test file validates deterministic quantization contract compliance.
//

import XCTest
@testable import Aether3DCore

/// Tests for deterministic quantization contract (A3 + A4).
///
/// **Rule ID:** A3, A4, CROSS_PLATFORM_QUANT_001A, A1 (v1.1.1)
/// **Status:** IMMUTABLE
final class DeterministicQuantizationContractTests: XCTestCase {
    
    func test_quantize_roundingMode_halfAwayFromZero_consistency() {
        // Test half tie rounding: 0.5 rounds to 1 (away from zero)
        let result = DeterministicQuantization.quantizeForGeomId(0.0005)
        XCTAssertEqual(result.quantized, 1)
        XCTAssertEqual(result.edgeCasesTriggered.count, 0)
        
        // Test negative half tie: -0.5 rounds to -1 (away from zero)
        let resultNeg = DeterministicQuantization.quantizeForGeomId(-0.0005)
        XCTAssertEqual(resultNeg.quantized, -1)
    }
    
    func test_quantize_geomId_precision_1mm() {
        // 1mm precision test
        let result = DeterministicQuantization.quantizeForGeomId(0.001)
        XCTAssertEqual(result.quantized, 1)
        
        let result2 = DeterministicQuantization.quantizeForGeomId(0.002)
        XCTAssertEqual(result2.quantized, 2)
    }
    
    func test_quantize_patchId_precision_0_1mm() {
        // 0.1mm precision test
        let result = DeterministicQuantization.quantizeForPatchId(0.0001)
        XCTAssertEqual(result.quantized, 1)
        
        let result2 = DeterministicQuantization.quantizeForPatchId(0.0002)
        XCTAssertEqual(result2.quantized, 2)
    }
    
    func test_quantize_precision_separation() {
        // Verify two precisions are different
        let geomResult = DeterministicQuantization.quantizeForGeomId(0.0005)
        let patchResult = DeterministicQuantization.quantizeForPatchId(0.0005)
        
        // Same input should produce different quantized values
        XCTAssertNotEqual(geomResult.quantized, patchResult.quantized)
    }
    
    func test_quantize_negative_zero_normalized() {
        // A1: -0.0 must be normalized to +0.0
        let result = DeterministicQuantization.quantizeForGeomId(-0.0)
        XCTAssertEqual(result.quantized, 0)
        XCTAssertEqual(result.edgeCasesTriggered.count, 0)
    }
    
    func test_quantize_nan_inf_rejected_with_edgecase() {
        // A1: NaN/Inf must trigger EdgeCase
        let nanResult = DeterministicQuantization.quantizeForGeomId(Double.nan)
        XCTAssertTrue(nanResult.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED))
        
        let infResult = DeterministicQuantization.quantizeForGeomId(Double.infinity)
        XCTAssertTrue(infResult.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED))
    }
    
    func test_quantize_overflow_handling() {
        // Test Int64 overflow
        // Int64.max = 9223372036854775807
        // For geomId precision (0.001), overflow occurs when value > Int64.max * 0.001
        // That's approximately 9.223e15, but we use a smaller test value that's still very large
        // Use a value that, when divided by 0.001, exceeds Int64.max
        let largeValue = 1e16 // 10^16 / 0.001 = 10^19, which exceeds Int64.max
        let result = DeterministicQuantization.quantizeForGeomId(largeValue)
        
        // Should trigger COORDINATE_OUT_OF_RANGE or NAN_OR_INF_DETECTED
        XCTAssertTrue(
            result.edgeCasesTriggered.contains(.COORDINATE_OUT_OF_RANGE) ||
            result.edgeCasesTriggered.contains(.NAN_OR_INF_DETECTED),
            "Large value should trigger overflow edge case"
        )
    }
}
