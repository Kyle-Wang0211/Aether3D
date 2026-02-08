//
// PatchWeightComputer.swift
// Aether3D
//
// PR2 Patch V4 - Comprehensive Patch Weight Computation
// Three-factor weight: frequency + decay + view diversity
//

import Foundation

/// Comprehensive patch weight computation
public struct PatchWeightComputer {
    
    /// Compute comprehensive patch weight (3-factor: frequency + decay + diversity)
    /// - Parameters:
    ///   - observationCount: Number of observations
    ///   - lastUpdate: Last update timestamp
    ///   - currentTime: Current timestamp
    ///   - viewDiversityScore: Diversity score from ViewDiversityTracker [0, 1]
    /// - Returns: Combined weight [0, 1]
    public static func computeWeight(
        observationCount: Int,
        lastUpdate: TimeInterval,
        currentTime: TimeInterval,
        viewDiversityScore: Double
    ) -> Double {
        return computeWeight(
            observationCount: observationCount,
            lastUpdate: lastUpdate,
            currentTime: currentTime,
            viewDiversityScore: viewDiversityScore,
            dimensionalCompleteness: nil
        )
    }
    
    /// **Rule ID:** PR6_GRID_WEIGHT_001
    /// Compute comprehensive patch weight (4-factor: frequency + decay + diversity + dimensional completeness)
    /// - Parameters:
    ///   - observationCount: Number of observations
    ///   - lastUpdate: Last update timestamp
    ///   - currentTime: Current timestamp
    ///   - viewDiversityScore: Diversity score from ViewDiversityTracker [0, 1]
    ///   - dimensionalCompleteness: Dimensional completeness score [0, 1] (optional, PR6 extension)
    /// - Returns: Combined weight [0, 1]
    public static func computeWeight(
        observationCount: Int,
        lastUpdate: TimeInterval,
        currentTime: TimeInterval,
        viewDiversityScore: Double,
        dimensionalCompleteness: Double? = nil
    ) -> Double {
        // Factor 1: Frequency cap (anti-spam)
        let frequencyWeight = min(1.0, Double(observationCount) / EvidenceConstants.weightCapDenominator)
        
        // Factor 2: Confidence decay (recency)
        // Use exponential decay: w(t) = 0.5 ^ (age / halfLife)
        let age = currentTime - lastUpdate
        let halfLife = EvidenceConstants.confidenceHalfLifeSec
        let decayWeight = pow(0.5, age / halfLife)
        
        // Factor 3: View diversity (coverage)
        // Low diversity = less reliable evidence
        let clampedDiversity = max(0.0, min(1.0, viewDiversityScore))
        let diversityWeight = 0.5 + 0.5 * clampedDiversity  // Range: [0.5, 1.0]
        
        // Factor 4: Dimensional completeness (PR6 extension)
        let dimensionalWeight: Double
        if let completeness = dimensionalCompleteness {
            // Use dimensional completeness as 4th factor
            let clampedCompleteness = max(0.0, min(1.0, completeness))
            dimensionalWeight = 0.5 + 0.5 * clampedCompleteness  // Range: [0.5, 1.0]
        } else {
            // No dimensional data: use 1.0 (no penalty)
            dimensionalWeight = 1.0
        }
        
        // Combine: multiplicative for factors that should compound
        let combined = frequencyWeight * decayWeight * diversityWeight * dimensionalWeight
        
        // Clamp to [0, 1]
        return max(0.0, min(1.0, combined))
    }
}

// clampedEvidence is defined in ClampedEvidence.swift
