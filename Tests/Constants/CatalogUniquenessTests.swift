//
// CatalogUniquenessTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Catalog Uniqueness Tests
//
// This test file validates catalog uniqueness and consistency.
//

import XCTest
@testable import Aether3DCore

/// Tests for catalog uniqueness and consistency (5.1).
///
/// **Rule ID:** 5.1
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - Global uniqueness of codes
/// - No duplicate shortLabel within same category
/// - Severity ↔ actionable consistency
/// - No dangling references
final class CatalogUniquenessTests: XCTestCase {
    
    func test_explanationCatalog_codeUniqueness() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        var codeSet = Set<String>()
        var duplicates: [String] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String else { continue }
            
            if codeSet.contains(code) {
                duplicates.append(code)
            } else {
                codeSet.insert(code)
            }
        }
        
        if !duplicates.isEmpty {
            XCTFail("""
                ❌ Duplicate codes found in USER_EXPLANATION_CATALOG.json
                Invariant: 5.1 (Catalog Uniqueness)
                Duplicates: \(duplicates.joined(separator: ", "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Remove duplicate entries or rename codes to be unique
                """)
        }
    }
    
    func test_explanationCatalog_shortLabelUniqueness() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        var labelMap: [String: [String]] = [:] // category -> [codes with same label]
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  let category = entry["category"] as? String,
                  let shortLabel = entry["shortLabel"] as? String else {
                continue
            }
            
            let key = "\(category):\(shortLabel)"
            if labelMap[key] == nil {
                labelMap[key] = []
            }
            labelMap[key]?.append(code)
        }
        
        var duplicates: [(category: String, label: String, codes: [String])] = []
        for (key, codes) in labelMap {
            if codes.count > 1 {
                let parts = key.split(separator: ":", maxSplits: 1)
                duplicates.append((
                    category: String(parts[0]),
                    label: String(parts[1]),
                    codes: codes
                ))
            }
        }
        
        if !duplicates.isEmpty {
            let duplicateList = duplicates.map { "\($0.category):'\($0.label)' (codes: \($0.codes.joined(separator: ", ")))" }
            XCTFail("""
                ❌ Duplicate shortLabel within same category in USER_EXPLANATION_CATALOG.json
                Invariant: 5.1 (Catalog Uniqueness)
                Duplicates: \(duplicateList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Rename shortLabel to be unique within category
                """)
        }
    }
    
    func test_explanationCatalog_severityActionableConsistency() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        var inconsistencies: [(code: String, severity: String, actionable: Bool)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  let severity = entry["severity"] as? String,
                  let actionable = entry["actionable"] as? Bool else {
                continue
            }
            
            // Critical severity should generally be actionable
            // Exception: action_hint category entries are actions themselves, so actionable=false is acceptable
            let category = entry["category"] as? String ?? ""
            if severity == "critical" && !actionable && category != "action_hint" {
                inconsistencies.append((code: code, severity: severity, actionable: actionable))
            }
        }
        
        if !inconsistencies.isEmpty {
            let inconsistencyList = inconsistencies.map { "\($0.code): severity=\($0.severity), actionable=\($0.actionable)" }
            XCTFail("""
                ❌ Severity ↔ actionable consistency violation in USER_EXPLANATION_CATALOG.json
                Invariant: 5.1 (Catalog Consistency)
                Inconsistencies: \(inconsistencyList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Review severity/actionable consistency OR add justification for non-actionable critical entries
                """)
        }
    }
    
    func test_explanationCatalog_noDanglingReferences() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        var danglingRefs: [(code: String, ref: String, field: String)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String else { continue }
            
            // Check suggestedActions references
            if let suggestedActions = entry["suggestedActions"] as? [String] {
                for actionCode in suggestedActions {
                    if !catalogCodes.contains(actionCode) {
                        danglingRefs.append((code: code, ref: actionCode, field: "suggestedActions"))
                    }
                }
            }
        }
        
        if !danglingRefs.isEmpty {
            let refList = danglingRefs.map { "\($0.code).\($0.field) → '\($0.ref)'" }
            XCTFail("""
                ❌ Dangling references in USER_EXPLANATION_CATALOG.json
                Invariant: 5.1 (Catalog Consistency)
                Dangling refs: \(refList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Remove dangling references OR add missing catalog entries
                """)
        }
    }
}
