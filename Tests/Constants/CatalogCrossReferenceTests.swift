//
// CatalogCrossReferenceTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Catalog Cross-Reference Tests
//
// This test file validates cross-references between catalogs and enums.
//

import XCTest
@testable import Aether3DCore

/// Tests for catalog cross-reference integrity.
///
/// **Rule ID:** B1, B2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Every suggestedActions item exists as ActionHintCode
/// - Every PrimaryReasonCode exists in catalog
/// - Every EdgeCaseType and RiskFlag exists in catalog
final class CatalogCrossReferenceTests: XCTestCase {
    
    func test_suggestedActions_existAsActionHintCodes() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let actionHintCodes = Set(ActionHintCode.allCases.map { $0.rawValue })
        var missingHints: [String] = []
        
        for entry in entries {
            guard let suggestedActions = entry["suggestedActions"] as? [String] else { continue }
            
            for hint in suggestedActions {
                // Check if hint exists as ActionHintCode OR as catalog entry (for legacy/forward compatibility)
                if !actionHintCodes.contains(hint) {
                    // Check if it exists in catalog as action_hint category
                    let hintExists = entries.contains { e in
                        (e["code"] as? String) == hint && (e["category"] as? String) == "action_hint"
                    }
                    
                    if !hintExists {
                        let code = entry["code"] as? String ?? "unknown"
                        missingHints.append("\(code) -> \(hint)")
                    }
                }
            }
        }
        
        if !missingHints.isEmpty {
            XCTFail("""
                ❌ Suggested actions reference non-existent ActionHintCode or catalog entry
                Invariant: B1, B2 (Catalog Cross-Reference)
                Missing hints: \(missingHints.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Add missing ActionHintCode enum cases OR add catalog entries OR fix catalog references
                """)
        }
    }
    
    func test_suggestedActions_haveActionHintCategory() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        // Build map of code -> category
        var codeToCategory: [String: String] = [:]
        for entry in entries {
            if let code = entry["code"] as? String,
               let category = entry["category"] as? String {
                codeToCategory[code] = category
            }
        }
        
        var violations: [String] = []
        
        for entry in entries {
            guard let suggestedActions = entry["suggestedActions"] as? [String] else { continue }
            
            for hint in suggestedActions {
                if let category = codeToCategory[hint], category != "action_hint" {
                    let code = entry["code"] as? String ?? "unknown"
                    violations.append("\(code) -> \(hint) (category: \(category), expected: action_hint)")
                }
            }
        }
        
        if !violations.isEmpty {
            XCTFail("""
                ❌ Suggested actions must reference action_hint category entries
                Invariant: B1, B2 (Catalog Cross-Reference)
                Violations: \(violations.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Ensure all suggestedActions reference entries with category='action_hint'
                """)
        }
    }
    
    func test_primaryReasonCodes_existInCatalog() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        let reasonCodes = Set(PrimaryReasonCode.allCases.map { $0.rawValue })
        
        var missing: [String] = []
        for code in reasonCodes {
            if !catalogCodes.contains(code) {
                missing.append(code)
            }
        }
        
        if !missing.isEmpty {
            XCTFail("""
                ❌ PrimaryReasonCode enum cases missing from catalog
                Invariant: B1 (Catalog Completeness)
                Missing: \(missing.joined(separator: ", "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Add missing entries for all PrimaryReasonCode enum cases
                """)
        }
    }
    
    func test_edgeCaseTypes_existInCatalog() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        let edgeCases = Set(EdgeCaseType.allCases.map { $0.rawValue })
        
        var missing: [String] = []
        for code in edgeCases {
            if !catalogCodes.contains(code) {
                missing.append(code)
            }
        }
        
        if !missing.isEmpty {
            XCTFail("""
                ❌ EdgeCaseType enum cases missing from catalog
                Invariant: B1 (Catalog Completeness)
                Missing: \(missing.joined(separator: ", "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Add missing entries for all EdgeCaseType enum cases
                """)
        }
    }
    
    func test_riskFlags_existInCatalog() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        let riskFlags = Set(RiskFlag.allCases.map { $0.rawValue })
        
        var missing: [String] = []
        for code in riskFlags {
            if !catalogCodes.contains(code) {
                missing.append(code)
            }
        }
        
        if !missing.isEmpty {
            XCTFail("""
                ❌ RiskFlag enum cases missing from catalog
                Invariant: B1 (Catalog Completeness)
                Missing: \(missing.joined(separator: ", "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Add missing entries for all RiskFlag enum cases
                """)
        }
    }
}
