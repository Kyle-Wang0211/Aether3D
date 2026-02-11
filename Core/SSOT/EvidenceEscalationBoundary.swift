// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceEscalationBoundary.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - Evidence Escalation Boundary (EEB)
//
// EEB belongs to PR#1, not PR#6.
// Defines the ONLY legal triggers and legality checks for EvidenceLevel escalation.
//

import Foundation

// MARK: - EvidenceLevel

/// Evidence level (constitutional, new in PR#1)
/// 
/// **Note:** Do NOT modify existing EvidenceConfidenceLevel enum in PR#1.
/// This is a new constitutional type for EEB.
public enum EvidenceLevel: UInt8, Codable, CaseIterable {
    case L0 = 0
    case L1 = 1
    case L2 = 2
    case L3_core = 3
    case L3_strict = 4
}

// MARK: - EEBTrigger

/// Evidence Escalation Boundary trigger (closed-world)
/// 
/// Defines the ONLY legal triggers that can upgrade EvidenceLevel.
/// Closed-world: adding new cases requires schema version bump.
public enum EEBTrigger: String, Codable, CaseIterable {
    /// A new observation passes all required validity gates
    case newValidObservation = "NEW_VALID_OBSERVATION"
    
    /// A new baseline pair satisfies L2 geometric constraints
    case newBaselineSatisfied = "NEW_BASELINE_SATISFIED"
    
    /// Appearance stability satisfies L3 constraints
    case newColorStabilitySatisfied = "NEW_COLOR_STABILITY_SATISFIED"
    
    /// Cross-epoch inheritance during migration
    /// Explicitly forbidden for L3
    case epochMigrationInheritance = "EPOCH_MIGRATION_INHERITANCE"
}

// MARK: - EEBGuard

/// Evidence Escalation Boundary guard
/// 
/// All escalation decisions must pass through EEBGuard.
/// Bypassing EEBGuard constitutes a constitutional violation.
public struct EEBGuard {
    /// Determines whether an EvidenceLevel escalation is legally allowed.
    ///
    /// - Parameters:
    ///   - from: Current EvidenceLevel
    ///   - to: Target EvidenceLevel
    ///   - trigger: The EEBTrigger that caused the escalation
    ///   - isCrossEpoch: Whether this escalation occurs during epoch migration
    ///
    /// - Returns: true if escalation is legal, false otherwise
    public static func allows(
        from: EvidenceLevel,
        to: EvidenceLevel,
        trigger: EEBTrigger,
        isCrossEpoch: Bool
    ) -> Bool {
        // Monotonicity is mandatory
        guard to.rawValue > from.rawValue else {
            return false
        }
        
        switch trigger {
        case .newValidObservation:
            // Only L0 → L1 is legal
            return from == .L0 && to == .L1
            
        case .newBaselineSatisfied:
            // Only L1 → L2 is legal
            return from == .L1 && to == .L2
            
        case .newColorStabilitySatisfied:
            // Only L2 → L3_core or L3_strict is legal
            return from == .L2 && (to == .L3_core || to == .L3_strict)
            
        case .epochMigrationInheritance:
            // Cross-epoch inheritance ceiling
            guard isCrossEpoch else { return false }
            // L3 must never survive migration
            return to.rawValue <= EvidenceLevel.L2.rawValue
        }
    }
}
