//
// GateInputValidator.swift
// Aether3D
//
// PR3 - Gate Input Validation Firewall
// Closed enum reasons, computed fallback quality
//

import Foundation

/// Gate Input Validator: Input validation firewall
///
/// DESIGN:
/// - Uses closed enum for reasons (not strings)
/// - Computes fallback quality from worst-case inputs (not fixed constant)
/// - Never returns NaN or Inf
/// - Never throws (always returns usable result)
public enum GateInputValidator {

    /// Validated inputs structure
    public struct ValidatedInputs: Sendable {
        public let thetaSpanDeg: Double
        public let phiSpanDeg: Double
        public let l2PlusCount: Int
        public let l3Count: Int
        public let reprojRmsPx: Double
        public let edgeRmsPx: Double
        public let sharpness: Double
        public let overexposureRatio: Double
        public let underexposureRatio: Double
    }

    /// Validation result
    public enum ValidationResult: Sendable {
        case valid(ValidatedInputs)
        case invalid(reason: GateInputInvalidReason, fallbackQuality: Double)
    }

    /// Validate all gate inputs
    ///
    /// - Parameters:
    ///   - thetaSpanDeg: Theta span in degrees
    ///   - phiSpanDeg: Phi span in degrees
    ///   - l2PlusCount: L2+ count
    ///   - l3Count: L3 count
    ///   - reprojRmsPx: Reprojection RMS in pixels
    ///   - edgeRmsPx: Edge RMS in pixels
    ///   - sharpness: Sharpness score
    ///   - overexposureRatio: Overexposure ratio [0, 1]
    ///   - underexposureRatio: Underexposure ratio [0, 1]
    /// - Returns: Validation result (valid inputs or invalid reason + fallback)
    public static func validate(
        thetaSpanDeg: Double,
        phiSpanDeg: Double,
        l2PlusCount: Int,
        l3Count: Int,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double
    ) -> ValidationResult {
        var failures: [GateInputInvalidReason] = []

        // Validate theta span
        if !thetaSpanDeg.isFinite {
            failures.append(.thetaSpanNonFinite)
        } else if thetaSpanDeg < 0 {
            failures.append(.thetaSpanNegative)
        }

        // Validate phi span
        if !phiSpanDeg.isFinite {
            failures.append(.phiSpanNonFinite)
        } else if phiSpanDeg < 0 {
            failures.append(.phiSpanNegative)
        }

        // Validate counts
        if l2PlusCount < 0 {
            failures.append(.l2PlusCountNegative)
        }
        if l3Count < 0 {
            failures.append(.l3CountNegative)
        }

        // Validate reprojection RMS
        if !reprojRmsPx.isFinite {
            failures.append(.reprojRmsNonFinite)
        } else if reprojRmsPx < 0 {
            failures.append(.reprojRmsNegative)
        }

        // Validate edge RMS
        if !edgeRmsPx.isFinite {
            failures.append(.edgeRmsNonFinite)
        } else if edgeRmsPx < 0 {
            failures.append(.edgeRmsNegative)
        }

        // Validate sharpness
        if !sharpness.isFinite {
            failures.append(.sharpnessNonFinite)
        } else if sharpness < 0 {
            failures.append(.sharpnessNegative)
        }

        // Validate overexposure ratio
        if !overexposureRatio.isFinite {
            failures.append(.overexposureRatioNonFinite)
        } else if overexposureRatio < 0 || overexposureRatio > 1 {
            failures.append(.overexposureRatioOutOfRange)
        }

        // Validate underexposure ratio
        if !underexposureRatio.isFinite {
            failures.append(.underexposureRatioNonFinite)
        } else if underexposureRatio < 0 || underexposureRatio > 1 {
            failures.append(.underexposureRatioOutOfRange)
        }

        // If any failures, return invalid with computed fallback
        if !failures.isEmpty {
            let reason: GateInputInvalidReason = failures.count == 1 ? failures[0] : .multipleFailures(failures)
            let fallbackQuality = computeFallbackQuality(reason: reason)
            return .invalid(reason: reason, fallbackQuality: fallbackQuality)
        }

        // All valid - return validated inputs
        let validated = ValidatedInputs(
            thetaSpanDeg: thetaSpanDeg,
            phiSpanDeg: phiSpanDeg,
            l2PlusCount: l2PlusCount,
            l3Count: l3Count,
            reprojRmsPx: reprojRmsPx,
            edgeRmsPx: edgeRmsPx,
            sharpness: sharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio
        )
        return .valid(validated)
    }

    /// Compute fallback quality from worst-case inputs
    ///
    /// DESIGN: Computed from worst-case scenario, not a fixed constant
    /// This ensures fallback is always ≤ minViewGain
    ///
    /// - Parameter reason: Invalid reason
    /// - Returns: Fallback quality ∈ [0, minViewGain]
    private static func computeFallbackQuality(reason: GateInputInvalidReason) -> Double {
        // Worst-case scenario: all gains at minimum
        // This matches HardGatesV13.fallbackGateQuality
        return HardGatesV13.minViewGain * 0.4 + HardGatesV13.minGeomGain * 0.45 + HardGatesV13.minBasicGain * 0.15
    }
}
