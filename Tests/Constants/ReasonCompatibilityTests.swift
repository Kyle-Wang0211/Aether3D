// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ReasonCompatibilityTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Reason Compatibility Tests
//
// This test file validates reason->hint constraints.
//

import XCTest
@testable import Aether3DCore

/// Tests for reason compatibility rules (U1, U16).
///
/// **Rule ID:** U1, U16
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Reason compatibility rules are valid
/// - Precedence constraints are enforced
/// - Disallowed combinations are prevented
final class ReasonCompatibilityTests: XCTestCase {
    
    func test_reasonCompatibility_schema_valid() throws {
        let compat = try JSONTestHelpers.loadJSONDictionary(filename: "REASON_COMPATIBILITY.json")
        
        // Validate structure exists
        XCTAssertNotNil(compat["precedenceConstraints"],
            "REASON_COMPATIBILITY.json must have precedenceConstraints")
        XCTAssertNotNil(compat["allowedSecondaryReasons"],
            "REASON_COMPATIBILITY.json must have allowedSecondaryReasons")
        XCTAssertNotNil(compat["disallowedCombinations"],
            "REASON_COMPATIBILITY.json must have disallowedCombinations")
    }
    
    func test_reasonCompatibility_referencedCodesExist() throws {
        let compat = try JSONTestHelpers.loadJSONDictionary(filename: "REASON_COMPATIBILITY.json")
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        
        guard let catalogEntries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        let catalogCodes = Set(catalogEntries.compactMap { $0["code"] as? String })
        
        // Check precedence constraints
        if let precedence = compat["precedenceConstraints"] as? [[String: Any]] {
            for constraint in precedence {
                if let higherPriority = constraint["higherPriority"] as? String {
                    XCTAssertTrue(catalogCodes.contains(higherPriority),
                        "REASON_COMPATIBILITY.json references unknown code '\(higherPriority)'")
                }
                if let lowerPriority = constraint["lowerPriority"] as? [String] {
                    for code in lowerPriority {
                        XCTAssertTrue(catalogCodes.contains(code),
                            "REASON_COMPATIBILITY.json references unknown code '\(code)'")
                    }
                }
            }
        }
        
        // Check allowed secondary reasons
        if let allowed = compat["allowedSecondaryReasons"] as? [String: [String]] {
            for (primary, secondaries) in allowed {
                XCTAssertTrue(catalogCodes.contains(primary),
                    "REASON_COMPATIBILITY.json references unknown primary code '\(primary)'")
                for secondary in secondaries {
                    XCTAssertTrue(catalogCodes.contains(secondary),
                        "REASON_COMPATIBILITY.json references unknown secondary code '\(secondary)'")
                }
            }
        }
        
        // Check disallowed combinations
        if let disallowed = compat["disallowedCombinations"] as? [[String: Any]] {
            for combination in disallowed {
                if let primary = combination["primary"] as? String {
                    XCTAssertTrue(catalogCodes.contains(primary),
                        "REASON_COMPATIBILITY.json references unknown primary code '\(primary)'")
                }
                if let secondary = combination["secondary"] as? [String] {
                    for code in secondary {
                        XCTAssertTrue(catalogCodes.contains(code),
                            "REASON_COMPATIBILITY.json references unknown secondary code '\(code)'")
                    }
                }
            }
        }
    }
    
    func test_reasonCompatibility_captureOccludedPrecedence() throws {
        // U16: capture_occluded must outrank missing/boundary
        let compat = try JSONTestHelpers.loadJSONDictionary(filename: "REASON_COMPATIBILITY.json")
        
        guard let precedence = compat["precedenceConstraints"] as? [[String: Any]] else {
            XCTFail("REASON_COMPATIBILITY.json must have precedenceConstraints")
            return
        }
        
        var foundCaptureOccludedRule = false
        for constraint in precedence {
            if let higherPriority = constraint["higherPriority"] as? String,
               higherPriority == PrimaryReasonCode.CAPTURE_OCCLUDED.rawValue {
                foundCaptureOccludedRule = true
                if let lowerPriority = constraint["lowerPriority"] as? [String] {
                    XCTAssertTrue(lowerPriority.contains(PrimaryReasonCode.BOUNDARY_UNCERTAIN.rawValue),
                        "capture_occluded must outrank boundary_uncertain (U16)")
                }
                break
            }
        }
        
        XCTAssertTrue(foundCaptureOccludedRule,
            "REASON_COMPATIBILITY.json must define capture_occluded precedence rule (U16)")
    }
}
