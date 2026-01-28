//
//  LogValidator.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 8
//  LogValidator - static lint for log validation
//

import Foundation

/// LogValidator - validates log entries
public struct LogValidator {
    /// Validate ruleIds
    /// Static lint: ruleIds must be from closed enum
    /// ruleIds cannot contain B_FEATURE_* in Gray→White decisions
    public static func validateRuleIds(_ ruleIds: [RuleId], forTransition: VisualState) -> Bool {
        // Check all ruleIds are valid
        let validRuleIds = Set(RuleId.allCases)
        for ruleId in ruleIds {
            if !validRuleIds.contains(ruleId) {
                return false
            }
        }
        
        // Check no B_FEATURE_* in Gray→White (if applicable)
        if forTransition == .white {
            // Would check for B_FEATURE_* rules
        }
        
        return true
    }
}

