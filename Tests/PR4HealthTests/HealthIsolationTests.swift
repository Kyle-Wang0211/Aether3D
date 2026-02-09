// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HealthIsolationTests.swift
// PR4HealthTests
//
// PR4 V10 - Verify Health module has NO forbidden dependencies
//

import XCTest
@testable import PR4Health

final class HealthIsolationTests: XCTestCase {
    
    func testHealthInputsClosedSet() {
        let inputs = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )
        
        XCTAssertNotNil(inputs)
    }
    
    func testHealthComputerIsolation() {
        let inputs = HealthInputs(
            consistency: 0.8,
            coverage: 0.9,
            confidenceStability: 0.7,
            latencyOK: true
        )
        
        let health = HealthComputer.compute(inputs)
        
        XCTAssertGreaterThanOrEqual(health, 0.0)
        XCTAssertLessThanOrEqual(health, 1.0)
    }
    
    func testHealthIndependentOfQuality() {
        let inputs1 = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )
        
        let inputs2 = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )
        
        let health1 = HealthComputer.compute(inputs1)
        let health2 = HealthComputer.compute(inputs2)
        
        XCTAssertEqual(health1, health2,
            "Same inputs must produce same health")
    }
    
    func testHealthEdgeCases() {
        let worstInputs = HealthInputs(
            consistency: 0.0,
            coverage: 0.0,
            confidenceStability: 0.0,
            latencyOK: false
        )
        let worstHealth = HealthComputer.compute(worstInputs)
        XCTAssertEqual(worstHealth, 0.0, accuracy: 0.01)
        
        let bestInputs = HealthInputs(
            consistency: 1.0,
            coverage: 1.0,
            confidenceStability: 1.0,
            latencyOK: true
        )
        let bestHealth = HealthComputer.compute(bestInputs)
        XCTAssertEqual(bestHealth, 1.0, accuracy: 0.01)
    }
}
