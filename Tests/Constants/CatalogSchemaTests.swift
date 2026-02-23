// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CatalogSchemaTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Catalog Schema Tests
//
// This test file validates JSON catalog schema correctness and completeness.
//

import XCTest
@testable import Aether3DCore

/// Tests for catalog schema validation.
///
/// **Rule ID:** D2, B1, C1, G1
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - All required schema fields exist
/// - Explanation catalog completeness
/// - Enum cases match catalog entries
/// - Domain prefixes are registered
/// - Breaking change surfaces are defined
final class CatalogSchemaTests: XCTestCase {
    
    // MARK: - USER_EXPLANATION_CATALOG.json Schema Validation
    
    func test_userExplanationCatalog_schema_complete() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let requiredFields = ["code", "category", "severity", "shortLabel", "userExplanation", 
                             "technicalExplanation", "appliesTo", "actionable", "suggestedActions"]
        
        for (index, entry) in entries.enumerated() {
            for field in requiredFields {
                if !entry.keys.contains(field) {
                    XCTFail("""
                        ❌ Entry \(index) missing required field '\(field)'
                        Invariant: B1
                        File: USER_EXPLANATION_CATALOG.json
                        Entry code: \(entry["code"] as? String ?? "unknown")
                        Fix: Add missing field '\(field)' to catalog entry
                        """)
                }
            }
            
            // Validate code format (uppercase snake-case recommended)
            if let code = entry["code"] as? String {
                XCTAssertFalse(code.isEmpty, "Entry \(index) has empty code")
                // Code should be uppercase with underscores
                let codePattern = "^[A-Z][A-Z0-9_]*$"
                let regex = try NSRegularExpression(pattern: codePattern)
                let range = NSRange(location: 0, length: code.utf16.count)
                XCTAssertTrue(regex.firstMatch(in: code, range: range) != nil,
                    "Entry \(index) code '\(code)' should be uppercase snake-case")
            }
            
            // Validate actionable consistency
            if let actionable = entry["actionable"] as? Bool, actionable {
                if let suggestedActions = entry["suggestedActions"] as? [Any] {
                    XCTAssertFalse(suggestedActions.isEmpty,
                        "Entry \(index) is actionable=true but has empty suggestedActions")
                }
            }
            
            // Validate appliesTo array
            if let appliesTo = entry["appliesTo"] as? [String] {
                XCTAssertFalse(appliesTo.isEmpty,
                    "Entry \(index) appliesTo array must not be empty")
            }
        }
    }
    
    // MARK: - MINIMUM_EXPLANATION_SET.json Validation
    
    func test_minimumExplanationSet_completeness() throws {
        let minimumSet = try JSONTestHelpers.loadJSONDictionary(filename: "MINIMUM_EXPLANATION_SET.json")
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        
        guard let catalogEntries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(catalogEntries.compactMap { $0["code"] as? String })
        
        // Check mandatory PrimaryReasonCodes
        if let mandatoryReasons = minimumSet["mandatoryPrimaryReasonCodes"] as? [String] {
            for code in mandatoryReasons {
                XCTAssertTrue(catalogCodes.contains(code),
                    "MINIMUM_EXPLANATION_SET.json requires '\(code)' but it's missing from USER_EXPLANATION_CATALOG.json")
            }
        }
        
        // Check mandatory ActionHintCodes
        if let mandatoryHints = minimumSet["mandatoryActionHintCodes"] as? [String] {
            for code in mandatoryHints {
                XCTAssertTrue(catalogCodes.contains(code),
                    "MINIMUM_EXPLANATION_SET.json requires '\(code)' but it's missing from USER_EXPLANATION_CATALOG.json")
            }
        }
    }
    
    // MARK: - Enum-to-Catalog Cross-Check
    
    func test_enumCases_haveExplanationCatalogEntries() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let catalogEntries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(catalogEntries.compactMap { $0["code"] as? String })
        
        // Check EdgeCaseType
        for edgeCase in EdgeCaseType.allCases {
            let code = edgeCase.rawValue
            XCTAssertTrue(catalogCodes.contains(code),
                "EdgeCaseType.\(edgeCase) (code: '\(code)') missing from USER_EXPLANATION_CATALOG.json")
        }
        
        // Check RiskFlag
        for riskFlag in RiskFlag.allCases {
            let code = riskFlag.rawValue
            XCTAssertTrue(catalogCodes.contains(code),
                "RiskFlag.\(riskFlag) (code: '\(code)') missing from USER_EXPLANATION_CATALOG.json")
        }
        
        // Check PrimaryReasonCode
        for reasonCode in PrimaryReasonCode.allCases {
            let code = reasonCode.rawValue
            XCTAssertTrue(catalogCodes.contains(code),
                "PrimaryReasonCode.\(reasonCode) (code: '\(code)') missing from USER_EXPLANATION_CATALOG.json")
        }
        
        // Check ActionHintCode
        for hintCode in ActionHintCode.allCases {
            let code = hintCode.rawValue
            XCTAssertTrue(catalogCodes.contains(code),
                "ActionHintCode.\(hintCode) (code: '\(code)') missing from USER_EXPLANATION_CATALOG.json")
        }
    }
    
    // MARK: - DOMAIN_PREFIXES.json Validation
    
    func test_domainPrefixes_complete() throws {
        let domainPrefixes = try JSONTestHelpers.loadJSONDictionary(filename: "DOMAIN_PREFIXES.json")
        
        guard let prefixes = domainPrefixes["prefixes"] as? [[String: Any]] else {
            XCTFail("DOMAIN_PREFIXES.json must have 'prefixes' array")
            return
        }
        
        let requiredPrefixes = [
            "AETHER3D:PATCH_ID",
            "AETHER3D:GEOM_ID",
            "AETHER3D:MESH_EPOCH",
            "AETHER3D:ASSET_ROOT",
            "AETHER3D:EVIDENCE"
        ]
        
        let prefixStrings = Set(prefixes.compactMap { $0["prefix"] as? String })
        
        for requiredPrefix in requiredPrefixes {
            XCTAssertTrue(prefixStrings.contains(requiredPrefix),
                "DOMAIN_PREFIXES.json missing required prefix '\(requiredPrefix)'")
        }
        
        // Validate each prefix has required fields
        for (index, prefix) in prefixes.enumerated() {
            let requiredFields = ["prefix", "purpose", "identityCritical", "introducedInVersion"]
            for field in requiredFields {
                XCTAssertTrue(prefix.keys.contains(field),
                    "Prefix \(index) missing required field '\(field)'")
            }
        }
        
        // Cross-check with constants
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_PATCH_ID),
            "DOMAIN_PREFIXES.json must include constant DOMAIN_PREFIX_PATCH_ID")
        XCTAssertTrue(prefixStrings.contains(DeterministicEncoding.DOMAIN_PREFIX_GEOM_ID),
            "DOMAIN_PREFIXES.json must include constant DOMAIN_PREFIX_GEOM_ID")
    }
    
    // MARK: - REASON_COMPATIBILITY.json Validation
    
    func test_reasonCompatibility_schema_complete() throws {
        let compat = try JSONTestHelpers.loadJSONDictionary(filename: "REASON_COMPATIBILITY.json")
        
        // Validate structure exists
        XCTAssertNotNil(compat["precedenceConstraints"], "REASON_COMPATIBILITY.json must have precedenceConstraints")
        XCTAssertNotNil(compat["allowedSecondaryReasons"], "REASON_COMPATIBILITY.json must have allowedSecondaryReasons")
        XCTAssertNotNil(compat["disallowedCombinations"], "REASON_COMPATIBILITY.json must have disallowedCombinations")
        
        // Validate referenced codes exist
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let catalogEntries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        let catalogCodes = Set(catalogEntries.compactMap { $0["code"] as? String })
        
        if let precedence = compat["precedenceConstraints"] as? [[String: Any]] {
            for constraint in precedence {
                if let higherPriority = constraint["higherPriority"] as? String {
                    XCTAssertTrue(catalogCodes.contains(higherPriority),
                        "REASON_COMPATIBILITY.json references unknown code '\(higherPriority)'")
                }
            }
        }
    }
    
    // MARK: - BREAKING_CHANGE_SURFACE.json Validation
    
    func test_breakingChangeSurface_complete() throws {
        let breakingSurface = try JSONTestHelpers.loadJSONDictionary(filename: "BREAKING_CHANGE_SURFACE.json")
        
        guard let surfaces = breakingSurface["breakingSurfaces"] as? [[String: Any]] else {
            XCTFail("BREAKING_CHANGE_SURFACE.json must have 'breakingSurfaces' array")
            return
        }
        
        let requiredSurfaces = [
            "encoding.byte_order",
            "encoding.string_format",
            "quant.geom_precision",
            "quant.patch_precision",
            "rounding_mode",
            "hash_algorithm",
            "color.white_point",
            "color.matrix"
        ]
        
        let surfaceIds = Set(surfaces.compactMap { $0["id"] as? String })
        
        for requiredSurface in requiredSurfaces {
            XCTAssertTrue(surfaceIds.contains(requiredSurface),
                "BREAKING_CHANGE_SURFACE.json missing required surface '\(requiredSurface)'")
        }
        
        // Validate each surface has RFC requirement
        for (index, surface) in surfaces.enumerated() {
            if let requires = surface["requires"] as? [String] {
                XCTAssertTrue(requires.contains("RFC"),
                    "Breaking surface \(index) must require RFC")
            }
        }
    }
    
    // MARK: - COLOR_MATRICES.json Validation
    
    func test_colorMatrices_schema_complete() throws {
        let matrices = try JSONTestHelpers.loadJSONDictionary(filename: "COLOR_MATRICES.json")
        
        // Validate D65 white point
        XCTAssertEqual(matrices["whitePoint"] as? String, "D65",
            "COLOR_MATRICES.json whitePoint must be D65")
        
        // Validate sRGB to XYZ matrix exists
        guard let sRGBToXYZ = matrices["sRGBToXYZ"] as? [String: Any],
              let matrix = sRGBToXYZ["matrix"] as? [[Double]] else {
            XCTFail("COLOR_MATRICES.json must have sRGBToXYZ.matrix")
            return
        }
        
        XCTAssertEqual(matrix.count, 3, "sRGBToXYZ matrix must have 3 rows")
        XCTAssertEqual(matrix[0].count, 3, "sRGBToXYZ matrix must have 3 columns")
        
        // Validate XYZ to Lab parameters exist
        guard let xyzToLab = matrices["xyzToLab"] as? [String: Any],
              let referenceWhite = xyzToLab["referenceWhite"] as? [String: Double] else {
            XCTFail("COLOR_MATRICES.json must have xyzToLab.referenceWhite")
            return
        }
        
        XCTAssertNotNil(referenceWhite["Xn"], "xyzToLab.referenceWhite must have Xn")
        XCTAssertNotNil(referenceWhite["Yn"], "xyzToLab.referenceWhite must have Yn")
        XCTAssertNotNil(referenceWhite["Zn"], "xyzToLab.referenceWhite must have Zn")
        
        // Cross-check with constants (exact numeric equality)
        let expectedMatrix = ColorSpaceConstants.SRGB_TO_XYZ_MATRIX
        for (i, row) in matrix.enumerated() {
            for (j, value) in row.enumerated() {
                XCTAssertEqual(value, expectedMatrix[i][j],
                    accuracy: 1e-10,
                    "COLOR_MATRICES.json matrix[\(i)][\(j)] must match ColorSpaceConstants exactly")
            }
        }
    }
    
    // MARK: - Golden Vector Schema Validation
    
    func test_goldenVectorsEncoding_schema_complete() throws {
        let vectors = try JSONTestHelpers.loadJSONDictionary(filename: "GOLDEN_VECTORS_ENCODING.json")
        
        guard let testVectors = vectors["testVectors"] as? [[String: Any]] else {
            XCTFail("GOLDEN_VECTORS_ENCODING.json must have 'testVectors' array")
            return
        }
        
        for (index, vector) in testVectors.enumerated() {
            XCTAssertNotNil(vector["name"], "Vector \(index) missing 'name'")
            XCTAssertNotNil(vector["expectedBytes"], "Vector \(index) missing 'expectedBytes'")
        }
    }
    
    func test_goldenVectorsQuantization_schema_complete() throws {
        let vectors = try JSONTestHelpers.loadJSONDictionary(filename: "GOLDEN_VECTORS_QUANTIZATION.json")
        
        guard let testVectors = vectors["testVectors"] as? [[String: Any]] else {
            XCTFail("GOLDEN_VECTORS_QUANTIZATION.json must have 'testVectors' array")
            return
        }
        
        for (index, vector) in testVectors.enumerated() {
            XCTAssertNotNil(vector["name"], "Vector \(index) missing 'name'")
            XCTAssertNotNil(vector["input"], "Vector \(index) missing 'input'")
            XCTAssertNotNil(vector["precision"], "Vector \(index) missing 'precision'")
            XCTAssertNotNil(vector["expectedQuantized"], "Vector \(index) missing 'expectedQuantized'")
        }
    }
    
    func test_goldenVectorsColor_schema_complete() throws {
        let vectors = try JSONTestHelpers.loadJSONDictionary(filename: "GOLDEN_VECTORS_COLOR.json")
        
        XCTAssertEqual(vectors["whitePoint"] as? String, "D65",
            "GOLDEN_VECTORS_COLOR.json whitePoint must be D65")
        
        guard let testVectors = vectors["testVectors"] as? [[String: Any]] else {
            XCTFail("GOLDEN_VECTORS_COLOR.json must have 'testVectors' array")
            return
        }
        
        for (index, vector) in testVectors.enumerated() {
            XCTAssertNotNil(vector["name"], "Vector \(index) missing 'name'")
            XCTAssertNotNil(vector["input"], "Vector \(index) missing 'input'")
            XCTAssertNotNil(vector["expectedLab"], "Vector \(index) missing 'expectedLab'")
        }
    }
}
