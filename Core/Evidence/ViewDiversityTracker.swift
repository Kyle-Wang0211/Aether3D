// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ViewDiversityTracker.swift
// Aether3D
//
// PR2 Patch V4 - View Diversity Tracker
// Deterministic angle bucketing for novelty scoring
//

import Foundation

/// View angle bucket state
private struct AngleBucket {
    let bucketIndex: Int
    var observationCount: Int
    var lastUpdateMs: Int64
    
    init(bucketIndex: Int, observationCount: Int = 1, lastUpdateMs: Int64 = 0) {
        self.bucketIndex = bucketIndex
        self.observationCount = observationCount
        self.lastUpdateMs = lastUpdateMs
    }
}

/// View diversity tracker
///
/// DESIGN:
/// - Buckets view angles into fixed-size buckets
/// - Novelty score higher for new buckets
/// - Deterministic storage (sorted arrays, no Set iteration)
public final class ViewDiversityTracker {
    
    /// Per-patch bucket tracking (sorted by bucket index)
    private var patchBuckets: [String: [AngleBucket]] = [:]
    
    public init() {}
    
    /// Add observation and return novelty score
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - viewAngleDeg: View angle in degrees [0, 360)
    ///   - timestampMs: Current timestamp in milliseconds
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Novelty score [0, 1] where 1.0 = highly novel (new bucket)
    public func addObservation(
        patchId: String,
        viewAngleDeg: Double,
        timestampMs: Int64,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Double {
        // Normalize angle to [0, 360)
        let normalizedAngle = viewAngleDeg.truncatingRemainder(dividingBy: 360.0)
        let clampedAngle = normalizedAngle < 0 ? normalizedAngle + 360.0 : normalizedAngle
        
        // Compute bucket index
        let bucketIndex = Int(clampedAngle / constants.diversityAngleBucketSizeDeg)
        
        // Get or create bucket list for this patch
        var buckets = patchBuckets[patchId] ?? []
        
        // Check if bucket already exists
        let existingIndex = buckets.firstIndex { $0.bucketIndex == bucketIndex }
        
        if let idx = existingIndex {
            // Existing bucket: increment count
            buckets[idx].observationCount += 1
            buckets[idx].lastUpdateMs = timestampMs
        } else {
            // New bucket: add it
            let newBucket = AngleBucket(
                bucketIndex: bucketIndex,
                observationCount: 1,
                lastUpdateMs: timestampMs
            )
            buckets.append(newBucket)
            
            // Keep sorted by bucket index (deterministic)
            buckets.sort { $0.bucketIndex < $1.bucketIndex }
            
            // Cap bucket count
            if buckets.count > constants.diversityMaxBucketsTracked {
                // Remove oldest bucket (by lastUpdateMs)
                buckets.sort { $0.lastUpdateMs < $1.lastUpdateMs }
                buckets.removeFirst()
                // Re-sort by bucket index
                buckets.sort { $0.bucketIndex < $1.bucketIndex }
            }
        }
        
        patchBuckets[patchId] = buckets
        
        // Compute novelty score: higher for new buckets, lower for many observations in same bucket
        return diversityScore(patchId: patchId, constants: constants)
    }
    
    /// Get diversity score for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Diversity score [0, 1] where 1.0 = high diversity
    public func diversityScore(
        patchId: String,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Double {
        guard let buckets = patchBuckets[patchId], !buckets.isEmpty else {
            return 1.0  // No observations = maximum novelty
        }
        
        // Score based on:
        // 1. Number of unique buckets (more buckets = higher diversity)
        // 2. Distribution of observations (even distribution = higher diversity)
        
        let uniqueBuckets = buckets.count
        let totalObservations = buckets.reduce(0) { $0 + $1.observationCount }
        
        // Normalize by max buckets
        let bucketScore = Double(uniqueBuckets) / Double(constants.diversityMaxBucketsTracked)
        
        // Distribution score: entropy-like measure
        // More even distribution = higher score
        var distributionScore: Double = 0.0
        if totalObservations > 0 {
            for bucket in buckets {
                let proportion = Double(bucket.observationCount) / Double(totalObservations)
                if proportion > 0 {
                    distributionScore -= proportion * log2(proportion)
                }
            }
            // Normalize by max entropy (log2(maxBuckets))
            let maxEntropy = log2(Double(constants.diversityMaxBucketsTracked))
            distributionScore = maxEntropy > 0 ? distributionScore / maxEntropy : 0.0
        }
        
        // Combine scores (weighted average)
        let combinedScore = 0.6 * bucketScore + 0.4 * distributionScore
        
        return max(0.0, min(1.0, combinedScore))
    }
    
    /// Reset all tracking
    public func reset() {
        patchBuckets.removeAll()
    }
}
