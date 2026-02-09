// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceInvariants.swift
// Aether3D
//
// PR2 Patch V4 - Evidence System Invariants
// Code-enforced non-negotiable invariants
//

import Foundation

/// Evidence system invariants (non-negotiable)
///
/// These invariants MUST hold at all times.
/// Violations indicate a critical bug.
public enum EvidenceInvariants {
    
    // MARK: - Display Invariants
    
    /// INVARIANT: Display evidence NEVER decreases per patch
    /// 
    /// VERIFICATION: PatchDisplayMap.update() enforces max(prev, computed)
    public static func assertDisplayMonotonic(
        previous: Double,
        current: Double,
        patchId: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        if current < previous {
            fatalError(
                "INVARIANT VIOLATION: Display decreased for patch \(patchId): \(previous) -> \(current) " +
                "(\(file):\(line))"
            )
        }
        #endif
    }
    
    // MARK: - Ledger Invariants
    
    /// INVARIANT: Ledger evidence ∈ [0, 1]
    ///
    /// VERIFICATION: @ClampedEvidence enforces bounds
    public static func assertLedgerBounds(
        evidence: Double,
        patchId: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        if evidence < 0.0 || evidence > 1.0 {
            fatalError(
                "INVARIANT VIOLATION: Ledger evidence out of bounds for patch \(patchId): \(evidence) " +
                "(\(file):\(line))"
            )
        }
        #endif
    }
    
    // MARK: - Decay Invariants
    
    /// INVARIANT: ConfidenceDecay NEVER mutates stored evidence
    ///
    /// VERIFICATION: Decay only affects aggregation weight, not PatchEntry.evidence
    public static func assertDecayDoesNotMutateEvidence(
        before: Double,
        after: Double,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        if abs(before - after) > 1e-9 {
            fatalError(
                "INVARIANT VIOLATION: Decay mutated stored evidence: \(before) -> \(after) " +
                "(\(file):\(line))"
            )
        }
        #endif
    }
    
    // MARK: - Admission Invariants
    
    /// INVARIANT: UnifiedAdmissionController is the ONLY throughput gate
    ///
    /// VERIFICATION: No other component should hard-block observations
    public static func assertOnlyAdmissionControllerBlocks(
        blockedBy: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        let allowedBlockers = ["UnifiedAdmissionController", "SpamProtection.shouldAllowUpdate"]
        if !allowedBlockers.contains(where: { blockedBy.contains($0) }) {
            EvidenceLogger.warn(
                "Potential invariant violation: Blocking by \(blockedBy) " +
                "(only UnifiedAdmissionController should hard-block)"
            )
        }
        #endif
    }
    
    // MARK: - Throughput Invariants
    
    /// INVARIANT: Minimum throughput guarantee (25%)
    ///
    /// VERIFICATION: UnifiedAdmissionController enforces minimumSoftScale
    public static func assertMinimumThroughput(
        qualityScale: Double,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        if qualityScale < EvidenceConstants.minimumSoftScale {
            fatalError(
                "INVARIANT VIOLATION: Quality scale below minimum: \(qualityScale) < \(EvidenceConstants.minimumSoftScale) " +
                "(\(file):\(line))"
            )
        }
        #endif
    }
    
    // MARK: - Delta Invariants
    
    /// INVARIANT: Delta computed BEFORE display update (Rule D)
    ///
    /// VERIFICATION: IsolatedEvidenceEngine computes delta from prevDisplay
    public static func assertDeltaComputedBeforeUpdate(
        delta: Double,
        prevDisplay: Double,
        newDisplay: Double,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        let expectedDelta = newDisplay - prevDisplay
        if abs(delta - expectedDelta) > 0.01 {
            EvidenceLogger.warn(
                "Potential invariant violation: Delta mismatch. Expected \(expectedDelta), got \(delta) " +
                "(\(file):\(line))"
            )
        }
        #endif
    }
    
    // MARK: - Determinism Invariants
    
    /// INVARIANT: Deterministic JSON encoding
    ///
    /// VERIFICATION: TrueDeterministicJSONEncoder produces byte-identical output
    public static func assertDeterministicEncoding(
        first: Data,
        second: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        if first != second {
            fatalError(
                "INVARIANT VIOLATION: Non-deterministic encoding detected " +
                "(\(file):\(line))"
            )
        }
        #endif
    }
    
    // MARK: - PR6 Grid Invariants
    
    /// **Rule ID:** PR6_GRID_MASS_001
    /// D-S mass invariant: occupied + free + unknown = 1.0
    public static func assertGridMassInvariant(_ mass: DSMassFunction) {
        #if DEBUG
        let sum = mass.occupied + mass.free + mass.unknown
        assert(abs(sum - 1.0) < EvidenceConstants.dsEpsilon,
               "Grid mass invariant violated: sum=\(sum), expected 1.0")
        #endif
    }
    
    /// **Rule ID:** PR6_GRID_MONOTONIC_001
    /// State machine monotonicity: current >= previous
    public static func assertGridStateMonotonic(current: ColorState, previous: ColorState) {
        #if DEBUG
        // State order: black=0, darkGray=1, lightGray=2, white=3, original=4
        let currentOrder: Int
        switch current {
        case .black: currentOrder = 0
        case .darkGray: currentOrder = 1
        case .lightGray: currentOrder = 2
        case .white: currentOrder = 3
        case .original: currentOrder = 4
        case .unknown: currentOrder = -1
        }
        
        let previousOrder: Int
        switch previous {
        case .black: previousOrder = 0
        case .darkGray: previousOrder = 1
        case .lightGray: previousOrder = 2
        case .white: previousOrder = 3
        case .original: previousOrder = 4
        case .unknown: previousOrder = -1
        }
        
        assert(currentOrder >= previousOrder,
               "Grid state monotonicity violated: \(previous) -> \(current)")
        #endif
    }
    
    /// **Rule ID:** PR6_GRID_BALANCE_001
    /// Refinement balance: 2:1 ratio for neighboring cell levels
    public static func assertRefinementBalance(grid: EvidenceGrid) async {
        #if DEBUG
        // Simplified check: verify grid is in valid state
        // Full implementation would check 2:1 balance rule for neighboring cells
        let cells = await grid.allActiveCells()
        for cell in cells {
            // Verify cell level is valid
            assert(cell.level.rawValue >= 0 && cell.level.rawValue <= 6,
                   "Invalid cell level: \(cell.level.rawValue)")
        }
        #endif
    }
}
