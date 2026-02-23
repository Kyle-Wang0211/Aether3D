// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// BuildMode Wire Contract Tests
// PR1 C-Class: Ensures BuildMode wire values remain stable
// ============================================================================

import XCTest
@testable import Aether3DCore

/// Wire contract tests for BuildMode
/// 
/// These tests ensure that JSON encode/decode roundtrips work correctly
/// and that rawValue strings match expected wire format exactly.
final class BuildModeWireContractTests: XCTestCase {
    
    // MARK: - RawValue Tests
    
    func testNormalRawValue() {
        XCTAssertEqual(
            BuildMode.NORMAL.rawValue,
            "NORMAL",
            "BuildMode.NORMAL rawValue must be exactly 'NORMAL'"
        )
    }
    
    func testDampingRawValue() {
        XCTAssertEqual(
            BuildMode.DAMPING.rawValue,
            "DAMPING",
            "BuildMode.DAMPING rawValue must be exactly 'DAMPING'"
        )
    }
    
    func testSaturatedRawValue() {
        XCTAssertEqual(
            BuildMode.SATURATED.rawValue,
            "SATURATED",
            "BuildMode.SATURATED rawValue must be exactly 'SATURATED'"
        )
    }
    
    // MARK: - JSON Roundtrip Tests
    
    func testNormalJsonRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let original = BuildMode.NORMAL
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(BuildMode.self, from: encoded)
        
        XCTAssertEqual(decoded, original, "BuildMode.NORMAL must survive JSON roundtrip")
        XCTAssertEqual(decoded.rawValue, "NORMAL", "Decoded value must have correct rawValue")
    }
    
    func testDampingJsonRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let original = BuildMode.DAMPING
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(BuildMode.self, from: encoded)
        
        XCTAssertEqual(decoded, original, "BuildMode.DAMPING must survive JSON roundtrip")
        XCTAssertEqual(decoded.rawValue, "DAMPING", "Decoded value must have correct rawValue")
    }
    
    func testSaturatedJsonRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let original = BuildMode.SATURATED
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(BuildMode.self, from: encoded)
        
        XCTAssertEqual(decoded, original, "BuildMode.SATURATED must survive JSON roundtrip")
        XCTAssertEqual(decoded.rawValue, "SATURATED", "Decoded value must have correct rawValue")
    }
    
    // MARK: - JobState CapacitySaturated Wire Tests
    
    func testCapacitySaturatedRawValue() {
        XCTAssertEqual(
            JobState.capacitySaturated.rawValue,
            "capacity_saturated",
            "JobState.capacitySaturated rawValue must be exactly 'capacity_saturated'"
        )
    }
    
    func testCapacitySaturatedJsonRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let original = JobState.capacitySaturated
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(JobState.self, from: encoded)
        
        XCTAssertEqual(decoded, original, "JobState.capacitySaturated must survive JSON roundtrip")
        XCTAssertEqual(decoded.rawValue, "capacity_saturated", "Decoded value must have correct rawValue")
    }
}
