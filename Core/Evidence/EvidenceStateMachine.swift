// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceStateMachine.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence State Machine
// S0-S5 state transitions mapping to ColorState
//

import Foundation

/// **Rule ID:** PR6_GRID_STATE_001
/// Coverage result from CoverageEstimator
public struct CoverageResult: Sendable, Codable {
    /// Main coverage percentage [0, 1]
    public let coveragePercentage: Double
    
    /// Breakdown counts per level (L0..L6)
    public let breakdownCounts: [Int]
    
    /// Weighted sum components per level
    public let weightedSumComponents: [Double]
    
    /// Excluded area in square meters (from PIZ occlusion exclusion)
    public let excludedAreaSqM: Double
    
    public init(
        coveragePercentage: Double,
        breakdownCounts: [Int],
        weightedSumComponents: [Double],
        excludedAreaSqM: Double
    ) {
        self.coveragePercentage = coveragePercentage
        self.breakdownCounts = breakdownCounts
        self.weightedSumComponents = weightedSumComponents
        self.excludedAreaSqM = excludedAreaSqM
    }
}

/// **Rule ID:** PR6_GRID_STATE_002
/// Evidence State Machine: S0-S5 transitions
/// Monotonic: state never decreases (S0 → S1 → S2 → S3 → S4 → S5)
public final class EvidenceStateMachine: @unchecked Sendable {
    
    /// Current state (monotonic, never decreases)
    private var currentState: ColorState = .black
    
    /// Previous state (for monotonicity check)
    private var previousState: ColorState = .black
    
    /// S5 threshold constants
    private let whiteThreshold: Double = 0.88
    private let s5MinSoftEvidence: Double = 0.75
    
    public init() {}
    
    /// **Rule ID:** PR6_GRID_STATE_003
    /// Evaluate state transition based on coverage and evidence
    ///
    /// - Parameters:
    ///   - coverage: Coverage result from CoverageEstimator
    ///   - pizRegions: PIZ regions (for exclusion consideration, using existing PIZRegion from Core/PIZ)
    ///   - evidenceSnapshot: Evidence snapshot from engine
    /// - Returns: New ColorState (monotonic, never decreases)
    public func evaluate(
        coverage: CoverageResult,
        pizRegions: [PIZRegion] = [],
        evidenceSnapshot: EvidenceState? = nil
    ) -> ColorState {
        let newState = computeState(
            coverage: coverage,
            pizRegions: pizRegions,
            evidenceSnapshot: evidenceSnapshot
        )
        
        // **Rule ID:** PR6_GRID_STATE_004
        // Monotonic enforcement: state never decreases
        if stateOrder(newState) > stateOrder(currentState) {
            previousState = currentState
            currentState = newState
        }
        // If newState < currentState, keep currentState (monotonic)
        
        return currentState
    }
    
    /// Compute state from inputs (without monotonic enforcement)
    private func computeState(
        coverage: CoverageResult,
        pizRegions: [PIZRegion],
        evidenceSnapshot: EvidenceState?
    ) -> ColorState {
        let coverageValue = coverage.coveragePercentage
        
        // Get soft evidence from snapshot
        let softEvidence = evidenceSnapshot?.softDisplay ?? 0.0
        
        // **Rule ID:** PR6_GRID_STATE_005
        // S5 condition: whiteThreshold AND s5MinSoftEvidence
        if coverageValue >= whiteThreshold && softEvidence >= s5MinSoftEvidence {
            return .original  // S5
        }
        
        // S4: High coverage but not S5
        if coverageValue >= 0.75 {
            return .white  // S4
        }
        
        // S3: Medium-high coverage
        if coverageValue >= 0.50 {
            return .lightGray  // S3
        }
        
        // S2: Medium coverage
        if coverageValue >= 0.25 {
            return .darkGray  // S2
        }
        
        // S1: Low coverage
        if coverageValue >= 0.10 {
            return .darkGray  // S1 (same as S2 visually)
        }
        
        // S0: Very low or zero coverage
        return .black  // S0
    }
    
    /// Get state order for monotonic comparison
    private func stateOrder(_ state: ColorState) -> Int {
        switch state {
        case .black: return 0
        case .darkGray: return 1
        case .lightGray: return 2
        case .white: return 3
        case .original: return 4
        case .unknown: return -1  // Unknown is lowest
        }
    }
    
    /// Get current state
    public func getCurrentState() -> ColorState {
        return currentState
    }
    
    /// Reset state machine
    public func reset() {
        currentState = .black
        previousState = .black
    }
}

// Note: PIZRegion is already defined in Core/PIZ/PIZRegion.swift
// PR6 uses the existing PIZRegion type, no need to redefine
