// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZInputValidatorTests.swift
// Aether3D
//
// PR1 PIZ Detection - Input Validation Tests
//
// Tests for input validation including shape, float classification, and range checks.
// **Rule ID:** PIZ_INPUT_VALIDATION_001, PIZ_INPUT_VALIDATION_002, PIZ_FLOAT_CLASSIFICATION_001

import XCTest
@testable import Aether3DCore

final class PIZInputValidatorTests: XCTestCase {
    
    /// Test valid 32x32 heatmap passes validation.
    func testValidHeatmap() {
        let heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        let result = PIZInputValidator.validate(heatmap)
        
        if case .valid = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Valid heatmap should pass validation")
        }
    }
    
    /// Test non-32x32 shape is rejected.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_002
    func testInvalidShape() {
        let heatmap = Array(repeating: Array(repeating: 0.5, count: 31), count: 32)
        let result = PIZInputValidator.validate(heatmap)
        
        if case .invalid(let reason) = result {
            XCTAssertTrue(reason.contains("32"))
        } else {
            XCTFail("Invalid shape should be rejected")
        }
    }
    
    /// Test NaN values are rejected.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_002
    func testNaNRejected() {
        var heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        heatmap[0][0] = Double.nan
        let result = PIZInputValidator.validate(heatmap)
        
        if case .invalid(let reason) = result {
            XCTAssertTrue(reason.contains("NaN"))
        } else {
            XCTFail("NaN should be rejected")
        }
    }
    
    /// Test ±Inf values are rejected.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_002
    func testInfiniteRejected() {
        var heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        heatmap[0][0] = Double.infinity
        let result = PIZInputValidator.validate(heatmap)
        
        if case .invalid(let reason) = result {
            XCTAssertTrue(reason.contains("Infinite"))
        } else {
            XCTFail("Infinity should be rejected")
        }
    }
    
    /// Test subnormal values are rejected.
    /// **Rule ID:** PIZ_FLOAT_CLASSIFICATION_001
    func testSubnormalRejected() {
        var heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        // Create a subnormal value deterministically
        // Use nextDown from a very small normal value to get a subnormal
        let tinyNormal = Double.leastNormalMagnitude
        let subnormal = tinyNormal.nextDown // This should be subnormal
        heatmap[0][0] = subnormal
        let result = PIZInputValidator.validate(heatmap)
        
        if case .invalid(let reason) = result {
            XCTAssertTrue(reason.contains("Subnormal") || reason.contains("subnormal"), "Expected subnormal rejection, got: \(reason)")
        } else {
            // If subnormal check doesn't work, verify the value is actually subnormal
            if subnormal.isSubnormal {
                XCTFail("Subnormal should be rejected but validation passed. Value: \(subnormal), isSubnormal: \(subnormal.isSubnormal)")
            } else {
                // Value might have been normalized, skip this test
                print("Skipping subnormal test: value is not subnormal (\(subnormal))")
            }
        }
    }
    
    /// Test zero is allowed.
    /// **Rule ID:** PIZ_FLOAT_CLASSIFICATION_001
    func testZeroAllowed() {
        var heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        heatmap[0][0] = 0.0
        heatmap[0][1] = -0.0
        
        let result = PIZInputValidator.validate(heatmap)
        if case .valid = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Zero should be allowed")
        }
    }
    
    /// Test values outside [0.0, 1.0] are rejected.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_002
    func testRangeValidation() {
        var heatmap = Array(repeating: Array(repeating: 0.5, count: 32), count: 32)
        heatmap[0][0] = -0.1
        let result1 = PIZInputValidator.validate(heatmap)
        
        if case .invalid(let reason) = result1 {
            XCTAssertTrue(reason.contains("range"))
        } else {
            XCTFail("Value < 0.0 should be rejected")
        }
        
        heatmap[0][0] = 1.1
        let result2 = PIZInputValidator.validate(heatmap)
        
        if case .invalid(let reason) = result2 {
            XCTAssertTrue(reason.contains("range"))
        } else {
            XCTFail("Value > 1.0 should be rejected")
        }
    }
    
    /// Test INSUFFICIENT_DATA report creation.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_001
    func testInsufficientDataReport() {
        let report = PIZInputValidator.createInsufficientDataReport(reason: "Test reason")
        
        XCTAssertEqual(report.gateRecommendation, .insufficientData)
        XCTAssertEqual(report.globalTrigger, false)
        XCTAssertEqual(report.localTriggerCount, 0)
        XCTAssertEqual(report.regions?.count ?? 0, 0)
    }
}
