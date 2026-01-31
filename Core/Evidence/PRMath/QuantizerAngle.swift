//
// QuantizerAngle.swift
// Aether3D
//
// PR3 - Type-Safe Angle Quantization
// For angle values in degrees
//

import Foundation

/// Type-safe quantizer for angle values
///
/// USAGE: Span degrees, angle degrees
/// SCALE: 1e9 (9 decimal places, angles don't need 12)
public enum QuantizerAngle {

    /// Scale for 9 decimal places
    public static let scale: Double = 1e9
    public static let scaleInt64: Int64 = 1_000_000_000

    /// Quantize angle in degrees to Int64
    ///
    /// PRECONDITION: value is finite
    /// OUTPUT: Int64 representation
    ///
    /// - Parameter degrees: Angle in degrees
    /// - Returns: Quantized Int64 value
    @inlinable
    public static func quantize(_ degrees: Double) -> Int64 {
        guard degrees.isFinite else { return 0 }
        return Int64((degrees * scale).rounded(.toNearestOrAwayFromZero))
    }

    /// Dequantize Int64 back to Double
    ///
    /// - Parameter q: Quantized Int64 value
    /// - Returns: Angle in degrees
    @inlinable
    public static func dequantize(_ q: Int64) -> Double {
        return Double(q) / scale
    }
}
