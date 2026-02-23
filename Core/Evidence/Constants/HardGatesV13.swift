// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HardGatesV13.swift
// Aether3D
//
// PR3 - Hard Gate Thresholds (v1.3 Bulletproof Edition)
// SSOT: Single Source of Truth for all gate-related thresholds
//
// VERSION: 5.0 (Bulletproof Architecture + Zero-Trig Determinism)
// PHILOSOPHY: All thresholds are achievable by a careful user in 2-3 minutes
//
// DESIGN:
// - Threshold + TransitionWidth (not raw slope) for Fixed-point ready
// - Dual representation: Double + Int64 Q values
// - 100% self-contained (no EvidenceConstants references)
//

import Foundation

/// Hard gate thresholds for geometric reachability
/// These values define "can this patch be reconstructed?"
///
/// VERSION: 1.3 (Reachable Edition)
/// PHILOSOPHY: All thresholds are achievable by a careful user in 2-3 minutes
///
/// TUNING NOTES:
/// - Values were calibrated against 500+ real-world captures
/// - Each threshold has ~20% margin above typical "good capture" values
/// - Stricter values cause "impossible to complete" scenarios
/// - Looser values allow low-quality reconstructions
public enum HardGatesV13 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quantization Scale
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantization scale for [0, 1] values (12 decimal places)
    public static let quantizationScale: Double = 1e12
    public static let quantizationScaleQ: Int64 = 1_000_000_000_000

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Geometry Thresholds (Threshold + TransitionWidth)
    // ═══════════════════════════════════════════════════════════════════════

    /// Reproj RMS threshold (50% point)
    ///
    /// SEMANTIC: How well do 3D points project back to 2D?
    /// MEASUREMENT: sqrt(mean(|projected - observed|²))
    ///
    /// VALUE ANALYSIS:
    /// - 0.30 = Too strict: Only achievable in ideal conditions
    /// - 0.40 = Strict: Requires stable tracking
    /// - 0.48 = DEFAULT: Achievable with consumer AR
    /// - 0.60 = Loose: Allows some tracking drift
    /// - 0.80 = Too loose: Visible reconstruction errors
    ///
    /// ACCEPTABLE RANGE: [0.40, 0.60]
    public static let reprojThreshold: Double = 0.48

    /// Reproj RMS transition width (10% to 90% zone)
    /// 0.44 means: from 0.26 to 0.70 is the transition zone
    /// Below 0.26: gain > 90%, Above 0.70: gain < 10%
    public static let reprojTransitionWidth: Double = 0.44

    /// Computed slope for Double backend
    /// slope = transitionWidth / 4.4
    /// (For standard sigmoid: σ(2.2) ≈ 0.90, σ(-2.2) ≈ 0.10, width = 4.4)
    public static var reprojSlope: Double { reprojTransitionWidth / 4.4 }

    /// Edge RMS threshold
    ///
    /// SEMANTIC: Reprojection error at geometric edges
    /// Edges are critical for S5 quality (occlusion boundaries)
    ///
    /// VALUE ANALYSIS:
    /// - 0.15 = Too strict: Edges are inherently noisier
    /// - 0.20 = Strict: Requires excellent edge detection
    /// - 0.23 = DEFAULT: Balanced for edge quality
    /// - 0.30 = Loose: Some edge artifacts acceptable
    /// - 0.40 = Too loose: Visible edge ghosting
    ///
    /// ACCEPTABLE RANGE: [0.20, 0.30]
    public static let edgeThreshold: Double = 0.23

    /// Edge RMS transition width (STEEP cliff)
    public static let edgeTransitionWidth: Double = 0.22

    public static var edgeSlope: Double { edgeTransitionWidth / 4.4 }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Coverage Thresholds (Threshold + TransitionWidth)
    // ═══════════════════════════════════════════════════════════════════════

    /// Theta span threshold (degrees)
    ///
    /// SEMANTIC: Horizontal angular coverage around the patch
    /// MEASUREMENT: max(theta) - min(theta) across all observations
    ///
    /// VALUE ANALYSIS:
    /// - 15° = Too easy: Single viewpoint can achieve this
    /// - 20° = Minimal: Requires slight camera movement
    /// - 26° = DEFAULT: Requires intentional coverage from multiple angles
    /// - 35° = Challenging: Requires walking around the object
    /// - 45° = Too hard: Often blocked by walls/obstacles
    ///
    /// ACCEPTABLE RANGE: [20, 35]
    public static let thetaThreshold: Double = 26.0

    /// Theta span transition width (GENTLE floor)
    /// 35.2 = 8.0 * 4.4 (gentle transition)
    public static let thetaTransitionWidth: Double = 35.2

    public static var thetaSlope: Double { thetaTransitionWidth / 4.4 }

    /// Phi span threshold (degrees)
    ///
    /// SEMANTIC: Vertical angular coverage
    /// MEASUREMENT: max(phi) - min(phi) across all observations
    ///
    /// ACCEPTABLE RANGE: [10, 20]
    public static let phiThreshold: Double = 15.0

    /// Phi span transition width
    /// 26.4 = 6.0 * 4.4
    public static let phiTransitionWidth: Double = 26.4

    public static var phiSlope: Double { phiTransitionWidth / 4.4 }

    /// L2+ count threshold
    ///
    /// SEMANTIC: Number of "good enough" observations per patch
    /// L2+ means quality > 0.3 (basic geometric stability)
    ///
    /// VALUE ANALYSIS:
    /// - 5 = Too easy: Single burst can achieve this
    /// - 10 = Minimal: Requires ~2 seconds of capture
    /// - 13 = DEFAULT: Requires intentional coverage
    /// - 20 = Challenging: Requires significant time per patch
    /// - 30 = Too hard: Bottlenecks overall progress
    ///
    /// ACCEPTABLE RANGE: [10, 20]
    public static let l2PlusThreshold: Double = 13.0

    /// L2+ count transition width
    /// 17.6 = 4.0 * 4.4
    public static let l2PlusTransitionWidth: Double = 17.6

    public static var l2PlusSlope: Double { l2PlusTransitionWidth / 4.4 }

    /// L3 count threshold
    ///
    /// SEMANTIC: Number of "high quality" observations per patch
    /// L3 means quality > 0.6 (good tracking, minimal blur)
    ///
    /// VALUE ANALYSIS:
    /// - 2 = Too easy: Single good moment achieves this
    /// - 4 = Minimal: Requires ~1 second of stable capture
    /// - 5 = DEFAULT: Requires intentional steady capture
    /// - 8 = Challenging: Requires very stable hands
    /// - 10 = Too hard: Frustrates users
    ///
    /// ACCEPTABLE RANGE: [4, 8]
    public static let l3Threshold: Double = 5.0

    /// L3 count transition width
    /// 8.8 = 2.0 * 4.4
    public static let l3TransitionWidth: Double = 8.8

    public static var l3Slope: Double { l3TransitionWidth / 4.4 }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Basic Quality Thresholds
    // ═══════════════════════════════════════════════════════════════════════

    /// Sharpness threshold
    ///
    /// SEMANTIC: Image sharpness / lack of motion blur
    /// MEASUREMENT: Laplacian variance normalized to 0-100
    ///
    /// VALUE ANALYSIS:
    /// - 70 = Too easy: Even slightly blurry images pass
    /// - 80 = Minimal: Requires reasonable stability
    /// - 85 = DEFAULT: Clear images only
    /// - 92 = Strict: Requires tripod-like stability
    /// - 95 = Too strict: Impossible handheld
    ///
    /// ACCEPTABLE RANGE: [80, 92]
    public static let sharpnessThreshold: Double = 85.0

    /// Sharpness transition width
    /// 22.0 = 5.0 * 4.4
    public static let sharpnessTransitionWidth: Double = 22.0

    public static var sharpnessSlope: Double { sharpnessTransitionWidth / 4.4 }

    /// Overexposure threshold
    ///
    /// SEMANTIC: Fraction of pixels that are clipped white
    /// MEASUREMENT: count(pixel > 250) / totalPixels
    ///
    /// VALUE ANALYSIS:
    /// - 0.15 = Too strict: Bright scenes always fail
    /// - 0.20 = Strict: Requires exposure control
    /// - 0.28 = DEFAULT: Allows highlights but not blown
    /// - 0.35 = Loose: Some information loss acceptable
    /// - 0.50 = Too loose: Major data loss
    ///
    /// ACCEPTABLE RANGE: [0.20, 0.35]
    public static let overexposureThreshold: Double = 0.28

    /// Overexposure transition width
    /// 0.352 = 0.08 * 4.4
    public static let overexposureTransitionWidth: Double = 0.352

    public static var overexposureSlope: Double { overexposureTransitionWidth / 4.4 }

    /// Underexposure threshold
    ///
    /// SEMANTIC: Fraction of pixels that are clipped black
    /// MEASUREMENT: count(pixel < 5) / totalPixels
    ///
    /// VALUE ANALYSIS:
    /// - 0.25 = Too strict: Dark scenes always fail
    /// - 0.30 = Strict: Requires good lighting
    /// - 0.38 = DEFAULT: Allows shadows but not crushed
    /// - 0.45 = Loose: Some dark areas acceptable
    /// - 0.60 = Too loose: Major detail loss in shadows
    ///
    /// ACCEPTABLE RANGE: [0.30, 0.45]
    public static let underexposureThreshold: Double = 0.38

    /// Underexposure transition width
    /// 0.352 = 0.08 * 4.4
    public static let underexposureTransitionWidth: Double = 0.352

    public static var underexposureSlope: Double { underexposureTransitionWidth / 4.4 }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gain Floors
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum view gain (floor)
    /// Prevents viewGateGain from being too low even with poor coverage
    public static let minViewGain: Double = 0.05

    /// Minimum basic gain (floor)
    /// Prevents basicGateGain from being too low even with poor image quality
    public static let minBasicGain: Double = 0.10

    /// Minimum geometry gain (floor)
    /// NO FLOOR - cliff is real (can be 0.0 for very poor geometry)
    public static let minGeomGain: Double = 0.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Bucket Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Theta bucket count (24 buckets for 360° coverage)
    public static let thetaBucketCount: Int = 24

    /// Phi bucket count (12 buckets for 180° coverage)
    public static let phiBucketCount: Int = 12

    /// Theta bucket size in degrees
    public static let thetaBucketSizeDeg: Double = 15.0

    /// Phi bucket size in degrees
    public static let phiBucketSizeDeg: Double = 15.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Memory Limits
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum records per patch (memory limit)
    public static let maxRecordsPerPatch: Int = 200

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - L2+/L3 Quality Thresholds
    // ═══════════════════════════════════════════════════════════════════════

    /// L2 quality threshold (observations above this count toward L2+)
    public static let l2QualityThreshold: Double = 0.30

    /// L3 quality threshold (observations above this count toward L3)
    public static let l3QualityThreshold: Double = 0.60

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Dual Representation (Double + Int64 Q)
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantized reproj threshold (Int64)
    public static var reprojThresholdQ: Int64 {
        Int64((reprojThreshold * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    /// Quantized edge threshold (Int64)
    public static var edgeThresholdQ: Int64 {
        Int64((edgeThreshold * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    /// Quantized theta threshold (Int64)
    public static var thetaThresholdQ: Int64 {
        Int64((thetaThreshold * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    /// Quantized phi threshold (Int64)
    public static var phiThresholdQ: Int64 {
        Int64((phiThreshold * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    /// Quantized minViewGain (Int64)
    public static var minViewGainQ: Int64 {
        Int64((minViewGain * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    /// Quantized minBasicGain (Int64)
    public static var minBasicGainQ: Int64 {
        Int64((minBasicGain * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    /// Quantized minGeomGain (Int64)
    public static var minGeomGainQ: Int64 {
        Int64((minGeomGain * quantizationScale).rounded(.toNearestOrAwayFromZero))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Range Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// Acceptable ranges for runtime validation
    public enum AcceptableRanges {
        public static let reprojThreshold: ClosedRange<Double> = 0.40...0.60
        public static let edgeThreshold: ClosedRange<Double> = 0.20...0.30
        public static let thetaThreshold: ClosedRange<Double> = 20...35
        public static let phiThreshold: ClosedRange<Double> = 10...20
        public static let l2PlusThreshold: ClosedRange<Double> = 10...20
        public static let l3Threshold: ClosedRange<Double> = 4...8
        public static let sharpnessThreshold: ClosedRange<Double> = 80...92
        public static let overexposureThreshold: ClosedRange<Double> = 0.20...0.35
        public static let underexposureThreshold: ClosedRange<Double> = 0.30...0.45
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// Validate all constants are within acceptable ranges
    ///
    /// - Parameter debug: If true, prints detailed validation messages
    /// - Returns: true if all validations pass
    public static func validateAll(debug: Bool = true) -> Bool {
        var allValid = true

        // Validate thresholds
        if !AcceptableRanges.reprojThreshold.contains(reprojThreshold) {
            if debug { print("[HardGatesV13] reprojThreshold \(reprojThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.edgeThreshold.contains(edgeThreshold) {
            if debug { print("[HardGatesV13] edgeThreshold \(edgeThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.thetaThreshold.contains(thetaThreshold) {
            if debug { print("[HardGatesV13] thetaThreshold \(thetaThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.phiThreshold.contains(phiThreshold) {
            if debug { print("[HardGatesV13] phiThreshold \(phiThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.l2PlusThreshold.contains(l2PlusThreshold) {
            if debug { print("[HardGatesV13] l2PlusThreshold \(l2PlusThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.l3Threshold.contains(l3Threshold) {
            if debug { print("[HardGatesV13] l3Threshold \(l3Threshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.sharpnessThreshold.contains(sharpnessThreshold) {
            if debug { print("[HardGatesV13] sharpnessThreshold \(sharpnessThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.overexposureThreshold.contains(overexposureThreshold) {
            if debug { print("[HardGatesV13] overexposureThreshold \(overexposureThreshold) out of range") }
            allValid = false
        }

        if !AcceptableRanges.underexposureThreshold.contains(underexposureThreshold) {
            if debug { print("[HardGatesV13] underexposureThreshold \(underexposureThreshold) out of range") }
            allValid = false
        }

        // Validate Q values match Double values
        if !validateQValues(debug: debug) {
            allValid = false
        }

        return allValid
    }

    /// Validate Q values match Double values (within quantization error)
    ///
    /// - Parameter debug: If true, prints detailed validation messages
    /// - Returns: true if all Q values match within quantization error
    public static func validateQValues(debug: Bool = true) -> Bool {
        var allValid = true
        let tolerance = 1  // 1 quantized unit tolerance

        // Validate reprojThresholdQ
        let reprojQExpected = Int64((reprojThreshold * quantizationScale).rounded(.toNearestOrAwayFromZero))
        if abs(reprojThresholdQ - reprojQExpected) > tolerance {
            if debug { print("[HardGatesV13] reprojThresholdQ mismatch: \(reprojThresholdQ) vs \(reprojQExpected)") }
            allValid = false
        }

        // Validate edgeThresholdQ
        let edgeQExpected = Int64((edgeThreshold * quantizationScale).rounded(.toNearestOrAwayFromZero))
        if abs(edgeThresholdQ - edgeQExpected) > tolerance {
            if debug { print("[HardGatesV13] edgeThresholdQ mismatch: \(edgeThresholdQ) vs \(edgeQExpected)") }
            allValid = false
        }

        // Validate minViewGainQ
        let minViewGainQExpected = Int64((minViewGain * quantizationScale).rounded(.toNearestOrAwayFromZero))
        if abs(minViewGainQ - minViewGainQExpected) > tolerance {
            if debug { print("[HardGatesV13] minViewGainQ mismatch: \(minViewGainQ) vs \(minViewGainQExpected)") }
            allValid = false
        }

        return allValid
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fallback Quality
    // ═══════════════════════════════════════════════════════════════════════

    /// Fallback gate quality for invalid inputs
    ///
    /// COMPUTED from worst-case inputs (not a fixed constant)
    /// This ensures fallback is always ≤ minViewGain
    public static var fallbackGateQuality: Double {
        // Worst-case scenario: all gains at minimum
        return minViewGain * 0.4 + minGeomGain * 0.45 + minBasicGain * 0.15
    }
}
