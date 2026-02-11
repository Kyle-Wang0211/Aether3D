// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceVector3Tests.swift
// Aether3D
//
// PR3 - EvidenceVector3 Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceVector3Tests: XCTestCase {

    func testSubtraction() {
        let a = EvidenceVector3(x: 1.0, y: 2.0, z: 3.0)
        let b = EvidenceVector3(x: 0.5, y: 1.0, z: 1.5)
        let result = a - b
        XCTAssertEqual(result.x, 0.5, accuracy: 1e-10)
        XCTAssertEqual(result.y, 1.0, accuracy: 1e-10)
        XCTAssertEqual(result.z, 1.5, accuracy: 1e-10)
    }

    func testLength() {
        let v = EvidenceVector3(x: 3.0, y: 4.0, z: 0.0)
        XCTAssertEqual(v.length(), 5.0, accuracy: 1e-10)
    }

    func testNormalized() {
        let v = EvidenceVector3(x: 3.0, y: 4.0, z: 0.0)
        let normalized = v.normalized()
        XCTAssertEqual(normalized.length(), 1.0, accuracy: 1e-10)
    }

    func testZeroVectorNormalized() {
        let v = EvidenceVector3.zero
        let normalized = v.normalized()
        XCTAssertEqual(normalized, EvidenceVector3.zero)
    }

    func testIsFinite() {
        let v1 = EvidenceVector3(x: 1.0, y: 2.0, z: 3.0)
        XCTAssertTrue(v1.isFinite())

        let v2 = EvidenceVector3(x: Double.infinity, y: 2.0, z: 3.0)
        XCTAssertFalse(v2.isFinite())

        let v3 = EvidenceVector3(x: Double.nan, y: 2.0, z: 3.0)
        XCTAssertFalse(v3.isFinite())
    }

    func testArrayInitialization() {
        let array: [Double] = [1.0, 2.0, 3.0]
        let v = EvidenceVector3(array: array)
        XCTAssertEqual(v.x, 1.0)
        XCTAssertEqual(v.y, 2.0)
        XCTAssertEqual(v.z, 3.0)
    }

    func testArrayInitializationShort() {
        let array: [Double] = [1.0, 2.0]
        let v = EvidenceVector3(array: array)
        XCTAssertEqual(v, EvidenceVector3.zero)
    }
}
