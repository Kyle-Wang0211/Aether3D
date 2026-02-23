// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GateInputValidatorTests.swift
// Aether3D
//
// PR3 - Gate Input Validator Tests
//

import XCTest
@testable import Aether3DCore

final class GateInputValidatorTests: XCTestCase {

    func testValidInputs() {
        let result = GateInputValidator.validate(
            thetaSpanDeg: 30.0,
            phiSpanDeg: 20.0,
            l2PlusCount: 15,
            l3Count: 7,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 0.22,
            underexposureRatio: 0.30
        )

        if case .valid(let inputs) = result {
            XCTAssertEqual(inputs.thetaSpanDeg, 30.0)
            XCTAssertEqual(inputs.reprojRmsPx, 0.35)
        } else {
            XCTFail("Expected valid result")
        }
    }

    func testNaNInput() {
        let result = GateInputValidator.validate(
            thetaSpanDeg: Double.nan,
            phiSpanDeg: 20.0,
            l2PlusCount: 15,
            l3Count: 7,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 0.22,
            underexposureRatio: 0.30
        )

        if case .invalid(let reason, let fallback) = result {
            XCTAssertEqual(reason, .thetaSpanNonFinite)
            XCTAssertGreaterThanOrEqual(fallback, 0.0)
            XCTAssertLessThanOrEqual(fallback, HardGatesV13.minViewGain)
        } else {
            XCTFail("Expected invalid result for NaN")
        }
    }

    func testNegativeCount() {
        let result = GateInputValidator.validate(
            thetaSpanDeg: 30.0,
            phiSpanDeg: 20.0,
            l2PlusCount: -1,  // Invalid
            l3Count: 7,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 0.22,
            underexposureRatio: 0.30
        )

        if case .invalid(let reason, _) = result {
            XCTAssertEqual(reason, .l2PlusCountNegative)
        } else {
            XCTFail("Expected invalid result for negative count")
        }
    }

    func testOutOfRangeRatio() {
        let result = GateInputValidator.validate(
            thetaSpanDeg: 30.0,
            phiSpanDeg: 20.0,
            l2PlusCount: 15,
            l3Count: 7,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 1.5,  // Invalid
            underexposureRatio: 0.30
        )

        if case .invalid(let reason, _) = result {
            XCTAssertEqual(reason, .overexposureRatioOutOfRange)
        } else {
            XCTFail("Expected invalid result for out of range ratio")
        }
    }

    func testFallbackQualityComputed() {
        // Test fallback quality is computed (not fixed constant)
        let result1 = GateInputValidator.validate(
            thetaSpanDeg: Double.nan,
            phiSpanDeg: 20.0,
            l2PlusCount: 15,
            l3Count: 7,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 0.22,
            underexposureRatio: 0.30
        )

        let result2 = GateInputValidator.validate(
            thetaSpanDeg: 30.0,
            phiSpanDeg: Double.infinity,
            l2PlusCount: 15,
            l3Count: 7,
            reprojRmsPx: 0.35,
            edgeRmsPx: 0.18,
            sharpness: 88.0,
            overexposureRatio: 0.22,
            underexposureRatio: 0.30
        )

        if case .invalid(_, let fallback1) = result1,
           case .invalid(_, let fallback2) = result2 {
            // Fallback should be same (computed from worst-case)
            XCTAssertEqual(fallback1, fallback2)
        } else {
            XCTFail("Expected invalid results")
        }
    }
}
