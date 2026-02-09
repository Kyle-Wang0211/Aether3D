// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ExplanationIntegrityTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Explanation Integrity Tests
//
// This test file validates explanation integrity and user trust guarantees.
//

import XCTest
@testable import Aether3DCore

/// Tests for explanation integrity (EIA_001).
///
/// **Rule ID:** EIA_001, B1, B2
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - No false blame language
/// - No false certainty
/// - Actionable or explicitly non-actionable
/// - User trust guarantees maintained
final class ExplanationIntegrityTests: XCTestCase {
    
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
            "you didn't",
            "your device",
            "you need to"
        ]
        
        var violations: [(code: String, text: String, field: String)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String else { continue }
            
            // Check userExplanation
            if let userExplanation = entry["userExplanation"] as? String {
                let lowerExplanation = userExplanation.lowercased()
                for pattern in blamePatterns {
                    if lowerExplanation.contains(pattern) {
                        violations.append((code: code, text: userExplanation, field: "userExplanation"))
                        break
                    }
                }
            }
            
            // Check shortLabel
            if let shortLabel = entry["shortLabel"] as? String {
                let lowerLabel = shortLabel.lowercased()
                for pattern in blamePatterns {
                    if lowerLabel.contains(pattern) {
                        violations.append((code: code, text: shortLabel, field: "shortLabel"))
                        break
                    }
                }
            }
        }
        
        if !violations.isEmpty {
            let violationList = violations.map { "\($0.code).\($0.field): '\($0.text)'" }
            XCTFail("""
                ❌ Explanations contain user-blaming language
                Invariant: EIA_001 (Explanation Integrity - No False Blame)
                Violations: \(violationList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Rewrite explanations to use neutral language, focus on physical limitations
                See: docs/constitution/EXPLANATION_INTEGRITY_AUDIT.md
                """)
        }
    }
    
    func test_explanations_actionableOrExplicitNonActionable() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        var violations: [(code: String, actionable: Bool, hasActions: Bool, hasRationale: Bool)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  code.hasPrefix("PRC_") else {
                continue
            }
            
            let actionable = entry["actionable"] as? Bool ?? false
            let suggestedActions = entry["suggestedActions"] as? [Any] ?? []
            let technicalExplanation = entry["technicalExplanation"] as? String ?? ""
            
            let hasActions = !suggestedActions.isEmpty
            let hasRationale = !technicalExplanation.isEmpty
            
            if actionable && !hasActions {
                violations.append((code: code, actionable: true, hasActions: false, hasRationale: hasRationale))
            } else if !actionable && !hasRationale {
                violations.append((code: code, actionable: false, hasActions: hasActions, hasRationale: false))
            }
        }
        
        if !violations.isEmpty {
            let violationList = violations.map { violation in
                if violation.actionable {
                    return "\(violation.code): actionable=true but no suggestedActions"
                } else {
                    return "\(violation.code): actionable=false but no technicalExplanation rationale"
                }
            }
            XCTFail("""
                ❌ Explanations must be actionable OR explicitly non-actionable
                Invariant: EIA_001 (Explanation Integrity - Actionability)
                Violations: \(violationList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Add suggestedActions for actionable entries OR add technicalExplanation rationale for non-actionable entries
                See: docs/constitution/EXPLANATION_INTEGRITY_AUDIT.md
                """)
        }
    }
    
    func test_explanations_noFalseCertainty() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        // Check that "confirmed" language is used appropriately
        // This is a heuristic - manual review still required
        var potentialIssues: [(code: String, text: String)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  code.hasPrefix("PRC_"),
                  let userExplanation = entry["userExplanation"] as? String else {
                continue
            }
            
            let lowerExplanation = userExplanation.lowercased()
            
            // Check for certainty words
            if lowerExplanation.contains("confirmed") || lowerExplanation.contains("definitely") {
                // Check if confidence level is appropriate
                // Note: This is a warning, not a failure - manual review required
                potentialIssues.append((code: code, text: userExplanation))
            }
        }
        
        // Note: This test warns but doesn't fail
        // Manual review is required for final validation
        if !potentialIssues.isEmpty {
            print("⚠️  Warning: Explanations contain certainty language - manual review recommended")
            print("   Invariant: EIA_001 (Explanation Integrity - No False Certainty)")
            print("   Codes: \(potentialIssues.map { $0.code }.joined(separator: ", "))")
            print("   See: docs/constitution/EXPLANATION_INTEGRITY_AUDIT.md")
        }
    }
    
    func test_explanations_userReadable() throws {
        let catalog = try JSONTestHelpers.loadJSONDictionary(filename: "USER_EXPLANATION_CATALOG.json")
        guard let entries = catalog["entries"] as? [[String: Any]] else {
            XCTFail("USER_EXPLANATION_CATALOG.json must have 'entries' array")
            return
        }
        
        let technicalTerms = [
            "quantization",
            "deterministic",
            "mesh epoch",
            "patch id",
            "geom id",
            "l3 evidence",
            "s-state",
            "piz score"
        ]
        
        var violations: [(code: String, text: String)] = []
        
        for entry in entries {
            guard let code = entry["code"] as? String,
                  let userExplanation = entry["userExplanation"] as? String else {
                continue
            }
            
            let lowerExplanation = userExplanation.lowercased()
            for term in technicalTerms {
                if lowerExplanation.contains(term) {
                    violations.append((code: code, text: userExplanation))
                    break
                }
            }
        }
        
        if !violations.isEmpty {
            let violationList = violations.map { "\($0.code): '\($0.text)'" }
            XCTFail("""
                ❌ Explanations contain technical jargon without user translation
                Invariant: EIA_001 (Explanation Integrity - User Readability)
                Violations: \(violationList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Rewrite userExplanation to avoid technical terms OR provide user-friendly translation
                See: docs/constitution/EXPLANATION_INTEGRITY_AUDIT.md
                """)
        }
    }
    
    func test_explanations_severityConsistency() throws {
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
            if severity == "critical" && !actionable {
                let category = entry["category"] as? String ?? ""
                if category != "action_hint" {
                    inconsistencies.append((code: code, severity: severity, actionable: actionable))
                }
            }
        }
        
        if !inconsistencies.isEmpty {
            let inconsistencyList = inconsistencies.map { "\($0.code): severity=\($0.severity), actionable=\($0.actionable)" }
            XCTFail("""
                ❌ Severity ↔ actionable consistency violation
                Invariant: EIA_001 (Explanation Integrity - Consistency)
                Inconsistencies: \(inconsistencyList.joined(separator: "; "))
                File: USER_EXPLANATION_CATALOG.json
                Fix: Review severity/actionable consistency OR add justification for non-actionable critical entries
                See: docs/constitution/EXPLANATION_INTEGRITY_AUDIT.md
                """)
        }
    }
}
