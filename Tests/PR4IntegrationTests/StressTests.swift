// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// StressTests.swift
// PR4IntegrationTests
//
// PR4 V10 - Stress tests for edge cases and boundary conditions
//

import XCTest
@testable import PR4Math
@testable import PR4Softmax
@testable import PR4LUT
@testable import PR4Overflow

final class StressTests: XCTestCase {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Boundary Value Tests
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Test Q16 arithmetic at boundaries
    func testQ16BoundaryValues() {
        // Test addition near boundaries
        // Note: Int64.max / 2 + Int64.max / 2 = Int64.max - 1, so it doesn't overflow
        // We need values that actually cause overflow
        let (_, overflow1) = Q16.add(Int64.max, 1)
        XCTAssertTrue(overflow1, "Int64.max + 1 should overflow")

        // Test that large but non-overflowing addition works
        let (sum2, overflow2) = Q16.add(Int64.max / 2, Int64.max / 2)
        XCTAssertFalse(overflow2, "Int64.max/2 + Int64.max/2 does not overflow (result is Int64.max - 1)")
        XCTAssertEqual(sum2, Int64.max - 1)

        // Test multiplication near boundaries
        let (prod1, overflow3) = Q16.multiply(65536, 65536)
        XCTAssertFalse(overflow3, "1.0 * 1.0 should not overflow")
        XCTAssertEqual(prod1, 65536, "1.0 * 1.0 = 1.0")

        // Note: Q16.multiply uses Int128 intermediate, so Int64.max * 65536 >> 16 = Int64.max
        // This does NOT overflow because the 128-bit intermediate handles it.
        // The multiplication result fits in Int64 after the right shift.
        let (prod2, overflow4) = Q16.multiply(Int64.max, 65536)
        XCTAssertFalse(overflow4, "Int64.max * 1.0 fits after shift")
        XCTAssertEqual(prod2, Int64.max, "Int64.max * 1.0 = Int64.max")

        // To cause actual overflow, we need a result that exceeds Int64.max after shift
        // Int64.max * Int64.max >> 16 will definitely overflow
        let (_, overflow5) = Q16.multiply(Int64.max, Int64.max)
        XCTAssertTrue(overflow5, "Int64.max * Int64.max should overflow")
    }
    
    /// Test softmax with extreme spread
    func testSoftmaxExtremeSpread() {
        // Maximum allowed spread: 32
        for spread in stride(from: 1, through: 32, by: 1) {
            let high = Int64(spread) * 65536
            let low = -Int64(spread) * 65536
            
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: [high, low])
            let sum = weights.reduce(0, +)
            
            XCTAssertEqual(sum, 65536,
                "Softmax sum != 65536 for spread \(spread): got \(sum)")
            
            XCTAssertTrue(weights.allSatisfy { $0 >= 0 },
                "Negative weight for spread \(spread)")
        }
    }
    
    /// Test softmax with many elements
    func testSoftmaxManyElements() {
        for count in [10, 50, 100, 500, 1000] {
            var rng = SplitMix64(seed: UInt64(count))
            let logits = (0..<count).map { _ in
                Int64.random(in: -10 * 65536...10 * 65536, using: &rng)
            }
            
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)
            
            XCTAssertEqual(sum, 65536,
                "Softmax sum != 65536 for count \(count): got \(sum)")
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - LUT Boundary Tests
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Test LUT at exact boundaries
    func testLUTBoundaries() {
        // Test exp(0) = 65536
        let expZero = RangeCompleteSoftmaxLUT.expQ16(0)
        XCTAssertEqual(expZero, 65536, "exp(0) should be exactly 65536")
        
        // Test exp(-1) is reasonable
        let expNeg1 = RangeCompleteSoftmaxLUT.expQ16(-65536)
        XCTAssertGreaterThan(expNeg1, 0, "exp(-1) should be > 0")
        XCTAssertLessThan(expNeg1, 65536, "exp(-1) should be < 1.0")
        
        // Test exp(-2) is reasonable
        let expNeg2 = RangeCompleteSoftmaxLUT.expQ16(-131072)
        XCTAssertGreaterThan(expNeg2, 0, "exp(-2) should be > 0")
        XCTAssertLessThan(expNeg2, expNeg1, "exp(-2) should be < exp(-1)")
    }
    
    /// Test LUT interpolation between points
    func testLUTInterpolation() {
        // Test halfway between LUT entries
        for i in stride(from: 0, to: -32 * 65536, by: -65536 / 2) {
            let x = Int64(i)
            let result = RangeCompleteSoftmaxLUT.expQ16(x)
            
            // Result should be monotonically decreasing
            let resultNext = RangeCompleteSoftmaxLUT.expQ16(x - 1)
            XCTAssertLessThanOrEqual(resultNext, result,
                "exp(\(x-1)) should be <= exp(\(x))")
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    
    init(seed: UInt64) { state = seed }
    
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
