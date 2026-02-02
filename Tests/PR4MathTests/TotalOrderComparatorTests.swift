//
// TotalOrderComparatorTests.swift
// PR4MathTests
//
// PR4 V10 - Total order comparator tests
//

import XCTest
@testable import PR4Math

final class TotalOrderComparatorTests: XCTestCase {
    
    func testSanitizeNaN() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(.nan)
        XCTAssertEqual(result, 0.0)
        XCTAssertTrue(wasSpecial)
    }
    
    func testSanitizeInfinity() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(.infinity)
        XCTAssertEqual(result, Double.greatestFiniteMagnitude)
        XCTAssertTrue(wasSpecial)
    }
    
    func testSanitizeNegativeZero() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(-0.0)
        XCTAssertEqual(result, 0.0)
        XCTAssertTrue(result.sign == .plus)
        XCTAssertTrue(wasSpecial)
    }
    
    func testTotalOrderNaN() {
        let a = Double.nan
        let b = 0.0
        XCTAssertEqual(TotalOrderComparator.totalOrder(a, b),
                       TotalOrderComparator.totalOrder(a, b))
    }
    
    func testTotalOrderDeterministic() {
        let values: [Double] = [.nan, -.infinity, -1, -0.0, 0, 1, .infinity]
        var sorted = values
        sorted.sort { TotalOrderComparator.totalOrder($0, $1) < 0 }
        
        for _ in 0..<100 {
            var check = values
            check.sort { TotalOrderComparator.totalOrder($0, $1) < 0 }
            XCTAssertEqual(sorted.map { $0.bitPattern }, check.map { $0.bitPattern })
        }
    }
}
