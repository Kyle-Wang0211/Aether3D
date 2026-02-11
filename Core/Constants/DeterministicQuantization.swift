// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicQuantization.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Deterministic Quantization Module (A3 + A4 Implementation)
//
// This module provides deterministic quantization functions for cross-platform consistency.
// All identity-related quantization MUST use these functions.
//

import Foundation

/// Deterministic quantization module for cross-platform consistency.
///
/// **Rule ID:** CROSS_PLATFORM_QUANT_001, CROSS_PLATFORM_QUANT_001A, A1 (v1.1.1)
/// **Status:** IMMUTABLE
public enum DeterministicQuantization {
    
    // MARK: - Quantization Precision Constants (A3)
    
    /// Quantization precision for geomId (1mm, cross-epoch stable).
    /// **Rule ID:** A3
    /// **Status:** IMMUTABLE
    /// **Unit:** meters
    /// **Scope:** identity
    public static let QUANT_POS_GEOM_ID: Double = 1e-3
    
    /// Quantization precision for patchId (0.1mm, epoch-local precise).
    /// **Rule ID:** A3
    /// **Status:** IMMUTABLE
    /// **Unit:** meters
    /// **Scope:** identity
    public static let QUANT_POS_PATCH_ID: Double = 1e-4
    
    // MARK: - Canonicalization Prelude (A1 - v1.1.1)
    
    /// Canonicalizes a floating-point value before quantization.
    ///
    /// **Rule ID:** A1
    /// **Status:** IMMUTABLE
    ///
    /// Rules:
    /// - Input type MUST be Double (Float is forbidden)
    /// - All inputs MUST pass isFinite == true
    /// - NaN/+Inf/-Inf MUST trigger EdgeCase
    /// - -0.0 MUST be normalized to +0.0
    ///
    /// - Parameter value: The value to canonicalize
    /// - Returns: Canonicalized value and edge cases triggered
    public static func canonicalizeInput(_ value: Double) -> (canonicalized: Double, edgeCases: [EdgeCaseType]) {
        var edgeCases: [EdgeCaseType] = []
        var canonicalized = value
        
        // Check for NaN/Inf
        if !value.isFinite {
            edgeCases.append(.NAN_OR_INF_DETECTED)
            canonicalized = 0.0
            return (canonicalized, edgeCases)
        }
        
        // Normalize -0.0 to +0.0
        if value == 0.0 && value.sign == .minus {
            canonicalized = 0.0
        }
        
        return (canonicalized, edgeCases)
    }
    
    // MARK: - Quantization Functions
    
    /// Quantizes a value for geomId computation (1mm precision).
    ///
    /// **Rule ID:** A3, A4, A1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter value: The value to quantize (must be Double, will be canonicalized)
    /// - Returns: Quantization result with edge cases
    public static func quantizeForGeomId(_ value: Double) -> QuantizationResult {
        let (canonicalized, edgeCases) = canonicalizeInput(value)
        
        if !edgeCases.isEmpty {
            return QuantizationResult(
                quantized: 0,
                edgeCasesTriggered: edgeCases,
                rawValue: value
            )
        }
        
        let quantizedValue = canonicalized / QUANT_POS_GEOM_ID
        
        // Check for Int64 overflow before rounding
        let int64MaxDouble = Double(Int64.max)  // 9223372036854775807
        let int64MinDouble: Double = -9.223372036854776e+18  // Double representation of Int64.min
        if quantizedValue > int64MaxDouble || quantizedValue < int64MinDouble {
            var overflowEdgeCases = edgeCases
            overflowEdgeCases.append(.COORDINATE_OUT_OF_RANGE)
            overflowEdgeCases.append(.MESH_VALIDATION_FAILED)
            return QuantizationResult(
                quantized: 0,
                edgeCasesTriggered: overflowEdgeCases,
                rawValue: value
            )
        }
        
        let quantized = roundHalfAwayFromZero(quantizedValue)
        return QuantizationResult(
            quantized: quantized,
            edgeCasesTriggered: edgeCases,
            rawValue: nil
        )
    }
    
    /// Quantizes a value for patchId computation (0.1mm precision).
    ///
    /// **Rule ID:** A3, A4, A1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter value: The value to quantize (must be Double, will be canonicalized)
    /// - Returns: Quantization result with edge cases
    public static func quantizeForPatchId(_ value: Double) -> QuantizationResult {
        let (canonicalized, edgeCases) = canonicalizeInput(value)
        
        if !edgeCases.isEmpty {
            return QuantizationResult(
                quantized: 0,
                edgeCasesTriggered: edgeCases,
                rawValue: value
            )
        }
        
        let quantizedValue = canonicalized / QUANT_POS_PATCH_ID
        
        // Check for Int64 overflow before rounding
        let int64MaxDouble = Double(Int64.max)  // 9223372036854775807
        let int64MinDouble: Double = -9.223372036854776e+18  // Double representation of Int64.min
        if quantizedValue > int64MaxDouble || quantizedValue < int64MinDouble {
            var overflowEdgeCases = edgeCases
            overflowEdgeCases.append(.COORDINATE_OUT_OF_RANGE)
            overflowEdgeCases.append(.MESH_VALIDATION_FAILED)
            return QuantizationResult(
                quantized: 0,
                edgeCasesTriggered: overflowEdgeCases,
                rawValue: value
            )
        }
        
        let quantized = roundHalfAwayFromZero(quantizedValue)
        return QuantizationResult(
            quantized: quantized,
            edgeCasesTriggered: edgeCases,
            rawValue: nil
        )
    }
    
    // MARK: - Rounding Mode Implementation (A4)
    
    /// Rounds a value using ROUND_HALF_AWAY_FROM_ZERO mode.
    ///
    /// **Rule ID:** A4, CROSS_PLATFORM_QUANT_001A
    /// **Status:** IMMUTABLE
    ///
    /// Definition: If |fractional part| == 0.5, round toward the sign of x.
    /// Otherwise, round to nearest integer.
    ///
    /// This is explicitly implemented and does not rely on standard library defaults.
    ///
    /// - Parameter value: The value to round
    /// - Returns: Rounded integer value
    public static func roundHalfAwayFromZero(_ value: Double) -> Int64 {
        if value.isNaN || value.isInfinite {
            return 0
        }
        
        let truncated = value.truncatingRemainder(dividingBy: 1.0)
        let absTruncated = abs(truncated)
        
        if absTruncated == 0.5 {
            // Round toward the sign of value
            if value >= 0 {
                return Int64(value + 0.5)
            } else {
                return Int64(value - 0.5)
            }
        } else {
            // Round to nearest
            return Int64(value.rounded())
        }
    }
    
    // MARK: - Prohibited Operations
    
    /// **Rule ID:** A3
    /// **Status:** IMMUTABLE
    ///
    /// **Prohibited:**
    /// - Using the same precision for both IDs
    /// - Adaptive or dynamic precision
    /// - Precision inferred from mesh density
    /// - Continuous values leaking into identity
}

// MARK: - Quantization Result

/// Result of quantization operation with audit metadata.
///
/// **Rule ID:** MATH_SAFE_001A
/// **Status:** IMMUTABLE
public struct QuantizationResult {
    /// The quantized value (Int64)
    public let quantized: Int64
    
    /// Edge cases triggered during quantization
    public let edgeCasesTriggered: [EdgeCaseType]
    
    /// Raw value (only present if edge cases triggered)
    public let rawValue: Double?
    
    public init(
        quantized: Int64,
        edgeCasesTriggered: [EdgeCaseType],
        rawValue: Double?
    ) {
        self.quantized = quantized
        self.edgeCasesTriggered = edgeCasesTriggered
        self.rawValue = rawValue
    }
}
