//
// QuantizerQ01Tests.swift
// Aether3D
//
// PR3 - QuantizerQ01 Tests
//

import XCTest
@testable import Aether3DCore

final class QuantizerQ01Tests: XCTestCase {

    func testQuantizeDequantize() {
        let value = 0.5
        let quantized = QuantizerQ01.quantize(value)
        let dequantized = QuantizerQ01.dequantize(quantized)
        XCTAssertEqual(dequantized, value, accuracy: 1e-12)
    }

    func testQuantizeClamps() {
        // Test clamping to [0, 1]
        let belowZero = QuantizerQ01.quantize(-0.1)
        XCTAssertEqual(belowZero, 0)

        let aboveOne = QuantizerQ01.quantize(1.5)
        XCTAssertEqual(aboveOne, QuantizerQ01.scaleInt64)
    }

    func testAreEqual() {
        let q1 = QuantizerQ01.quantize(0.5)
        let q2 = QuantizerQ01.quantize(0.5)
        XCTAssertTrue(QuantizerQ01.areEqual(q1, q2))
    }

    func testAreClose() {
        let q1 = QuantizerQ01.quantize(0.5)
        let q2 = QuantizerQ01.quantize(0.5 + 1e-13)  // Very close
        XCTAssertTrue(QuantizerQ01.areClose(q1, q2, tolerance: 1))
    }
}
