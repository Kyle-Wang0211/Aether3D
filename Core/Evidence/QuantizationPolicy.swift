// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QuantizationPolicy.swift
// Aether3D
//
// PR2 Patch V4 - Float Quantization Policy
// Defines which fields should be quantized and how
//

import Foundation

/// Quantization policy for deterministic serialization
///
/// QUANTIZED (4 decimal places):
/// - Evidence values (0.0 to 1.0)
/// - Quality scores
/// - Weights
/// - Delta values
/// - Display values
///
/// NOT QUANTIZED:
/// - Timestamps (use Int64 milliseconds instead)
/// - Integer counts (observationCount, errorStreak)
/// - Version strings
/// - PatchId strings
/// - Coordinates (use Int64 or fixed precision separately)
public enum QuantizationPolicy {
    
    /// Default precision for quantized fields
    public static let defaultPrecision: Int = 4
    
    /// Fields that should be quantized
    public static let quantizedFields: Set<String> = [
        "evidence",
        "gateEvidence",
        "softEvidence",
        "quality",
        "gateQuality",
        "softQuality",
        "weight",
        "delta",
        "smoothedDelta",
        "rawDelta",
        "totalEvidence",
        "gateDisplay",
        "softDisplay",
        "totalDisplay",
        "gateDelta",
        "softDelta",
        "penalty",
        "scale",
        "multiplier",
        "alpha",
        "decayWeight",
        "frequencyWeight",
        "diversityWeight",
    ]
    
    /// Check if field should be quantized
    public static func shouldQuantize(fieldName: String) -> Bool {
        return quantizedFields.contains(fieldName)
    }
    
    /// Quantize value to fixed precision
    /// Uses half-away-from-zero rounding
    public static func quantize(_ value: Double, precision: Int = defaultPrecision) -> Double {
        // Handle special values
        if value.isNaN {
            return Double.nan
        }
        if value.isInfinite {
            return value
        }
        
        // Normalize -0.0 to 0.0
        if value == -0.0 {
            return 0.0
        }
        
        // Half-away-from-zero rounding
        let multiplier = pow(10.0, Double(precision))
        let scaled = value * multiplier
        
        // Round away from zero
        let rounded: Double
        if scaled >= 0 {
            rounded = floor(scaled + 0.5)
        } else {
            rounded = ceil(scaled - 0.5)
        }
        
        return rounded / multiplier
    }
    
    /// Format quantized double as string (no scientific notation)
    public static func formatQuantized(_ value: Double, precision: Int = defaultPrecision) -> String {
        // Handle special values
        if value.isNaN {
            return "null"
        }
        if value.isInfinite {
            return value > 0 ? "1e308" : "-1e308"
        }
        
        // Normalize -0.0
        let normalized = value == -0.0 ? 0.0 : value
        
        // Quantize
        let quantized = quantize(normalized, precision: precision)
        
        // Format without scientific notation
        let formatted = String(format: "%.\(precision)f", quantized)
        
        // Remove trailing zeros after decimal point
        var result = formatted
        while result.contains(".") && (result.hasSuffix("0") || result.hasSuffix(".")) {
            result.removeLast()
        }
        
        return result.isEmpty ? "0" : result
    }
}
