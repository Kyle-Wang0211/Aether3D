// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GateQualityComputer.swift
// Aether3D
//
// PR3 - Gate Quality Computer
// Integration layer: combines all components to compute gateQuality
//

import Foundation

/// Gate Quality Computer: Integration layer
///
/// DESIGN:
/// - Owns GateCoverageTracker
/// - Uses SmartAntiBoostSmoother for metric smoothing
/// - Uses GateInputValidator for input validation
/// - Computes gateQuality in 4 steps
/// - Uses TierContext for performance mode
public final class GateQualityComputer: @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Components
    // ═══════════════════════════════════════════════════════════════════════

    /// Gate coverage tracker
    private let coverageTracker: GateCoverageTracker

    /// Metric smoothers (for jitter reduction)
    private let reprojSmoother: SmartAntiBoostSmoother
    private let edgeSmoother: SmartAntiBoostSmoother
    private let sharpnessSmoother: SmartAntiBoostSmoother

    /// Tier context (determines math backend)
    private let tierContext: TierContext

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    /// Initialize gate quality computer
    ///
    /// - Parameters:
    ///   - tierContext: Tier context (default: canonical for testing)
    ///   - smootherConfig: Smoother configuration (default if not specified)
    public init(
        tierContext: TierContext = .forTesting,
        smootherConfig: SmootherConfig = .default
    ) {
        self.tierContext = tierContext
        self.coverageTracker = GateCoverageTracker()
        self.reprojSmoother = SmartAntiBoostSmoother(config: smootherConfig)
        self.edgeSmoother = SmartAntiBoostSmoother(config: smootherConfig)
        self.sharpnessSmoother = SmartAntiBoostSmoother(config: smootherConfig)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Computation
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute gate quality for a frame observation
    ///
    /// STEPS:
    /// 1. Validate inputs (GateInputValidator)
    /// 2. Smooth raw metrics (SmartAntiBoostSmoother)
    /// 3. Record observation and get view gain inputs (GateCoverageTracker)
    /// 4. Compute final gateQuality (GateGainFunctions)
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - direction: Normalized direction vector (from camera to patch)
    ///   - reprojRmsPx: Reprojection RMS error (pixels)
    ///   - edgeRmsPx: Edge reprojection RMS error (pixels)
    ///   - sharpness: Sharpness score (0-100)
    ///   - overexposureRatio: Overexposed pixel ratio (0-1)
    ///   - underexposureRatio: Underexposed pixel ratio (0-1)
    ///   - frameIndex: Frame index (for deterministic eviction)
    /// - Returns: Gate quality ∈ [0, 1]
    public func computeGateQuality(
        patchId: String,
        direction: EvidenceVector3,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double,
        frameIndex: Int
    ) -> Double {
        // Step 1: Validate inputs
        let validationResult = GateInputValidator.validate(
            thetaSpanDeg: 0,  // Will be computed from tracker
            phiSpanDeg: 0,    // Will be computed from tracker
            l2PlusCount: 0,   // Will be computed from tracker
            l3Count: 0,       // Will be computed from tracker
            reprojRmsPx: reprojRmsPx,
            edgeRmsPx: edgeRmsPx,
            sharpness: sharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio
        )

        // If invalid, return fallback quality
        if case .invalid(let reason, let fallbackQuality) = validationResult {
            #if DEBUG
            print("[GateQualityComputer] Invalid input: \(reason), using fallback: \(fallbackQuality)")
            #endif
            return fallbackQuality
        }

        // Step 2: Smooth raw metrics
        let smoothedReproj = reprojSmoother.addAndSmooth(reprojRmsPx)
        let smoothedEdge = edgeSmoother.addAndSmooth(edgeRmsPx)
        let smoothedSharpness = sharpnessSmoother.addAndSmooth(sharpness)

        // Step 3: Compute preliminary quality for L2+/L3 classification
        let prelimBasic = GateGainFunctions.basicGateGain(
            sharpness: smoothedSharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio,
            context: tierContext
        )

        let prelimGeom = GateGainFunctions.geomGateGain(
            reprojRmsPx: smoothedReproj,
            edgeRmsPx: smoothedEdge,
            context: tierContext
        )

        // PR3 internal quality for L2+/L3 classification
        let pr3Quality = PR3InternalQuality.compute(
            basicGain: prelimBasic,
            geomGain: prelimGeom
        )

        // Record observation in coverage tracker
        coverageTracker.recordObservation(
            patchId: patchId,
            direction: direction,
            pr3Quality: pr3Quality,
            frameIndex: frameIndex
        )

        // Step 4: Get view gain inputs from tracker
        let (thetaSpanDeg, phiSpanDeg, l2PlusCount, l3Count) = coverageTracker.viewGainInputs(for: patchId)

        // Step 5: Compute final gate quality
        let viewGain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: thetaSpanDeg,
            phiSpanDeg: phiSpanDeg,
            l2PlusCount: l2PlusCount,
            l3Count: l3Count,
            context: tierContext
        )

        let geomGain = GateGainFunctions.geomGateGain(
            reprojRmsPx: smoothedReproj,
            edgeRmsPx: smoothedEdge,
            context: tierContext
        )

        let basicGain = GateGainFunctions.basicGateGain(
            sharpness: smoothedSharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio,
            context: tierContext
        )

        let gateQuality = GateGainFunctions.gateQuality(
            viewGain: viewGain,
            geomGain: geomGain,
            basicGain: basicGain
        )

        // Validate output (DEBUG only)
        #if DEBUG
        GateInvariants.validateGateQuality01(gateQuality)
        #endif

        return gateQuality
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    /// Reset for new session
    public func reset() {
        coverageTracker.resetAll()
        reprojSmoother.reset()
        edgeSmoother.reset()
        sharpnessSmoother.reset()
    }

    /// Reset tracking for a specific patch
    ///
    /// - Parameter patchId: Patch identifier
    public func reset(patchId: String) {
        coverageTracker.reset(patchId: patchId)
    }
}
