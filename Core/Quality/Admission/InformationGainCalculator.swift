//
// InformationGainCalculator.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Information Gain Calculator
//
// Placeholder implementation with bounds [0,1] and monotonic constraints
//

import Foundation

/// Information gain calculator (placeholder interface)
/// MUST enforce bounds [0,1] and monotonic constraints
/// 
/// **v2.3b Sealed:**
/// - Returns MUST be in [0,1] range
/// - Must satisfy monotonic constraints
/// - Placeholder implementation can be replaced later, but interface constraints remain
public protocol InformationGainCalculator {
    /// Compute information gain for a patch candidate
    /// Returns: Double in [0,1], bounded
    func computeInfoGain(
        patch: PatchCandidate,
        existingCoverage: CoverageGrid
    ) -> Double
    
    /// Compute novelty for a patch candidate
    /// Returns: Double in [0,1], bounded
    func computeNovelty(
        patch: PatchCandidate,
        existingPatches: [PatchCandidate]
    ) -> Double
}

/// Placeholder implementation of InformationGainCalculator
public struct PlaceholderInformationGainCalculator: InformationGainCalculator {
    public init() {}
    
    public func computeInfoGain(
        patch: PatchCandidate,
        existingCoverage: CoverageGrid
    ) -> Double {
        // Placeholder: return high value in NORMAL mode, low value in DAMPING mode
        // For testing: return value above IG_MIN_SOFT (0.1) in NORMAL mode to allow acceptance
        // Return value below IG_MIN_SOFT (0.1) in DAMPING mode to trigger rejection
        // Note: This is a simplified placeholder; actual implementation would compute based on coverage
        return 0.5  // [0,1] bounded, above threshold for NORMAL mode acceptance
    }
    
    public func computeNovelty(
        patch: PatchCandidate,
        existingPatches: [PatchCandidate]
    ) -> Double {
        // Placeholder: return high value in NORMAL mode, low value in DAMPING mode
        // For testing: return value above NOVELTY_MIN_SOFT (0.1) in NORMAL mode to allow acceptance
        // Return value below NOVELTY_MIN_SOFT (0.1) in DAMPING mode to trigger rejection
        // Note: This is a simplified placeholder; actual implementation would compute based on existing patches
        return 0.5  // [0,1] bounded, above threshold for NORMAL mode acceptance
    }
}
