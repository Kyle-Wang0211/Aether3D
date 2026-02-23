// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GateGainFunctions.swift
// Aether3D
//
// PR3 - Gate Gain Functions
// Compute gateQuality from view, geometry, and basic quality metrics
//

import Foundation

/// Gate gain function implementations
///
/// DESIGN:
/// - All math operations use PRMath facade (canonical path only)
/// - @inlinable for hot path optimization
/// - Uses HardGatesV13 thresholds with TransitionWidth
public enum GateGainFunctions {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gate Weights (SSOT)
    // ═══════════════════════════════════════════════════════════════════════

    /// Gate gain internal weights (SSOT)
    /// These weights determine the contribution of each gain component
    public enum GateWeights {
        /// View gain weight (angular coverage)
        /// VALUE: 0.40 (40% of total gate quality)
        public static let viewWeight: Double = 0.40

        /// Geometry gain weight (reprojection accuracy)
        /// VALUE: 0.45 (45% of total gate quality)
        public static let geomWeight: Double = 0.45

        /// Basic gain weight (sharpness, exposure)
        /// VALUE: 0.15 (15% of total gate quality)
        public static let basicWeight: Double = 0.15

        /// Validation: weights must sum to 1.0
        public static func validate() -> Bool {
            let sum = viewWeight + geomWeight + basicWeight
            return abs(sum - 1.0) < 1e-9
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - View Gate Gain
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute view gate gain based on angular coverage
    ///
    /// FORMULA:
    /// viewGateGain = sigmoid((thetaSpan - threshold) / slope)
    ///              × sigmoid((phiSpan - threshold) / slope)
    ///              × sigmoid((l2PlusCount - threshold) / slope)
    ///              × sigmoid((l3Count - threshold) / slope)
    ///
    /// Then apply minimum: max(minViewGain, combined)
    ///
    /// - Parameters:
    ///   - thetaSpanDeg: Horizontal angular span in degrees
    ///   - phiSpanDeg: Vertical angular span in degrees
    ///   - l2PlusCount: Number of L2+ quality observations
    ///   - l3Count: Number of L3 quality observations
    ///   - context: Tier context (default: canonical)
    /// - Returns: View gain ∈ [minViewGain, 1]
    @inlinable
    public static func viewGateGain(
        thetaSpanDeg: Double,
        phiSpanDeg: Double,
        l2PlusCount: Int,
        l3Count: Int,
        context: TierContext = .forTesting
    ) -> Double {
        // Handle non-finite inputs
        guard thetaSpanDeg.isFinite && phiSpanDeg.isFinite else {
            return HardGatesV13.minViewGain
        }

        // Compute sigmoid gains for each component
        let thetaGain = PRMath.sigmoid01FromThreshold(
            thetaSpanDeg,
            threshold: HardGatesV13.thetaThreshold,
            transitionWidth: HardGatesV13.thetaTransitionWidth,
            context: context
        )

        let phiGain = PRMath.sigmoid01FromThreshold(
            phiSpanDeg,
            threshold: HardGatesV13.phiThreshold,
            transitionWidth: HardGatesV13.phiTransitionWidth,
            context: context
        )

        let l2PlusGain = PRMath.sigmoid01FromThreshold(
            Double(l2PlusCount),
            threshold: HardGatesV13.l2PlusThreshold,
            transitionWidth: HardGatesV13.l2PlusTransitionWidth,
            context: context
        )

        let l3Gain = PRMath.sigmoid01FromThreshold(
            Double(l3Count),
            threshold: HardGatesV13.l3Threshold,
            transitionWidth: HardGatesV13.l3TransitionWidth,
            context: context
        )

        // Combine components (product)
        let combined = thetaGain * phiGain * l2PlusGain * l3Gain

        // Apply minimum floor
        return max(HardGatesV13.minViewGain, combined)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Geometry Gate Gain
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute geometry gate gain based on reprojection accuracy
    ///
    /// FORMULA:
    /// geomGateGain = sigmoid((threshold - reprojRms) / slope)
    ///              × sigmoid((threshold - edgeRms) / slope)
    ///
    /// NOTE: Inverted sigmoid (lower is better)
    /// NO FLOOR - cliff is real (can be 0.0)
    ///
    /// - Parameters:
    ///   - reprojRmsPx: Reprojection RMS error in pixels
    ///   - edgeRmsPx: Edge reprojection RMS error in pixels
    ///   - context: Tier context (default: canonical)
    /// - Returns: Geometry gain ∈ [0, 1]
    @inlinable
    public static func geomGateGain(
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        context: TierContext = .forTesting
    ) -> Double {
        // Handle non-finite inputs
        guard reprojRmsPx.isFinite && edgeRmsPx.isFinite else {
            return HardGatesV13.minGeomGain
        }

        // Clamp to reasonable maximum to avoid NaN
        let clampedReproj = min(reprojRmsPx, 10.0)
        let clampedEdge = min(edgeRmsPx, 10.0)

        // Inverted sigmoid (lower is better)
        let reprojGain = PRMath.sigmoidInverted01FromThreshold(
            clampedReproj,
            threshold: HardGatesV13.reprojThreshold,
            transitionWidth: HardGatesV13.reprojTransitionWidth,
            context: context
        )

        let edgeGain = PRMath.sigmoidInverted01FromThreshold(
            clampedEdge,
            threshold: HardGatesV13.edgeThreshold,
            transitionWidth: HardGatesV13.edgeTransitionWidth,
            context: context
        )

        // Combine components (product)
        return reprojGain * edgeGain
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Basic Gate Gain
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute basic gate gain based on image quality
    ///
    /// FORMULA:
    /// basicGateGain = sigmoid((sharpness - threshold) / slope)
    ///              × sigmoid((threshold - overexposureRatio) / slope)
    ///              × sigmoid((threshold - underexposureRatio) / slope)
    ///
    /// Then apply minimum: max(minBasicGain, combined)
    ///
    /// - Parameters:
    ///   - sharpness: Sharpness score (0-100)
    ///   - overexposureRatio: Overexposure ratio [0, 1]
    ///   - underexposureRatio: Underexposure ratio [0, 1]
    ///   - context: Tier context (default: canonical)
    /// - Returns: Basic gain ∈ [minBasicGain, 1]
    @inlinable
    public static func basicGateGain(
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double,
        context: TierContext = .forTesting
    ) -> Double {
        // Handle non-finite inputs
        guard sharpness.isFinite && overexposureRatio.isFinite && underexposureRatio.isFinite else {
            return HardGatesV13.minBasicGain
        }

        // Compute sigmoid gains
        let sharpnessGain = PRMath.sigmoid01FromThreshold(
            sharpness,
            threshold: HardGatesV13.sharpnessThreshold,
            transitionWidth: HardGatesV13.sharpnessTransitionWidth,
            context: context
        )

        // Inverted sigmoid for exposure ratios (lower is better)
        let overexposureGain = PRMath.sigmoidInverted01FromThreshold(
            overexposureRatio,
            threshold: HardGatesV13.overexposureThreshold,
            transitionWidth: HardGatesV13.overexposureTransitionWidth,
            context: context
        )

        let underexposureGain = PRMath.sigmoidInverted01FromThreshold(
            underexposureRatio,
            threshold: HardGatesV13.underexposureThreshold,
            transitionWidth: HardGatesV13.underexposureTransitionWidth,
            context: context
        )

        // Combine components (product)
        let combined = sharpnessGain * overexposureGain * underexposureGain

        // Apply minimum floor
        return max(HardGatesV13.minBasicGain, combined)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gate Quality (Final Combination)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute final gate quality from component gains
    ///
    /// FORMULA:
    /// gateQuality = viewWeight * viewGain
    ///            + geomWeight * geomGain
    ///            + basicWeight * basicGain
    ///
    /// - Parameters:
    ///   - viewGain: View coverage gain
    ///   - geomGain: Geometry accuracy gain
    ///   - basicGain: Basic image quality gain
    /// - Returns: Gate quality ∈ [0, 1]
    @inlinable
    public static func gateQuality(
        viewGain: Double,
        geomGain: Double,
        basicGain: Double
    ) -> Double {
        // Validate weights sum to 1.0 (DEBUG only)
        #if DEBUG
        assert(GateWeights.validate(), "Gate weights must sum to 1.0")
        #endif

        // Weighted combination
        let quality = GateWeights.viewWeight * viewGain
                    + GateWeights.geomWeight * geomGain
                    + GateWeights.basicWeight * basicGain

        // Clamp to [0, 1]
        return PRMath.clamp01(quality)
    }
}
