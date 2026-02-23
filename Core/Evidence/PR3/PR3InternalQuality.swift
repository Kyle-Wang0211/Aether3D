// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PR3InternalQuality.swift
// Aether3D
//
// PR3 - PR3 Internal Quality Definition
// Single metric space, reuses GateGainFunctions
//

import Foundation

/// PR3 Internal Quality Definition
///
/// DESIGN:
/// - Defines L2+/L3 classification purely based on basicGain and geomGain
/// - Reuses GateGainFunctions to ensure single metric space
/// - Self-contained and independent of future PR4 metrics
public enum PR3InternalQuality {

    /// Compute PR3 internal quality
    ///
    /// FORMULA: pr3Quality = 0.4 * basicQuality + 0.6 * geomQuality
    ///
    /// - Parameters:
    ///   - basicGain: Basic quality gain
    ///   - geomGain: Geometry quality gain
    /// - Returns: PR3 internal quality ∈ [0, 1]
    @inlinable
    public static func compute(basicGain: Double, geomGain: Double) -> Double {
        // Weighted combination: basic 40%, geom 60%
        let quality = 0.4 * basicGain + 0.6 * geomGain
        return max(0.0, min(1.0, quality))
    }

    /// Check if quality qualifies as L2+
    ///
    /// L2+ means quality > 0.3 (basic geometric stability)
    ///
    /// - Parameter quality: PR3 internal quality
    /// - Returns: true if L2+
    @inlinable
    public static func isL2Plus(quality: Double) -> Bool {
        return quality > HardGatesV13.l2QualityThreshold
    }

    /// Check if quality qualifies as L3
    ///
    /// L3 means quality > 0.6 (good tracking, minimal blur)
    ///
    /// - Parameter quality: PR3 internal quality
    /// - Returns: true if L3
    @inlinable
    public static func isL3(quality: Double) -> Bool {
        return quality > HardGatesV13.l3QualityThreshold
    }
}
