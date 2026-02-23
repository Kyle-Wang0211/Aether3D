// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  HintSuppression.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 5
//  HintSuppression - hint suppression logic
//

import Foundation

/// HintSuppression - manages hint suppression rules
public class HintSuppression {
    private var invalidHintCounts: [HintDomain: Int] = [:]
    
    public init() {}
    
    /// Check if hint should be suppressed due to invalidity
    /// Suppress after 2 invalid hints
    public func shouldSuppressInvalidHint(domain: HintDomain) -> Bool {
        let count: Int
        if let existing = invalidHintCounts[domain] {
            count = existing
        } else {
            count = 0
        }
        return count >= 2
    }
    
    /// Record invalid hint
    public func recordInvalidHint(domain: HintDomain) {
        let current: Int
        if let existing = invalidHintCounts[domain] {
            current = existing
        } else {
            current = 0
        }
        invalidHintCounts[domain] = current + 1
    }
    
    /// Check if strong hint should be suppressed due to white region
    /// Strong hints don't show when white region exists
    public func shouldSuppressStrongHintInWhiteRegion(hasWhiteRegion: Bool) -> Bool {
        return hasWhiteRegion
    }
    
    /// Check consistency rule
    /// Don't show hints that contradict dominantProblem
    public func shouldSuppressForConsistency(
        domain: HintDomain,
        dominantProblem: QualityProblem
    ) -> Bool {
        // Consistency check: don't show hints that contradict dominant problem
        switch (domain, dominantProblem) {
        case (.light, .brightness):
            return false  // Consistent
        case (.motion, .motion):
            return false  // Consistent
        case (.texture, .texture):
            return false  // Consistent
        case (.focus, .focus):
            return false  // Consistent
        default:
            return true  // Contradictory, suppress
        }
    }
}

