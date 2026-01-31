//
// GateInputInvalidReason.swift
// Aether3D
//
// PR3 - Gate Input Invalid Reason (Closed Enum)
// All invalid reasons explicitly enumerated
//

import Foundation

/// Closed enum for gate input validation failure reasons
///
/// DESIGN:
/// - Closed enum ensures all reasons are explicit
/// - No string-based reasons (type-safe)
/// - Each reason maps to a computed fallback quality
public enum GateInputInvalidReason: Sendable, Codable, Equatable {

    /// Theta span is NaN or Inf
    case thetaSpanNonFinite

    /// Phi span is NaN or Inf
    case phiSpanNonFinite

    /// Theta span is negative
    case thetaSpanNegative

    /// Phi span is negative
    case phiSpanNegative

    /// L2+ count is negative
    case l2PlusCountNegative

    /// L3 count is negative
    case l3CountNegative

    /// Reprojection RMS is NaN or Inf
    case reprojRmsNonFinite

    /// Edge RMS is NaN or Inf
    case edgeRmsNonFinite

    /// Reprojection RMS is negative
    case reprojRmsNegative

    /// Edge RMS is negative
    case edgeRmsNegative

    /// Sharpness is NaN or Inf
    case sharpnessNonFinite

    /// Sharpness is negative
    case sharpnessNegative

    /// Overexposure ratio is NaN or Inf
    case overexposureRatioNonFinite

    /// Underexposure ratio is NaN or Inf
    case underexposureRatioNonFinite

    /// Overexposure ratio is out of [0, 1]
    case overexposureRatioOutOfRange

    /// Underexposure ratio is out of [0, 1]
    case underexposureRatioOutOfRange

    /// Multiple validation failures
    case multipleFailures([GateInputInvalidReason])
}
