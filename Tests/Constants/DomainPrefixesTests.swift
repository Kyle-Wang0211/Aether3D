// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DomainPrefixesTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Domain Prefixes Tests
//
// This test file validates domain separation prefix consistency.
//

import XCTest
@testable import Aether3DCore

/// Tests for domain separation prefixes (G1).
///
/// **Rule ID:** G1, A2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Domain prefixes match DOMAIN_PREFIXES.json
/// - Constants match catalog
/// - No ad-hoc prefixes allowed
final class DomainPrefixesTests: XCTestCase {
    
    func test_domainPrefixes_matchConstants() throws {
        let domainPrefixes = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        guard let prefixes = domainPrefixes["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        let prefixStrings = Set(prefixes.compactMap { $0["prefix"] as? String })
        
        // Verify constants match catalog
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_PATCH_ID),
            "DOMAIN_PREFIXES.json must include DOMAIN_PREFIX_PATCH_ID constant")
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_GEOM_ID),
            "DOMAIN_PREFIXES.json must include DOMAIN_PREFIX_GEOM_ID constant")
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_MESH_EPOCH),
            "DOMAIN_PREFIXES.json must include DOMAIN_PREFIX_MESH_EPOCH constant")
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_ASSET_ROOT),
            "DOMAIN_PREFIXES.json must include DOMAIN_PREFIX_ASSET_ROOT constant")
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_EVIDENCE),
            "DOMAIN_PREFIXES.json must include DOMAIN_PREFIX_EVIDENCE constant")
    }
    
    func test_domainPrefixes_allRegistered() throws {
        let domainPrefixes = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        guard let prefixes = domainPrefixes["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        // All prefixes must have required metadata
        for (index, prefix) in prefixes.enumerated() {
            XCTAssertNotNil(prefix["prefix"] as? String, "Prefix \(index) missing 'prefix' field")
            XCTAssertNotNil(prefix["purpose"] as? String, "Prefix \(index) missing 'purpose' field")
            XCTAssertNotNil(prefix["identityCritical"] as? Bool, "Prefix \(index) missing 'identityCritical' field")
            XCTAssertNotNil(prefix["introducedInVersion"] as? String, "Prefix \(index) missing 'introducedInVersion' field")
        }
    }
    
    func test_domainPrefixes_encoding_consistency() throws {
        let domainPrefixes = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        guard let prefixes = domainPrefixes["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        for prefixDict in prefixes {
            guard let prefixString = prefixDict["prefix"] as? String else { continue }
            
            // All prefixes must encode consistently
            let encoded = try DeterministicEncoding.encodeDomainPrefix(prefixString)
            XCTAssertGreaterThan(encoded.count, 4, "Prefix '\(prefixString)' must encode to at least length prefix")
            
            // Verify encoding format: uint32_be byteLength + UTF-8 bytes
            let length = UInt32(bigEndian: encoded.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })
            XCTAssertEqual(Int(length) + 4, encoded.count,
                "Prefix '\(prefixString)' encoding length mismatch")
        }
    }
}
