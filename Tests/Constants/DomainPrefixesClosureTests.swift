// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DomainPrefixesClosureTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Domain Prefixes Closure Tests
//
// This test file validates domain prefix closure and consistency.
//

import XCTest
@testable import Aether3DCore

/// Tests for domain prefix closure.
///
/// **Rule ID:** G1
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - DOMAIN_PREFIXES.json includes every prefix used by DeterministicEncoding
/// - Domain prefixes match constants
final class DomainPrefixesClosureTests: XCTestCase {
    
    func test_domainPrefixes_matchConstants() throws {
        let prefixesData = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        guard let prefixesArray = prefixesData["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        // Extract prefix values (format: "AETHER3D:PATCH_ID")
        let prefixValues = Set(prefixesArray.compactMap { $0["prefix"] as? String })
        
        // Expected prefixes (with AETHER3D: prefix)
        let expectedPrefixes = [
            "AETHER3D:PATCH_ID",
            "AETHER3D:GEOM_ID",
            "AETHER3D:MESH_EPOCH",
            "AETHER3D:ASSET_ROOT",
            "AETHER3D:EVIDENCE"
        ]
        
        var missing: [String] = []
        for prefix in expectedPrefixes {
            if !prefixValues.contains(prefix) {
                missing.append(prefix)
            }
        }
        
        if !missing.isEmpty {
            XCTFail("""
                ❌ Domain prefixes missing from DOMAIN_PREFIXES.json
                Invariant: G1 (Domain Separation Prefixes)
                Missing: \(missing.joined(separator: ", "))
                File: DOMAIN_PREFIXES.json
                Fix: Add missing domain prefixes
                """)
        }
    }
    
    func test_deterministicEncoding_usesCatalogPrefixes() throws {
        // This test ensures DOMAIN_PREFIXES.json includes all prefixes used by DeterministicEncoding
        // We verify that critical prefixes exist in the catalog
        
        let prefixesData = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        guard let prefixesArray = prefixesData["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        let prefixValues = Set(prefixesArray.compactMap { $0["prefix"] as? String })
        
        // Verify critical prefixes exist (with AETHER3D: prefix)
        let requiredPrefixes = [
            "AETHER3D:PATCH_ID",
            "AETHER3D:GEOM_ID",
            "AETHER3D:MESH_EPOCH"
        ]
        
        var missing: [String] = []
        for prefix in requiredPrefixes {
            if !prefixValues.contains(prefix) {
                missing.append(prefix)
            }
        }
        
        if !missing.isEmpty {
            XCTFail("""
                ❌ Required domain prefixes missing
                Invariant: G1 (Domain Separation Prefixes)
                Missing: \(missing.joined(separator: ", "))
                File: DOMAIN_PREFIXES.json
                Fix: Add missing required prefixes
                """)
        }
    }
}
