//
// ConfidenceDecay.swift
// Aether3D
//
// PR2 Patch V4 - Confidence Decay
// ONLY affects aggregation weight, NEVER modifies evidence
//

import Foundation

/// Confidence decay for stale patches
///
/// INVARIANT: This function NEVER modifies PatchEntry.evidence
/// It only returns a weight to be used in totalEvidence() computation
public enum ConfidenceDecay {
    
    /// Half-life in seconds
    public static let halfLifeSec: Double = EvidenceConstants.confidenceHalfLifeSec
    
    /// Compute WEIGHT for aggregation (NOT evidence value)
    ///
    /// Uses exponential decay: w(t) = 0.5 ^ (age / halfLife)
    ///
    /// - Parameters:
    ///   - lastUpdateMs: Last update timestamp in milliseconds
    ///   - currentTimeMs: Current timestamp in milliseconds
    /// - Returns: Decay weight [0, 1] where 1.0 = no decay, 0.0 = fully decayed
    public static func aggregationWeight(
        lastUpdateMs: Int64,
        currentTimeMs: Int64
    ) -> Double {
        let age = Double(currentTimeMs - lastUpdateMs) / 1000.0  // Convert to seconds
        return pow(0.5, age / halfLifeSec)
    }
    
    /// Compute weight from TimeInterval (convenience)
    public static func aggregationWeight(
        lastUpdate: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        let age = currentTime - lastUpdate
        return pow(0.5, age / halfLifeSec)
    }
}
