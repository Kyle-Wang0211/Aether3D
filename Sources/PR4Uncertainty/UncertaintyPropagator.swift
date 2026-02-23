// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// UncertaintyPropagator.swift
// PR4Uncertainty
//
// PR4 V10 - Pillar 37: Uncertainty propagation
//

import Foundation
import PR4Math

/// Uncertainty propagator
///
/// Propagates uncertainty through computation graph.
public enum UncertaintyPropagator {
    
    /// Propagate uncertainty through addition
    public static func propagateAdd(
        u1: Double,
        u2: Double,
        correlation: Double = 0.0
    ) -> Double {
        // sqrt(u1² + u2² + 2*correlation*u1*u2)
        let u1Sq = u1 * u1
        let u2Sq = u2 * u2
        let crossTerm = 2.0 * correlation * u1 * u2
        return sqrt(u1Sq + u2Sq + crossTerm)
    }
    
    /// Propagate uncertainty through multiplication
    public static func propagateMultiply(
        value1: Double,
        u1: Double,
        value2: Double,
        u2: Double,
        correlation: Double = 0.0
    ) -> Double {
        // Relative uncertainties
        let r1 = u1 / abs(value1)
        let r2 = u2 / abs(value2)
        
        // Combined relative uncertainty
        let rCombined = sqrt(r1 * r1 + r2 * r2 + 2 * correlation * r1 * r2)
        
        // Absolute uncertainty
        return abs(value1 * value2) * rCombined
    }
}
