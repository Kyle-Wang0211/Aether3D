// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CorrelationMatrix.swift
// PR4Uncertainty
//
// PR4 V10 - Pillar 31: Correlation source exhaustiveness
//

import Foundation
import PR4Math

/// Correlation matrix for uncertainty propagation
///
/// V8 RULE: All correlation sources must be explicitly tracked.
public struct CorrelationMatrix {
    
    /// Correlation values between sources
    private var correlations: [String: [String: Double]] = [:]
    
    /// Set correlation between two sources
    public mutating func setCorrelation(source1: String, source2: String, value: Double) {
        if correlations[source1] == nil {
            correlations[source1] = [:]
        }
        correlations[source1]?[source2] = Swift.max(-1.0, Swift.min(1.0, value))
        
        // Symmetric
        if correlations[source2] == nil {
            correlations[source2] = [:]
        }
        correlations[source2]?[source1] = Swift.max(-1.0, Swift.min(1.0, value))
    }
    
    /// Get correlation between two sources
    public func getCorrelation(source1: String, source2: String) -> Double {
        if source1 == source2 {
            return 1.0  // Self-correlation
        }
        return correlations[source1]?[source2] ?? 0.0
    }
}
