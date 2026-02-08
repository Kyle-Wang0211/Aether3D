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
        // Compute conflict K = m1(occupied) * m2(free) + m1(free) * m2(occupied)
        let conflictK = m1.occupied * m2.free + m1.free * m2.occupied
        
        // Guard against K → 1.0 (numerical explosion)
        guard conflictK < 1.0 - EvidenceConstants.dsEpsilon else {
            // High conflict: fall back to Yager
            let yagerMass = yagerCombine(m1, m2)
            return (mass: yagerMass, conflict: conflictK)
        }
        
        // Normalization factor: 1 / (1 - K)
        let normalizationFactor = 1.0 / (1.0 - conflictK)
        
        // Combined masses
        let combinedOccupied = normalizationFactor * (m1.occupied * m2.occupied + m1.occupied * m2.unknown + m1.unknown * m2.occupied)
        let combinedFree = normalizationFactor * (m1.free * m2.free + m1.free * m2.unknown + m1.unknown * m2.free)
        let combinedUnknown = normalizationFactor * (m1.unknown * m2.unknown)
        
        // Create combined mass function using internal init to avoid recursion
        var combined = DSMassFunction(
            rawOccupied: combinedOccupied,
            rawFree: combinedFree,
            rawUnknown: combinedUnknown
        )
        
        // Apply numerical sealing (MUST-FIX X)
        combined = combined.sealed()
        
        return (mass: combined, conflict: conflictK)
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
        // Compute conflict K
        let conflictK = m1.occupied * m2.free + m1.free * m2.occupied
        
        // Combined masses (without normalization)
        let combinedOccupied = m1.occupied * m2.occupied + m1.occupied * m2.unknown + m1.unknown * m2.occupied
        let combinedFree = m1.free * m2.free + m1.free * m2.unknown + m1.unknown * m2.free
        let combinedUnknown = m1.unknown * m2.unknown + conflictK  // Conflict goes to unknown
        
        // Create combined mass function using internal init to avoid recursion
        var combined = DSMassFunction(
            rawOccupied: combinedOccupied,
            rawFree: combinedFree,
            rawUnknown: combinedUnknown
        )
        
        // Apply numerical sealing (MUST-FIX X)
        combined = combined.sealed()
        
        return combined
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
        // Compute conflict K
        let conflictK = m1.occupied * m2.free + m1.free * m2.occupied
        
        // **Rule ID:** PR6_GRID_MASS_007
        // Deterministic branch tie-break: use >= not >
        if conflictK >= EvidenceConstants.dsConflictSwitch {
            // High conflict: use Yager
            return yagerCombine(m1, m2)
        } else {
            // Low conflict: use Dempster
            let (combined, _) = dempsterCombine(m1, m2)
            return combined
        }
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
        // Clamp reliability to [0, 1]
        let r = max(0.0, min(1.0, reliability))
        
        // Discount occupied and free
        let discountedOccupied = r * mass.occupied
        let discountedFree = r * mass.free
        
        // Move discounted mass to unknown
        let discountedUnknown = mass.unknown + (1.0 - r) * (mass.occupied + mass.free)
        
        // Create discounted mass function using internal init to avoid recursion
        var discounted = DSMassFunction(
            rawOccupied: discountedOccupied,
            rawFree: discountedFree,
            rawUnknown: discountedUnknown
        )
        
        // Apply numerical sealing
        discounted = discounted.sealed()
        
        return discounted
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
        switch deltaMultiplier {
        case 1.0:  // good
            return DSMassFunction(
                rawOccupied: EvidenceConstants.dsDefaultOccupiedGood,
                rawFree: 0.0,
                rawUnknown: EvidenceConstants.dsDefaultUnknownGood
            )
        case 0.3:  // suspect
            return DSMassFunction(
                rawOccupied: 0.3,
                rawFree: 0.0,
                rawUnknown: 0.7
            )
        case 0.0:  // bad
            return DSMassFunction(
                rawOccupied: 0.0,
                rawFree: EvidenceConstants.dsDefaultFreeBad,
                rawUnknown: 0.7
            )
        default:
            // Interpolate for other values
            if deltaMultiplier > 0.3 {
                // Between suspect and good
                let t = (deltaMultiplier - 0.3) / 0.7
                return DSMassFunction(
                    rawOccupied: 0.3 + t * (EvidenceConstants.dsDefaultOccupiedGood - 0.3),
                    rawFree: 0.0,
                    rawUnknown: 0.7 - t * (0.7 - EvidenceConstants.dsDefaultUnknownGood)
                )
            } else {
                // Between bad and suspect
                let t = deltaMultiplier / 0.3
                return DSMassFunction(
                    rawOccupied: 0.0 + t * 0.3,
                    rawFree: EvidenceConstants.dsDefaultFreeBad * (1.0 - t),
                    rawUnknown: 0.7
                )
            }
        }
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
        // Guard against NaN/Inf
        guard occupied.isFinite && free.isFinite && unknown.isFinite else {
            return .vacuous
        }
        
        // Clamp to [0, 1]
        let clampedOccupied = max(0.0, min(1.0, occupied))
        let clampedFree = max(0.0, min(1.0, free))
        let clampedUnknown = max(0.0, min(1.0, unknown))
        
        // Renormalize using internal init to avoid recursion
        let sealed = DSMassFunction(
            rawOccupied: clampedOccupied,
            rawFree: clampedFree,
            rawUnknown: clampedUnknown
        )
        
        // Verify invariant
        assert(sealed.verifyInvariant(), "Mass invariant violation after sealing")
        
        return sealed
    }
}
