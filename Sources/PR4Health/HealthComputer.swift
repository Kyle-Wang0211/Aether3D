// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HealthComputer.swift
// PR4Health
//
// PR4 V10 - Pillar 37: Health computation (ISOLATED from Quality/Uncertainty/Gate)
//

import Foundation
import PR4Math

/// Health computer - ISOLATED module
///
/// V9 RULE: Health MUST NOT depend on Quality/Uncertainty/Gate.
/// This is enforced at compile time via dependency isolation.
public enum HealthComputer {
    
    /// Health threshold
    public static let healthThreshold: Double = 0.7
    
    /// Compute health from inputs
    ///
    /// V10 RULE: Only uses HealthInputs - no quality/uncertainty/gate values.
    public static func compute(_ inputs: HealthInputs) -> Double {
        // Weighted combination
        let consistencyWeight: Double = 0.4
        let coverageWeight: Double = 0.3
        let confidenceStabilityWeight: Double = 0.2
        let latencyWeight: Double = 0.1
        
        var health = inputs.consistency * consistencyWeight
        health += inputs.coverage * coverageWeight
        health += inputs.confidenceStability * confidenceStabilityWeight
        health += (inputs.latencyOK ? 1.0 : 0.0) * latencyWeight
        
        // Clamp to [0, 1]
        return Swift.max(0.0, Swift.min(1.0, health))
    }
    
    /// Check if health is above threshold
    public static func isHealthy(_ health: Double) -> Bool {
        return health >= healthThreshold
    }
}
