// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PackageDAGProof.swift
// PR4Package
//
// PR4 V10 - Pillar 3: Package DAG proof (Seal-15)
//

import Foundation

/// Package dependency graph proof
///
/// V10 RULE: Module dependencies must be explicitly declared and verified.
public enum PackageDAGProof {
    
    /// PR4 module targets and their allowed dependencies
    public static let targetDependencies: [String: Set<String>] = [
        "PR4Math": ["Foundation"],
        "PR4LUT": ["Foundation", "PR4Math"],
        "PR4Overflow": ["Foundation", "PR4Math"],
        "PR4PathTrace": ["Foundation"],
        "PR4Ownership": ["Foundation", "PR4Math", "PR4PathTrace"],
        "PR4Determinism": ["Foundation", "PR4Math", "PR4LUT"],
        "PR4Health": ["Foundation", "PR4Math"],
        "PR4Uncertainty": ["Foundation", "PR4Math"],
        "PR4Calibration": ["Foundation", "PR4Math"],
        "PR4Softmax": ["Foundation", "PR4Math", "PR4LUT", "PR4Overflow", "PR4PathTrace"],
    ]
    
    /// Forbidden dependency pairs
    public static let forbiddenDependencies: [(from: String, to: String, reason: String)] = [
        ("PR4Health", "PR4Quality", "Health must not depend on Quality"),
        ("PR4Health", "PR4Uncertainty", "Health must not depend on Uncertainty"),
        ("PR4Health", "PR4Gate", "Health must not depend on Gate"),
        ("PR4Math", "PR4LUT", "Math is foundational"),
    ]
    
    /// Verify a target's dependencies are allowed
    public static func verifyTarget(_ target: String, actualDependencies: Set<String>) -> [String] {
        var violations: [String] = []
        
        guard let allowedDeps = targetDependencies[target] else {
            violations.append("Unknown target: \(target)")
            return violations
        }
        
        let disallowed = actualDependencies.subtracting(allowedDeps)
        for dep in disallowed {
            violations.append("\(target) has undeclared dependency on \(dep)")
        }
        
        for forbidden in forbiddenDependencies {
            if forbidden.from == target && actualDependencies.contains(forbidden.to) {
                violations.append("\(target) → \(forbidden.to): FORBIDDEN - \(forbidden.reason)")
            }
        }
        
        return violations
    }
    
    /// Verify entire DAG is acyclic
    public static func verifyAcyclic() -> Bool {
        var visited: Set<String> = []
        var recursionStack: Set<String> = []
        
        func hasCycle(_ target: String) -> Bool {
            if recursionStack.contains(target) { return true }
            if visited.contains(target) { return false }
            
            visited.insert(target)
            recursionStack.insert(target)
            
            if let deps = targetDependencies[target] {
                for dep in deps {
                    if targetDependencies.keys.contains(dep) {
                        if hasCycle(dep) { return true }
                    }
                }
            }
            
            recursionStack.remove(target)
            return false
        }
        
        for target in targetDependencies.keys {
            if hasCycle(target) { return false }
        }
        
        return true
    }
}
