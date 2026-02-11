// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZFloatCanon.swift
// Aether3D
//
// PR1 PIZ Detection - Float Canonicalization
//
// Implements SSOT quantization for floating-point values before JSON serialization.
// **Rule ID:** PIZ_FLOAT_CANON_001, PIZ_NUMERIC_FORMAT_001

import Foundation

/// Float canonicalization for PIZ detection outputs.
/// **Rule ID:** PIZ_FLOAT_CANON_001
public enum PIZFloatCanon {
    
    /// Quantize a floating-point value using SSOT precision.
    /// **Rule ID:** PIZ_FLOAT_CANON_001
    ///
    /// Algorithm:
    /// 1. scaled = value / JSON_CANON_QUANTIZATION_PRECISION
    /// 2. rounded_scaled = ROUND_HALF_AWAY_FROM_ZERO(scaled)
    /// 3. quantized = rounded_scaled * JSON_CANON_QUANTIZATION_PRECISION
    /// 4. Normalize -0.0 to +0.0
    ///
    /// - Parameter value: The value to quantize (must be finite, normal, in [0.0, 1.0])
    /// - Returns: Quantized value
    public static func quantize(_ value: Double) -> Double {
        let precision = PIZThresholds.JSON_CANON_QUANTIZATION_PRECISION
        
        // Scale value
        let scaled = value / precision
        
        // Round using ROUND_HALF_AWAY_FROM_ZERO
        let roundedScaled = roundHalfAwayFromZero(scaled)
        
        // Multiply back by precision
        let quantized = Double(roundedScaled) * precision
        
        // Normalize -0.0 to +0.0
        if quantized == 0.0 && quantized.sign == .minus {
            return 0.0
        }
        
        return quantized
    }
    
    /// Round a Double value using ROUND_HALF_AWAY_FROM_ZERO.
    /// **Rule ID:** PIZ_FLOAT_CANON_001
    ///
    /// Definition: If |fractional part| == 0.5, round toward the sign of x.
    /// Otherwise, round to nearest integer.
    private static func roundHalfAwayFromZero(_ value: Double) -> Int64 {
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
    
    /// Quantize all floating-point values in a 2D array (heatmap).
    public static func quantizeHeatmap(_ heatmap: [[Double]]) -> [[Double]] {
        return heatmap.map { row in
            row.map { quantize($0) }
        }
    }
    
    /// Quantize all floating-point values in a PIZRegion.
    public static func quantizeRegion(_ region: PIZRegion) -> PIZRegion {
        return PIZRegion(
            id: region.id,
            pixelCount: region.pixelCount,
            areaRatio: quantize(region.areaRatio),
            bbox: region.bbox,
            centroid: Point(
                row: quantize(region.centroid.row),
                col: quantize(region.centroid.col)
            ),
            principalDirection: Vector(
                dx: quantize(region.principalDirection.dx),
                dy: quantize(region.principalDirection.dy)
            ),
            severityScore: quantize(region.severityScore)
        )
    }
}
