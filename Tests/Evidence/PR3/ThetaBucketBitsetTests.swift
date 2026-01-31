//
// ThetaBucketBitsetTests.swift
// Aether3D
//
// PR3 - Theta Bucket Bitset Tests
//

import XCTest
@testable import Aether3DCore

final class ThetaBucketBitsetTests: XCTestCase {

    func testInsertContains() {
        var bitset = ThetaBucketBitset()
        XCTAssertFalse(bitset.contains(5))

        bitset.insert(5)
        XCTAssertTrue(bitset.contains(5))
        XCTAssertEqual(bitset.count, 1)
    }

    func testCount() {
        var bitset = ThetaBucketBitset()
        bitset.insert(0)
        bitset.insert(5)
        bitset.insert(10)
        XCTAssertEqual(bitset.count, 3)
    }

    func testPopcount() {
        var bitset = ThetaBucketBitset()
        for i in 0..<24 {
            bitset.insert(i)
        }
        XCTAssertEqual(bitset.count, 24)
    }

    func testDeterministicIteration() {
        var bitset = ThetaBucketBitset()
        bitset.insert(10)
        bitset.insert(5)
        bitset.insert(15)

        var indices: [Int] = []
        bitset.forEachBucket { index in
            indices.append(index)
        }

        // Should be in ascending order
        XCTAssertEqual(indices, [5, 10, 15])
    }

    func testClear() {
        var bitset = ThetaBucketBitset()
        bitset.insert(5)
        bitset.insert(10)
        bitset.clear()
        XCTAssertTrue(bitset.isEmpty)
        XCTAssertEqual(bitset.count, 0)
    }

    func testRawBitsSerialization() {
        var bitset = ThetaBucketBitset()
        bitset.insert(5)
        bitset.insert(10)

        let rawBits = bitset.rawBits
        let reconstructed = ThetaBucketBitset(rawBits: rawBits)

        XCTAssertEqual(reconstructed.count, bitset.count)
        XCTAssertTrue(reconstructed.contains(5))
        XCTAssertTrue(reconstructed.contains(10))
    }
}
