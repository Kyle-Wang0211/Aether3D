// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EmpiricalP68Calibrator.swift
// PR4Calibration
//
// PR4 V10 - Pillar 25: Empirical P68 calibration
//

import Foundation
import PR4Math

/// Empirical P68 calibrator
///
/// V8 RULE: Use 68th percentile (P68) for calibration.
public enum EmpiricalP68Calibrator {
    
    /// Minimum samples required
    public static let minSamples: Int = 3
    
    /// Compute P68 from samples
    public static func computeP68(_ samples: [Double]) -> Double {
        guard samples.count >= minSamples else {
            // Fallback: use MAD × 1.4826
            return DeterministicMedianMAD.mad(samples) * 1.4826
        }
        
        // Sort samples
        var sorted = samples
        sorted.sort()
        
        // Find 68th percentile index
        let p68Index = Int(Double(sorted.count) * 0.68)
        let clampedIndex = Swift.max(0, Swift.min(sorted.count - 1, p68Index))
        
        return sorted[clampedIndex]
    }
}
