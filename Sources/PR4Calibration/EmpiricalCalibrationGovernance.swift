//
// EmpiricalCalibrationGovernance.swift
// PR4Calibration
//
// PR4 V10 - Pillar 20: Empirical calibration governance
//

import Foundation
import PR4Math

/// Empirical calibration governance
///
/// V9 RULE: Govern calibration under all conditions (small N, drift, mixed distributions).
public enum EmpiricalCalibrationGovernance {
    
    /// Minimum samples for reliable calibration
    public static let minReliableSamples: Int = 10
    
    /// Compute calibration sigma
    public static func computeSigma(
        samples: [Double],
        useEmpirical: Bool = true
    ) -> (sigma: Double, method: CalibrationMethod, flags: Set<String>) {
        var flags: Set<String> = []
        
        if samples.count < minReliableSamples {
            flags.insert("insufficientSamples")
        }
        
        if useEmpirical && samples.count >= EmpiricalP68Calibrator.minSamples {
            let p68 = EmpiricalP68Calibrator.computeP68(samples)
            return (sigma: p68, method: .empirical, flags: flags)
        } else {
            // Fallback: MAD × 1.4826
            let mad = DeterministicMedianMAD.mad(samples)
            let sigma = mad * 1.4826
            flags.insert("usingFallback")
            return (sigma: sigma, method: .fallback, flags: flags)
        }
    }
    
    public enum CalibrationMethod: String {
        case empirical
        case fallback
    }
}
