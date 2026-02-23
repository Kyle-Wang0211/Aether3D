// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QuantizerAngleTests.swift
// Aether3D
//
// PR3 - QuantizerAngle Tests
//

import XCTest
@testable import Aether3DCore

final class QuantizerAngleTests: XCTestCase {

    func testQuantizeDequantize() {
        let angle = 26.5
        let quantized = QuantizerAngle.quantize(angle)
        let dequantized = QuantizerAngle.dequantize(quantized)
        XCTAssertEqual(dequantized, angle, accuracy: 1e-9)
    }

    func testQuantizeHandlesNonFinite() {
        let nanResult = QuantizerAngle.quantize(Double.nan)
        XCTAssertEqual(nanResult, 0)

        let infResult = QuantizerAngle.quantize(Double.infinity)
        XCTAssertEqual(infResult, 0)
    }
}
