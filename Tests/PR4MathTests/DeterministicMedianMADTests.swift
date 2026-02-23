// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicMedianMADTests.swift
// PR4MathTests
//
// PR4 V10 - Deterministic median and MAD tests
//

import XCTest
@testable import PR4Math

final class DeterministicMedianMADTests: XCTestCase {
    
    func testMedianOddCount() {
        let values: [Int64] = [5, 2, 9, 1, 7, 3, 8, 4, 6]
        let median = DeterministicMedianMAD.medianQ16(values)
        XCTAssertEqual(median, 5)
    }
    
    func testMedianEvenCount() {
        let values: [Int64] = [5, 2, 9, 1, 7, 3]
        let median = DeterministicMedianMAD.medianQ16(values)
        XCTAssertEqual(median, 4)  // (3 + 5) / 2 = 4
    }
    
    func testMedianSingleElement() {
        let values: [Int64] = [42]
        let median = DeterministicMedianMAD.medianQ16(values)
        XCTAssertEqual(median, 42)
    }
    
    func testMAD() {
        let values: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let mad = DeterministicMedianMAD.madQ16(values)
        XCTAssertEqual(mad, 2)
    }
    
    func testMedianDeterministic() {
        let values: [Int64] = [9, 3, 7, 1, 5, 8, 2, 6, 4]
        
        var firstResult: Int64?
        for _ in 0..<100 {
            let result = DeterministicMedianMAD.medianQ16(values)
            if let first = firstResult {
                XCTAssertEqual(result, first)
            } else {
                firstResult = result
            }
        }
    }
}
