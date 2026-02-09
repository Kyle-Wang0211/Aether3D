// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// LengthQTests.swift
// Aether3D
//
// Tests for LengthQ (quantization, serialization, multi-scale support)
//

import XCTest
@testable import Aether3DCore

final class LengthQTests: XCTestCase {
    
    // MARK: - Basic Tests
    
    func testLengthQCreation() {
        let length = LengthQ(scaleId: .geomId, quanta: 10)
        XCTAssertEqual(length.scaleId, .geomId)
        XCTAssertEqual(length.quanta, 10)
    }
    
    func testLengthQFromMeters() {
        let length = LengthQ.fromMeters(0.001, scale: .geomId)  // 1mm
        XCTAssertEqual(length.scaleId, .geomId)
        XCTAssertEqual(length.quanta, 1)
    }
    
    func testLengthQToMeters() {
        let length = LengthQ(scaleId: .geomId, quanta: 1)  // 1mm
        let meters = length.toMeters()
        XCTAssertEqual(meters, 0.001, accuracy: 1e-6)
    }
    
    // MARK: - Multi-Scale Tests
    
    func testLengthScaleQuantums() {
        XCTAssertEqual(LengthScale.geomId.quantumInNanometers, 1_000_000)  // 1mm
        XCTAssertEqual(LengthScale.patchId.quantumInNanometers, 100_000)   // 0.1mm
        XCTAssertEqual(LengthScale.systemMinimum.quantumInNanometers, 50_000) // 0.05mm
    }
    
    func testLengthQComparison() {
        let length1 = LengthQ(scaleId: .geomId, quanta: 1)      // 1mm
        let length2 = LengthQ(scaleId: .geomId, quanta: 2)      // 2mm
        let length3 = LengthQ(scaleId: .systemMinimum, quanta: 20) // 1mm (20 * 0.05mm)
        
        XCTAssertLessThan(length1, length2)
        XCTAssertEqual(length1, length3)  // Same length, different scales
    }
    
    // MARK: - Digest Input Tests
    
    func testDigestInput() {
        let length = LengthQ(scaleId: .geomId, quanta: 42)
        let digestInput = length.digestInput()
        
        XCTAssertEqual(digestInput.scaleId, LengthScale.geomId.rawValue)
        XCTAssertEqual(digestInput.quanta, 42)
    }
    
    func testDigestInputNoFloats() throws {
        let length = LengthQ(scaleId: .geomId, quanta: 42)
        let digestInput = length.digestInput()
        
        // Should encode without errors (no floats)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        XCTAssertFalse(digest.isEmpty)
    }
}
