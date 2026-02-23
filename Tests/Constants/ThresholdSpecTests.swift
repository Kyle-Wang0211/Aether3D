// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ThresholdSpecTests.swift
// Aether3D
//
// Tests for ThresholdSpec, MinLimitSpec, and related validation.
// PATCH E: Included in Phase 1.
//

import XCTest
@testable import Aether3DCore

final class ThresholdSpecTests: XCTestCase {
    func testThresholdSpecValidation() {
        let validSpec = ThresholdSpec(
            ssotId: "Test.threshold",
            name: "Test Threshold",
            unit: .ratio,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: 0.5,
            onExceed: .clamp,
            onUnderflow: .reject,
            documentation: "Test"
        )
        
        let errors = SSOTValidation.validate(validSpec)
        XCTAssertTrue(errors.isEmpty, "Valid spec should have no errors")
    }
    
    func testThresholdSpecInvalidMinMax() {
        let invalidSpec = ThresholdSpec(
            ssotId: "Test.threshold",
            name: "Test Threshold",
            unit: .ratio,
            category: .quality,
            min: 1.0,
            max: 0.0, // Invalid: min > max
            defaultValue: 0.5,
            onExceed: .clamp,
            onUnderflow: .reject,
            documentation: "Test"
        )
        
        let errors = SSOTValidation.validate(invalidSpec)
        XCTAssertFalse(errors.isEmpty, "Invalid spec should have errors")
        XCTAssertTrue(errors.contains { $0.contains("min") && $0.contains("max") })
    }
    
    func testMinLimitSpecValidation() {
        let validSpec = MinLimitSpec(
            ssotId: "Test.minLimit",
            name: "Test Min Limit",
            unit: .frames,
            minValue: 10,
            onUnderflow: .reject,
            documentation: "Test"
        )
        
        let errors = SSOTValidation.validate(validSpec)
        XCTAssertTrue(errors.isEmpty, "Valid min limit spec should have no errors")
    }
    
    func testMinLimitSpecInvalidValue() {
        let invalidSpec = MinLimitSpec(
            ssotId: "Test.minLimit",
            name: "Test Min Limit",
            unit: .frames,
            minValue: 0, // Invalid: must be positive
            onUnderflow: .reject,
            documentation: "Test"
        )
        
        let errors = SSOTValidation.validate(invalidSpec)
        XCTAssertFalse(errors.isEmpty, "Invalid min limit spec should have errors")
    }
    
    func testFixedConstantSpecValidation() {
        let validSpec = FixedConstantSpec(
            ssotId: "Test.fixed",
            name: "Test Fixed",
            unit: .bytes,
            value: 1024,
            documentation: "Test"
        )
        
        let errors = SSOTValidation.validate(validSpec)
        XCTAssertTrue(errors.isEmpty, "Valid fixed constant spec should have no errors")
    }
}

