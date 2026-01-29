//
// CatalogActionabilityRulesTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Catalog Actionability Rules Tests
//
// This test file validates actionability rules and consistency.
//

import XCTest
@testable import Aether3DCore

/// Tests for catalog actionability rules.
///
/// **Rule ID:** EIA_001
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - actionable=true => suggestedActions non-empty
/// - action_hint entries have actionable=false
/// - Hints referenced in suggestedActions are actionable=false
final class CatalogActionabilityRulesTests: XCTestCase {
    
    func test_actionableTrue_hasSuggestedActions() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        var violations: [(code: String, category: String)] = []
        
        for entry in entries {
            guard let actionable = entry["actionable"] as? Bool,
                  actionable == true else { continue }
            
            let suggestedActions = entry["suggestedActions"] as? [Any] ?? []
            if suggestedActions.isEmpty {
                let code = entry["code"] as? String ?? "unknown"
                let category = entry["category"] as? String ?? "unknown"
                violations.append((code: code, category: category))
            }
        }
        
        if !violations.isEmpty {
            let violationList = violations.map { "\($0.code) (category: \($0.category))" }.joined(separator: "; ")
            XCTFail("""
                ❌ actionable=true entries must have non-empty suggestedActions
                Invariant: EIA_001 (Explanation Integrity - Actionability)
                Violations: \(violationList)
                File: USER_EXPLANATION_CATALOG.json
                Fix: Add suggestedActions OR set actionable=false with technicalExplanation rationale
                """)
        }
    }
    
    func test_actionHintEntries_areNotActionable() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        var violations: [String] = []
        
        for entry in entries {
            guard let category = entry["category"] as? String,
                  category == "action_hint" else { continue }
            
            if let actionable = entry["actionable"] as? Bool, actionable == true {
                let code = entry["code"] as? String ?? "unknown"
                violations.append(code)
            }
        }
        
        if !violations.isEmpty {
            XCTFail("""
                ❌ action_hint entries must have actionable=false
                Invariant: EIA_001 (Explanation Integrity - Actionability)
                Violations: \(violations.joined(separator: ", "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Set actionable=false for all action_hint category entries
                """)
        }
    }
    
    func test_suggestedActions_referenceNonActionableHints() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        // Build map of code -> actionable
        var codeToActionable: [String: Bool] = [:]
        for entry in entries {
            if let code = entry["code"] as? String,
               let actionable = entry["actionable"] as? Bool {
                codeToActionable[code] = actionable
            }
        }
        
        var violations: [String] = []
        
        for entry in entries {
            guard let suggestedActions = entry["suggestedActions"] as? [String] else { continue }
            
            for hint in suggestedActions {
                if let hintActionable = codeToActionable[hint], hintActionable == true {
                    let code = entry["code"] as? String ?? "unknown"
                    violations.append("\(code) -> \(hint) (hint is actionable=true, should be false)")
                }
            }
        }
        
        if !violations.isEmpty {
            XCTFail("""
                ❌ Suggested actions must reference actionable=false hints
                Invariant: EIA_001 (Explanation Integrity - Actionability)
                Violations: \(violations.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Ensure all hints referenced in suggestedActions have actionable=false
                """)
        }
    }
}
