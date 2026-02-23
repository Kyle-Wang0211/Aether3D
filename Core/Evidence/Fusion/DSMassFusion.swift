// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DSMassFusion.swift
// Aether3D
//
// PR6 Evidence Grid System - Dempster-Shafer Mass Fusion
// Implements D-S theory for evidence fusion with conflict handling
//

import Foundation

/// **Rule ID:** PR6_GRID_MASS_001
/// D-S Mass Function: (occupied, free, unknown)
/// Invariant: occupied + free + unknown = 1.0 (within EPS)
public struct DSMassFunction: Codable, Sendable, Equatable {
    /// Mass assigned to "occupied" hypothesis
    @ClampedEvidence public var occupied: Double
    
    /// Mass assigned to "free" hypothesis
    @ClampedEvidence public var free: Double
    
    /// Mass assigned to "unknown" hypothesis
    @ClampedEvidence public var unknown: Double
    
    public init(occupied: Double, free: Double, unknown: Double) {
        self.occupied = occupied
        self.free = free
        self.unknown = unknown
        
        // Enforce invariant: sum = 1.0
        self = self.normalized()
    }
    
    /// Internal initializer that skips normalization
    /// Used by DSMassFusion and sealed()/normalized() to break recursion
    internal init(rawOccupied: Double, rawFree: Double, rawUnknown: Double) {
        // Directly assign the values (bypasses normalization)
        self.occupied = rawOccupied
        self.free = rawFree
        self.unknown = rawUnknown
        // Skip normalization - caller ensures sum = 1.0
    }
    
    /// **Rule ID:** PR6_GRID_MASS_002
    /// Normalize mass function to ensure sum = 1.0
    private func normalized() -> DSMassFunction {
        let sum = occupied + free + unknown
        
        // If sum is too small, return vacuous mass
        guard sum > EvidenceConstants.dsEpsilon else {
            return DSMassFunction.vacuous
        }
        
        // Normalize using internal init to avoid recursion
        return DSMassFunction(
            rawOccupied: occupied / sum,
            rawFree: free / sum,
            rawUnknown: unknown / sum
        )
    }
    
    /// Vacuous mass: (0, 0, 1) - complete uncertainty
    /// Note: Uses internal initializer to avoid recursion in normalized()
    public static let vacuous = DSMassFunction(
        rawOccupied: 0.0,
        rawFree: 0.0,
        rawUnknown: 1.0
    )
    
    /// Verify invariant: occupied + free + unknown ≈ 1.0
    public func verifyInvariant() -> Bool {
        let sum = occupied + free + unknown
        return abs(sum - 1.0) < EvidenceConstants.dsEpsilon
    }
}

/// **Rule ID:** PR6_GRID_MASS_003
/// Dempster-Shafer Mass Fusion
/// Implements D-S combination rules with conflict handling
public enum DSMassFusion {
    
    /// **Rule ID:** PR6_GRID_MASS_004
    /// Dempster's combination rule
    ///
    /// Computes: m_combined(A) = (1 / (1 - K)) * Σ(m1(B) * m2(C))
    /// where B ∩ C = A and K is the conflict
    ///
    /// - Parameters:
    ///   - m1: First mass function
    ///   - m2: Second mass function
    /// - Returns: Combined mass function and conflict K
    public static func dempsterCombine(_ m1: DSMassFunction, _ m2: DSMassFunction) -> (mass: DSMassFunction, conflict: Double) {
        guard let native = DSMassNativeBridge.dempsterCombine(m1, m2) else {
            return (mass: .vacuous, conflict: 0.0)
        }
        return (mass: native.mass, conflict: native.conflict)
    }
    
    /// **Rule ID:** PR6_GRID_MASS_005
    /// Yager's combination rule (fallback for high conflict)
    ///
    /// When conflict K is high, Yager moves conflict mass to unknown
    /// instead of normalizing, which prevents numerical explosion
    ///
    /// - Parameters:
    ///   - m1: First mass function
    ///   - m2: Second mass function
    /// - Returns: Combined mass function
    public static func yagerCombine(_ m1: DSMassFunction, _ m2: DSMassFunction) -> DSMassFunction {
        DSMassNativeBridge.yagerCombine(m1, m2) ?? .vacuous
    }
    
    /// **Rule ID:** PR6_GRID_MASS_006
    /// Combine two mass functions with conflict threshold switching
    ///
    /// Uses Dempster's rule if conflict K < threshold, otherwise Yager's rule
    ///
    /// - Parameters:
    ///   - m1: First mass function
    ///   - m2: Second mass function
    /// - Returns: Combined mass function
    public static func combine(_ m1: DSMassFunction, _ m2: DSMassFunction) -> DSMassFunction {
        DSMassNativeBridge.combine(m1, m2) ?? .vacuous
    }
    
    /// **Rule ID:** PR6_GRID_MASS_008
    /// Reliability discounting (MUST-FIX G)
    ///
    /// Applies reliability coefficient r ∈ [0,1] to discount mass
    /// Formula: m_discounted(A) = r * m(A), m_discounted(unknown) = m(unknown) + (1-r) * (m(occupied) + m(free))
    ///
    /// - Parameters:
    ///   - mass: Mass function to discount
    ///   - reliability: Reliability coefficient r ∈ [0,1]
    /// - Returns: Discounted mass function
    public static func discount(mass: DSMassFunction, reliability: Double) -> DSMassFunction {
        DSMassNativeBridge.discount(mass, reliability: reliability) ?? .vacuous
    }
    
    /// **Rule ID:** PR6_GRID_MASS_009
    /// Create mass function from ObservationVerdict.deltaMultiplier
    ///
    /// Mapping:
    /// - good(1.0) → m(O)=0.8, m(F)=0.0, m(U)=0.2
    /// - suspect(0.3) → m(O)=0.3, m(F)=0.0, m(U)=0.7
    /// - bad(0.0) → m(O)=0.0, m(F)=0.3, m(U)=0.7
    ///
    /// - Parameter deltaMultiplier: Delta multiplier from ObservationVerdict
    /// - Returns: Mass function
    public static func fromDeltaMultiplier(_ deltaMultiplier: Double) -> DSMassFunction {
        DSMassNativeBridge.fromDeltaMultiplier(deltaMultiplier) ?? .vacuous
    }
}

// MARK: - Numerical Sealing (MUST-FIX X)

extension DSMassFunction {
    /// **Rule ID:** PR6_GRID_MASS_010
    /// Numerical sealing: guard against NaN/Inf and enforce invariants
    ///
    /// After every mass operation:
    /// 1. Guard isFinite else fallback to unknown=1.0
    /// 2. Clamp to [0,1]
    /// 3. Deterministic renormalization to sum-to-1
    ///
    /// - Returns: Sealed mass function
    func sealed() -> DSMassFunction {
        DSMassNativeBridge.sealed(self) ?? .vacuous
    }
}
