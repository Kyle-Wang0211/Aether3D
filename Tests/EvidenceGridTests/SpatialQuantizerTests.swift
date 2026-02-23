// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SpatialQuantizerTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Spatial Quantizer Tests
//

import XCTest
@testable import Aether3DCore

final class SpatialQuantizerTests: XCTestCase {
    
    func testMortonCodeRoundTrip() {
        let quantizer = SpatialQuantizer(cellSize: LengthQ(scaleId: .geomId, quanta: 1))
        
        let worldPos = EvidenceVector3(x: 1.5, y: 2.7, z: 3.9)
        let quantizedPos = quantizer.quantize(worldPos)
        let mortonCode = quantizer.mortonCode(x: quantizedPos.x, y: quantizedPos.y, z: quantizedPos.z)
        
        // Decode back
        let decodedPos = quantizer.decodeMortonCode(mortonCode)
        
        // Should match quantized position
        XCTAssertEqual(decodedPos.x, quantizedPos.x)
        XCTAssertEqual(decodedPos.y, quantizedPos.y)
        XCTAssertEqual(decodedPos.z, quantizedPos.z)
    }
    
    func testDeterministicHashing() {
        let quantizer = SpatialQuantizer(cellSize: LengthQ(scaleId: .geomId, quanta: 1))
        
        let worldPos = EvidenceVector3(x: 1.0, y: 2.0, z: 3.0)
        let code1 = quantizer.mortonCode(from: worldPos)
        let code2 = quantizer.mortonCode(from: worldPos)
        
        XCTAssertEqual(code1, code2, "Same position must produce same Morton code")
    }
    
    func testDifferentPositionsDifferentKeys() {
        let quantizer = SpatialQuantizer(cellSize: LengthQ(scaleId: .geomId, quanta: 1))
        
        let pos1 = EvidenceVector3(x: 1.0, y: 2.0, z: 3.0)
        let pos2 = EvidenceVector3(x: 1.0, y: 2.0, z: 4.0)
        
        let code1 = quantizer.mortonCode(from: pos1)
        let code2 = quantizer.mortonCode(from: pos2)
        
        XCTAssertNotEqual(code1, code2, "Different positions must produce different Morton codes")
    }
}
