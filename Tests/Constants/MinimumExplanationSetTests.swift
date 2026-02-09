// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MinimumExplanationSetTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Minimum Explanation Set Tests
//
// This test file validates MINIMUM_EXPLANATION_SET compliance.
//

import XCTest
@testable import Aether3DCore

/// Tests for minimum explanation set compliance (D2).
///
/// **Rule ID:** D2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Minimum explanation set is complete
/// - All mandatory codes exist in catalog
/// - CI enforcement is possible
final class MinimumExplanationSetTests: XCTestCase {
    
    func test_minimumExplanationSet_allMandatoryCodesExist() throws {
        let minimumSet = try JSONTestHelpers.loadJSONDictionary(filename: "MINIMUM_EXPLANATION_SET.json")
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        
        guard let catalogEntries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(catalogEntries.compactMap { $0["code"] as? String })
        
        // Check mandatory PrimaryReasonCodes
        if let mandatoryReasons = minimumSet["mandatoryPrimaryReasonCodes"] as? [String] {
            XCTAssertFalse(mandatoryReasons.isEmpty,
                "MINIMUM_EXPLANATION_SET.json must define mandatoryPrimaryReasonCodes (D2)")
            
            for code in mandatoryReasons {
                XCTAssertTrue(catalogCodes.contains(code),
                    "MINIMUM_EXPLANATION_SET.json requires '\(code)' but it's missing from USER_EXPLANATION_CATALOG.json (D2)")
            }
        } else {
            XCTFail("MINIMUM_EXPLANATION_SET.json must have mandatoryPrimaryReasonCodes field (D2)")
        }
        
        // Check mandatory ActionHintCodes
        if let mandatoryHints = minimumSet["mandatoryActionHintCodes"] as? [String] {
            XCTAssertFalse(mandatoryHints.isEmpty,
                "MINIMUM_EXPLANATION_SET.json must define mandatoryActionHintCodes (D2)")
            
            for code in mandatoryHints {
                XCTAssertTrue(catalogCodes.contains(code),
                    "MINIMUM_EXPLANATION_SET.json requires '\(code)' but it's missing from USER_EXPLANATION_CATALOG.json (D2)")
            }
        } else {
            XCTFail("MINIMUM_EXPLANATION_SET.json must have mandatoryActionHintCodes field (D2)")
        }
    }
    
    func test_minimumExplanationSet_coversCriticalCodes() throws {
        let minimumSet = try JSONTestHelpers.loadJSONDictionary(filename: "MINIMUM_EXPLANATION_SET.json")
        
        guard let mandatoryReasons = minimumSet["mandatoryPrimaryReasonCodes"] as? [String] else {
            XCTFail("MINIMUM_EXPLANATION_SET.json must have mandatoryPrimaryReasonCodes")
            return
        }
        
        // Verify critical codes are included
        let criticalCodes = [
            PrimaryReasonCode.NORMAL.rawValue,
            PrimaryReasonCode.CAPTURE_OCCLUDED.rawValue,
            PrimaryReasonCode.STRUCTURAL_OCCLUSION_CONFIRMED.rawValue
        ]
        
        for code in criticalCodes {
            XCTAssertTrue(mandatoryReasons.contains(code),
                "MINIMUM_EXPLANATION_SET.json must include critical code '\(code)' (D2)")
        }
    }
    
    func test_minimumExplanationSet_ciEnforceable() {
        // Verify that CI can enforce minimum set
        // This test itself is the enforcement mechanism
        
        do {
            let minimumSet = try JSONTestHelpers.loadJSONDictionary(filename: "MINIMUM_EXPLANATION_SET.json")
            let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
            
            // If we can load both files and validate, CI enforcement is possible
            XCTAssertNotNil(minimumSet["mandatoryPrimaryReasonCodes"],
                "Minimum set must be machine-readable for CI enforcement")
            XCTAssertNotNil(catalog["entries"],
                "Catalog must be machine-readable for CI enforcement")
        } catch {
            XCTFail("CI enforcement requires both MINIMUM_EXPLANATION_SET.json and USER_EXPLANATION_CATALOG.json to be loadable: \(error)")
        }
    }
}
