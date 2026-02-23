// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ExplanationCatalogCoverageTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Explanation Catalog Coverage Tests
//
// This test file validates explanation catalog completeness vs enums.
//

import XCTest
@testable import Aether3DCore

/// Tests for explanation catalog coverage (B1, B2, D2).
///
/// **Rule ID:** B1, B2, D2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - All enum cases have explanation entries
/// - Minimum explanation set is covered
/// - No empty hints when reason != NORMAL
final class ExplanationCatalogCoverageTests: XCTestCase {
    
    func test_allEdgeCaseTypes_haveExplanations() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        
        for edgeCase in EdgeCaseType.allCases {
            XCTAssertTrue(catalogCodes.contains(edgeCase.rawValue),
                "EdgeCaseType.\(edgeCase) (code: '\(edgeCase.rawValue)') must have entry in USER_EXPLANATION_CATALOG.json (B1)")
        }
    }
    
    func test_allRiskFlags_haveExplanations() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        
        for riskFlag in RiskFlag.allCases {
            XCTAssertTrue(catalogCodes.contains(riskFlag.rawValue),
                "RiskFlag.\(riskFlag) (code: '\(riskFlag.rawValue)') must have entry in USER_EXPLANATION_CATALOG.json (B1)")
        }
    }
    
    func test_allPrimaryReasonCodes_haveExplanations() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        
        for reasonCode in PrimaryReasonCode.allCases {
            XCTAssertTrue(catalogCodes.contains(reasonCode.rawValue),
                "PrimaryReasonCode.\(reasonCode) (code: '\(reasonCode.rawValue)') must have entry in USER_EXPLANATION_CATALOG.json (B2)")
        }
    }
    
    func test_allActionHintCodes_haveExplanations() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(entries.compactMap { $0["code"] as? String })
        
        for hintCode in ActionHintCode.allCases {
            XCTAssertTrue(catalogCodes.contains(hintCode.rawValue),
                "ActionHintCode.\(hintCode) (code: '\(hintCode.rawValue)') must have entry in USER_EXPLANATION_CATALOG.json (B2)")
        }
    }
    
    func test_minimumExplanationSet_covered() throws {
        let minimumSet = try JSONTestHelpers.loadJSONDictionary(filename: "MINIMUM_EXPLANATION_SET.json")
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        
        guard let catalogEntries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let catalogCodes = Set(catalogEntries.compactMap { $0["code"] as? String })
        
        if let mandatoryReasons = minimumSet["mandatoryPrimaryReasonCodes"] as? [String] {
            for code in mandatoryReasons {
                XCTAssertTrue(catalogCodes.contains(code),
                    "MINIMUM_EXPLANATION_SET.json requires '\(code)' but it's missing from USER_EXPLANATION_CATALOG.json (D2)")
            }
        }
        
        if let mandatoryHints = minimumSet["mandatoryActionHintCodes"] as? [String] {
            for code in mandatoryHints {
                XCTAssertTrue(catalogCodes.contains(code),
                    "MINIMUM_EXPLANATION_SET.json requires '\(code)' but it's missing from USER_EXPLANATION_CATALOG.json (D2)")
            }
        }
    }
    
    func test_actionableEntries_haveSuggestedActions() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        for (index, entry) in entries.enumerated() {
            if let actionable = entry["actionable"] as? Bool, actionable {
                if let suggestedActions = entry["suggestedActions"] as? [Any] {
                    XCTAssertFalse(suggestedActions.isEmpty,
                        "Entry \(index) (code: '\(entry["code"] ?? "unknown")') is actionable=true but has empty suggestedActions (B1)")
                } else {
                    XCTFail("Entry \(index) (code: '\(entry["code"] ?? "unknown")') is actionable=true but missing suggestedActions field")
                }
            }
        }
    }
    
    func test_nonNormalReasons_haveActionHints() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let normalCode = PrimaryReasonCode.NORMAL.rawValue
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  code.hasPrefix("PRC_"),
                  code != normalCode else {
                continue
            }
            
            // Non-NORMAL primary reasons should have suggested actions OR be explicitly non-actionable
            let actionable = entry["actionable"] as? Bool ?? false
            
            if actionable {
                if let suggestedActions = entry["suggestedActions"] as? [Any] {
                    if suggestedActions.isEmpty {
                        XCTFail("""
                            ❌ Primary reason '\(code)' (non-NORMAL, actionable=true) must have at least one action hint
                            Invariant: U2, EIA_001 (Explanation Integrity)
                            File: USER_EXPLANATION_CATALOG.json
                            Fix: Add suggestedActions OR set actionable=false with rationale
                            """)
                    }
                } else {
                    XCTFail("""
                        ❌ Primary reason '\(code)' (non-NORMAL, actionable=true) missing suggestedActions field
                        Invariant: U2, EIA_001 (Explanation Integrity)
                        File: USER_EXPLANATION_CATALOG.json
                        Fix: Add suggestedActions array OR set actionable=false with rationale
                        """)
                }
            } else {
                // Non-actionable entries should have rationale
                let technicalExplanation = entry["technicalExplanation"] as? String ?? ""
                if technicalExplanation.isEmpty {
                    XCTFail("""
                        ❌ Primary reason '\(code)' (non-NORMAL, actionable=false) must have technicalExplanation with rationale
                        Invariant: EIA_001 (Explanation Integrity)
                        File: USER_EXPLANATION_CATALOG.json
                        Fix: Add technicalExplanation explaining why no action is possible
                        """)
                }
            }
        }
    }
    
    func test_explanations_noFalseBlame() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let blamePatterns = [
            "you did",
            "you blocked",
            "you should have",
            "your fault",
            "you failed",
            "you didn't"
        ]
        
        var violations: [(code: String, text: String)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  let userExplanation = entry["userExplanation"] as? String else {
                continue
            }
            
            let lowerExplanation = userExplanation.lowercased()
            for pattern in blamePatterns {
                if lowerExplanation.contains(pattern) {
                    violations.append((code: code, text: userExplanation))
                    break
                }
            }
        }
        
        if !violations.isEmpty {
            let violationList = violations.map { "\($0.code): '\($0.text)'" }
            XCTFail("""
                ❌ Explanations contain user-blaming language
                Invariant: EIA_001 (Explanation Integrity - No False Blame)
                Violations: \(violationList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Rewrite explanations to use neutral language, focus on physical limitations
                """)
        }
    }
    
    func test_explanations_confidenceExplicit() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        // Check that explanations don't claim false certainty
        let certaintyWords = ["confirmed", "certain", "definitely", "always", "never"]
        var falseCertainty: [(code: String, text: String)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  code.hasPrefix("PRC_"),
                  let userExplanation = entry["userExplanation"] as? String else {
                continue
            }
            
            let lowerExplanation = userExplanation.lowercased()
            for word in certaintyWords {
                if lowerExplanation.contains(word) {
                    // Check if confidence level is appropriate
                    // This is a heuristic - manual review still required
                    falseCertainty.append((code: code, text: userExplanation))
                    break
                }
            }
        }
        
        // Note: This test warns but doesn't fail, as certainty language may be appropriate
        // Manual review is required for final validation
        if !falseCertainty.isEmpty {
            print("⚠️  Warning: Explanations contain certainty language - manual review recommended")
            print("   Codes: \(falseCertainty.map { $0.code }.joined(separator: ", "))")
        }
    }
}
