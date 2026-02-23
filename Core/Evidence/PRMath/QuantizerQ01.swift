// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QuantizerQ01.swift
// Aether3D
//
// PR3 - Type-Safe [0,1] Quantization
// Only for gain values, quality scores, ratios
//

import Foundation

/// Type-safe quantizer for [0, 1] values only
///
/// USAGE: Gain values, quality scores, ratios
/// FORBIDDEN: Angles, counts, raw inputs
public enum QuantizerQ01 {

    /// Scale for 12 decimal places
    public static let scale: Double = 1e12
    public static let scaleInt64: Int64 = 1_000_000_000_000

    /// Quantize [0, 1] value to Int64
    ///
    /// PRECONDITION: value ∈ [0, 1]
    /// OUTPUT: Int64 ∈ [0, scaleInt64]
    ///
    /// - Parameter value: Input value ∈ [0, 1]
    /// - Returns: Quantized Int64 value
    @inlinable
    public static func quantize(_ value: Double) -> Int64 {
        // Clamp to valid range (defensive)
        let clamped = max(0.0, min(1.0, value))
        // Round half away from zero (deterministic)
        return Int64((clamped * scale).rounded(.toNearestOrAwayFromZero))
    }

    /// Dequantize Int64 back to Double
    ///
    /// - Parameter q: Quantized Int64 value
    /// - Returns: Double value ∈ [0, 1]
    @inlinable
    public static func dequantize(_ q: Int64) -> Double {
        return Double(q) / scale
    }

    /// Check if two quantized values are equal
    ///
    /// - Parameters:
    ///   - a: First quantized value
    ///   - b: Second quantized value
    /// - Returns: true if equal
    @inlinable
    public static func areEqual(_ a: Int64, _ b: Int64) -> Bool {
        return a == b
    }

    /// Check if two quantized values are within tolerance
    ///
    /// - Parameters:
    ///   - a: First quantized value
    ///   - b: Second quantized value
    ///   - tolerance: Tolerance in quantized units (default: 1)
    /// - Returns: true if within tolerance
    @inlinable
    public static func areClose(_ a: Int64, _ b: Int64, tolerance: Int64 = 1) -> Bool {
        return abs(a - b) <= tolerance
    }
}
