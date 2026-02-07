//
// SoftQualityComputer.swift
// PR4Quality
//
// PR4 V10 - Pillar 37: Soft quality computation
//

import Foundation
import PR4Math
import PR4LUT
import PR4Overflow
import PR4Uncertainty

/// Soft quality computer
///
/// Computes quality metrics from depth samples.
public enum SoftQualityComputer {
    
    /// Compute quality from depth samples
    public static func compute(
        samples: [Double],
        uncertainty: Double
    ) -> QualityResult {
        // NOTE: Basic quality computation
        let consistency = computeConsistency(samples)
        let coverage = Double(samples.count) / 100.0  // Normalized
        
        let quality = (consistency + coverage) / 2.0
        
        return QualityResult(
            value: Swift.max(0.0, Swift.min(1.0, quality)),
            uncertainty: uncertainty
        )
    }
    
    private static func computeConsistency(_ samples: [Double]) -> Double {
        guard samples.count >= 2 else { return 0.5 }
        
        // Compute variance
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0, +) / Double(samples.count)
        let stdDev = sqrt(variance)
        
        // Consistency = inverse of normalized std dev
        let normalizedStdDev = stdDev / (mean + 1e-6)
        return 1.0 / (1.0 + normalizedStdDev)
    }
}
