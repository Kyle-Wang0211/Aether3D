// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CircularSpanBitsetTests.swift
// Aether3D
//
// PR3 - Circular Span Bitset Tests
//

import XCTest
@testable import Aether3DCore

final class CircularSpanBitsetTests: XCTestCase {

    func testCircularSpanWrapAround() {
        // Test wrap-around: buckets at 0° and 350° should have small span
        var bitset = ThetaBucketBitset()
        bitset.insert(0)   // 0° - 15°
        bitset.insert(23)  // 345° - 360°

        let span = CircularSpanBitset.computeSpanBuckets(bitset)
        // Should be 2 buckets (not 23)
        XCTAssertEqual(span, 2)
    }

    func testCircularSpanAllFilled() {
        var bitset = ThetaBucketBitset()
        for i in 0..<24 {
            bitset.insert(i)
        }

        let span = CircularSpanBitset.computeSpanBuckets(bitset)
        XCTAssertEqual(span, 24)
    }

    func testCircularSpanEmpty() {
        let bitset = ThetaBucketBitset()
        let span = CircularSpanBitset.computeSpanBuckets(bitset)
        XCTAssertEqual(span, 0)
    }

    func testCircularSpanSingleBucket() {
        var bitset = ThetaBucketBitset()
        bitset.insert(5)
        let span = CircularSpanBitset.computeSpanBuckets(bitset)
        XCTAssertEqual(span, 0)  // Single point has no span
    }

    func testLinearSpanPhi() {
        var bitset = PhiBucketBitset()
        bitset.insert(0)
        bitset.insert(5)
        bitset.insert(11)

        let span = CircularSpanBitset.computeLinearSpanBuckets(bitset)
        XCTAssertEqual(span, 11)  // Last - first
    }

    func testSpanToDegrees() {
        let bucketSpan = 4
        let degrees = CircularSpanBitset.spanToDegrees(bucketSpan, bucketSizeDeg: 15.0)
        XCTAssertEqual(degrees, 60.0)
    }
}
