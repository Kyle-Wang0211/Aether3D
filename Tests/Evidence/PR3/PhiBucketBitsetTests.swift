//
// PhiBucketBitsetTests.swift
// Aether3D
//
// PR3 - Phi Bucket Bitset Tests
//

import XCTest
@testable import Aether3DCore

final class PhiBucketBitsetTests: XCTestCase {

    func testInsertContains() {
        var bitset = PhiBucketBitset()
        XCTAssertFalse(bitset.contains(3))

        bitset.insert(3)
        XCTAssertTrue(bitset.contains(3))
        XCTAssertEqual(bitset.count, 1)
    }

    func testCount() {
        var bitset = PhiBucketBitset()
        bitset.insert(0)
        bitset.insert(6)
        bitset.insert(11)
        XCTAssertEqual(bitset.count, 3)
    }

    func testClear() {
        var bitset = PhiBucketBitset()
        bitset.insert(5)
        bitset.clear()
        XCTAssertTrue(bitset.isEmpty)
    }
}
