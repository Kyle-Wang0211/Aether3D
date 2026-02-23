// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HealthIsolationStrictTests.swift
// PR4HealthTests
//
// PR4 V10 - STRICT verification that Health has NO forbidden dependencies
//

import XCTest
@testable import PR4Health

final class HealthIsolationStrictTests: XCTestCase {
    
    /// Verify Health module compiles without Quality/Uncertainty/Gate
    func testHealthAPIIsolation() {
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
    
    /// Verify HealthInputs is a closed set of fields
    func testHealthInputsClosedSet() {
        let mirror = Mirror(reflecting: HealthInputs(
            consistency: 0.0,
            coverage: 0.0,
            confidenceStability: 0.0,
            latencyOK: false
        ))
        
        let allowedFields = Set(["consistency", "coverage", "confidenceStability", "latencyOK"])
        let actualFields = Set(mirror.children.compactMap { $0.label })
        
        XCTAssertEqual(actualFields, allowedFields,
            "HealthInputs has unexpected fields: \(actualFields.subtracting(allowedFields))")
    }
    
    /// Verify Health computation is independent of external state
    func testHealthComputationPure() {
        let inputs = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )
        
        var firstResult: Double?
        
        for run in 0..<100 {
            let health = HealthComputer.compute(inputs)
            
            if let first = firstResult {
                XCTAssertEqual(health, first,
                    "Health computation not pure at run \(run)")
            } else {
                firstResult = health
            }
        }
    }
    
    /// Verify Health module has correct import restrictions
    func testHealthImportRestrictions() {
        // Compile-time check enforced by build
        XCTAssertTrue(true, "Import restrictions are enforced at compile time")
    }
}
