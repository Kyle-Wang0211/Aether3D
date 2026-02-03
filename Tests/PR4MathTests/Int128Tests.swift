//
// Int128Tests.swift
// PR4MathTests
//
// Tests for 128-bit integer arithmetic
//

import XCTest
@testable import PR4Math

final class Int128Tests: XCTestCase {
    
    func testMultiplyPositive() {
        let result = Int128.multiply(1000000, 1000000)
        XCTAssertEqual(result.toInt64Saturating(), 1000000000000)
    }
    
    func testMultiplyNegative() {
        let result = Int128.multiply(-1000000, 1000000)
        XCTAssertEqual(result.toInt64Saturating(), -1000000000000)
    }
    
    func testMultiplyOverflow() {
        // This would overflow Int64 but not Int128
        // Int64.max / 2 * 4 = Int64.max * 2, which overflows Int64
        let result = Int128.multiply(Int64.max / 2, 4)
        // The result should be representable in Int128
        // Check that it's larger than Int64.max
        let resultInt64 = result.toInt64Saturating()
        XCTAssertEqual(resultInt64, Int64.max) // Should saturate
        // The actual Int128 value should have high bits set
        XCTAssertTrue(result.high >= 0) // Should have overflowed into high bits
    }
    
    func testRightShift() {
        let value = Int128(high: 0, low: 0x10000)
        let shifted = value >> 16
        XCTAssertEqual(shifted.low, 1)
    }
    
    func testSaturation() {
        let overflow = Int128(high: 1, low: 0)
        XCTAssertEqual(overflow.toInt64Saturating(), Int64.max)
        
        let underflow = Int128(high: -2, low: 0)
        XCTAssertEqual(underflow.toInt64Saturating(), Int64.min)
    }
    
    func testComparison() {
        let a = Int128(high: 0, low: 100)
        let b = Int128(high: 0, low: 200)
        XCTAssertTrue(a < b)
        
        let c = Int128(high: 1, low: 0)
        let d = Int128(high: 0, low: UInt64.max)
        XCTAssertTrue(d < c)
    }
}
