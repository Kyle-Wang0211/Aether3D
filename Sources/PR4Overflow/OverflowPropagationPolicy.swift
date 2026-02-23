// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// OverflowPropagationPolicy.swift
// PR4Overflow
//
// PR4 V10 - Pillar 23: Overflow propagation policy
//

import Foundation

/// Overflow propagation policy
///
/// V8 RULE: Define how overflows propagate through computation graph.
public enum OverflowPropagationPolicy {
    
    /// Propagation mode
    public enum PropagationMode {
        case stop      // Stop computation on overflow
        case clamp     // Clamp to bounds and continue
        case degrade   // Degrade quality and continue
        case isolate   // Isolate source and continue
    }
    
    /// Determine propagation mode for field
    public static func propagationMode(for field: String, tier: OverflowDetectionFramework.OverflowTier) -> PropagationMode {
        if OverflowTier0Fence.isTier0(field) {
            #if DETERMINISM_STRICT
            return .stop
            #else
            return .degrade
            #endif
        }
        
        switch tier {
        case .tier0:
            return .stop
        case .tier1:
            return .clamp
        case .tier2:
            return .isolate
        }
    }
    
    /// Propagate overflow through computation
    public static func propagate(
        field: String,
        tier: OverflowDetectionFramework.OverflowTier,
        affectedSources: Set<String>
    ) -> PropagationResult {
        let mode = propagationMode(for: field, tier: tier)
        
        switch mode {
        case .stop:
            return .stop(affectedSources: affectedSources)
        case .clamp:
            return .clamp(affectedSources: affectedSources)
        case .degrade:
            return .degrade(affectedSources: affectedSources, qualityPenalty: 0.1)
        case .isolate:
            return .isolate(affectedSources: affectedSources)
        }
    }
    
    public enum PropagationResult {
        case stop(affectedSources: Set<String>)
        case clamp(affectedSources: Set<String>)
        case degrade(affectedSources: Set<String>, qualityPenalty: Double)
        case isolate(affectedSources: Set<String>)
    }
}
