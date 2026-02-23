// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceStateMachine.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence State Machine
// S0-S5 state transitions mapping to ColorState
//
// Implementation delegated to C++ core layer via C API.
// S5 uses 6-gate information-theoretic certification:
//   1. DS Belief coverage >= 0.88
//   2. Choquet integral >= 0.72 (non-additive 5 super-dim)
//   3. Min super-dimension >= 0.45
//   4. DS uncertainty width <= 0.15
//   5. L5+ observation ratio >= 0.30 (CRLB proxy)
//   6. Lyapunov rate <= 0.05 (convergence certificate)
//

import Foundation
import CAetherNativeBridge

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

    // ── Information-theoretic extensions (from C++ CoverageEstimator) ──

    /// DS Belief coverage lower bound [0,1]
    public let beliefCoverage: Double

    /// DS Plausibility coverage upper bound [0,1]
    public let plausibilityCoverage: Double

    /// DS uncertainty width: Pl - Bel
    public let uncertaintyWidth: Double

    /// L5+ observation ratio (CRLB precision proxy)
    public let highObservationRatio: Double

    /// Lyapunov convergence rate: |dV/dt|/V
    public let lyapunovRate: Double

    /// Mean Fisher information across active cells
    public let meanFisherInfo: Double

    public init(
        coveragePercentage: Double,
        breakdownCounts: [Int],
        weightedSumComponents: [Double],
        excludedAreaSqM: Double,
        beliefCoverage: Double = 0.0,
        plausibilityCoverage: Double = 0.0,
        uncertaintyWidth: Double = 0.0,
        highObservationRatio: Double = 0.0,
        lyapunovRate: Double = 1.0,
        meanFisherInfo: Double = 0.0
    ) {
        self.coveragePercentage = coveragePercentage
        self.breakdownCounts = breakdownCounts
        self.weightedSumComponents = weightedSumComponents
        self.excludedAreaSqM = excludedAreaSqM
        self.beliefCoverage = beliefCoverage
        self.plausibilityCoverage = plausibilityCoverage
        self.uncertaintyWidth = uncertaintyWidth
        self.highObservationRatio = highObservationRatio
        self.lyapunovRate = lyapunovRate
        self.meanFisherInfo = meanFisherInfo
    }
}

/// **Rule ID:** PR6_GRID_STATE_002
/// Evidence State Machine: S0-S5 transitions
/// Monotonic: state never decreases (S0 → S1 → S2 → S3 → S4 → S5)
///
/// Core logic delegated to C++ `aether::evidence::EvidenceStateMachine`.
public final class EvidenceStateMachine: @unchecked Sendable {

    /// Opaque pointer to C++ implementation
    private var nativeHandle: OpaquePointer?

    public init() {
        var handle: OpaquePointer?
        let rc = aether_evidence_state_machine_create(nil, &handle)
        if rc == 0 {
            nativeHandle = handle
        }
    }

    deinit {
        if let handle = nativeHandle {
            aether_evidence_state_machine_destroy(handle)
        }
    }

    /// **Rule ID:** PR6_GRID_STATE_003
    /// Evaluate state transition based on coverage, evidence, and dimensional scores.
    ///
    /// Swift is a pure passthrough — ALL computation happens in C++ core:
    ///   - Fisher-weighted coverage → belief_coverage / plausibility_coverage
    ///   - 10 dim_scores → Choquet integral (5 super-dimensions)
    ///   - Lyapunov rate, L5+ ratio, DS uncertainty width
    ///
    /// - Parameters:
    ///   - coverage: Coverage result from CoverageEstimator (includes info-theoretic fields)
    ///   - pizRegions: PIZ regions (for exclusion consideration)
    ///   - evidenceSnapshot: Evidence snapshot from engine
    ///   - dimensionalScores: 10-dimensional scores (transparent passthrough to C++)
    /// - Returns: New ColorState (monotonic, never decreases)
    public func evaluate(
        coverage: CoverageResult,
        pizRegions: [PIZRegion] = [],
        evidenceSnapshot: EvidenceState? = nil,
        dimensionalScores: DimensionalScoreSet? = nil
    ) -> ColorState {
        guard let handle = nativeHandle else {
            return .black
        }

        var input = aether_evidence_state_machine_input_t()

        // Core signals from CoverageEstimator (info-theoretic)
        // Backward compatibility: if beliefCoverage not set (0.0), fall back to coveragePercentage.
        // This ensures legacy callers that only set coveragePercentage still get correct S0-S4 behavior.
        let effectiveBelief = coverage.beliefCoverage > 0.0
            ? coverage.beliefCoverage
            : coverage.coveragePercentage
        input.coverage = effectiveBelief
        input.plausibility_coverage = coverage.plausibilityCoverage > 0.0
            ? coverage.plausibilityCoverage
            : effectiveBelief  // If no Pl data, assume tight interval (Pl ≈ Bel)
        input.uncertainty_width = coverage.uncertaintyWidth
        input.high_observation_ratio = coverage.highObservationRatio
        input.lyapunov_rate = coverage.lyapunovRate

        // Transparent passthrough of 10 dimensional scores (zero computation in Swift)
        if let dims = dimensionalScores {
            input.dim_scores.0 = dims.dim1_viewGain
            input.dim_scores.1 = dims.dim2_geometryGain
            input.dim_scores.2 = dims.dim3_depthQuality
            input.dim_scores.3 = dims.dim4_semanticConsistency
            input.dim_scores.4 = dims.dim5_errorTypeScore
            input.dim_scores.5 = dims.dim6_basicGain
            input.dim_scores.6 = dims.dim7_provenanceContribution
            input.dim_scores.7 = dims.dim8_coverageTrackerScore
            input.dim_scores.8 = dims.dim9_resolutionQuality
            input.dim_scores.9 = dims.dim10_viewDiversity
        }

        var result = aether_evidence_state_machine_result_t()
        let rc = aether_evidence_state_machine_evaluate(handle, &input, &result)
        if rc != 0 {
            return .black
        }

        return colorStateFromC(result.state)
    }

    /// Get current state
    public func getCurrentState() -> ColorState {
        guard let handle = nativeHandle else {
            return .black
        }
        var cState: Int32 = Int32(AETHER_COLOR_STATE_BLACK)
        let rc = aether_evidence_state_machine_current_state(handle, &cState)
        if rc != 0 {
            return .black
        }
        return colorStateFromC(cState)
    }

    /// Reset state machine
    public func reset() {
        guard let handle = nativeHandle else { return }
        aether_evidence_state_machine_reset(handle)
    }

    // MARK: - Private helpers

    private func colorStateFromC(_ cState: Int32) -> ColorState {
        switch cState {
        case Int32(AETHER_COLOR_STATE_BLACK):      return .black
        case Int32(AETHER_COLOR_STATE_DARK_GRAY):  return .darkGray
        case Int32(AETHER_COLOR_STATE_LIGHT_GRAY): return .lightGray
        case Int32(AETHER_COLOR_STATE_WHITE):       return .white
        case Int32(AETHER_COLOR_STATE_ORIGINAL):    return .original
        default:                                     return .unknown
        }
    }
}

// Note: PIZRegion is already defined in Core/PIZ/PIZRegion.swift
// PR6 uses the existing PIZRegion type, no need to redefine
