// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DynamicWeights4Tests.swift
// Aether3D
//
// PR6 Evidence Grid System - Dynamic Weights 4-Way Tests
//

import XCTest
@testable import Aether3DCore

final class DynamicWeights4Tests: XCTestCase {
    
    func testWeights4SumToOne() {
        // Test that weights4() returns weights that sum to 1.0
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let (gate, soft, provenance, advanced) = DynamicWeights.weights4(progress: progress)
            
            let sum = gate + soft + provenance + advanced
            XCTAssertEqual(sum, 1.0, accuracy: 0.01, "Weights at progress=\(progress) must sum to 1.0")
        }
    }
    
    func testWeights4AtProgressZero() {
        // At progress=0, gate should dominate
        let (gate, soft, provenance, advanced) = DynamicWeights.weights4(progress: 0.0)
        
        // Gate + provenance should be higher than soft + advanced
        XCTAssertGreaterThan(gate + provenance, soft + advanced, "At progress=0, gate should dominate")
    }
    
    func testWeights4AtProgressOne() {
        // At progress=1, soft should dominate
        let (gate, soft, provenance, advanced) = DynamicWeights.weights4(progress: 1.0)
        
        // Soft + advanced should be higher than gate + provenance
        XCTAssertGreaterThan(soft + advanced, gate + provenance, "At progress=1, soft should dominate")
    }
}
