// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BucketedAmortizedAggregator.swift
// Aether3D
//
// PR2 Patch V4 - Bucketed Amortized Aggregator
// O(k) aggregation with bucket-based decay (k=8 constant)
//

import Foundation

/// Amortized aggregator with bucket-based decay
///
/// DESIGN DECISION: Trade some decay granularity for O(k) performance
/// where k = number of active buckets (typically 4-8), not n = number of patches
public final class BucketedAmortizedAggregator {
    
    // MARK: - Decay Bucket Configuration
    
    /// Bucket duration in seconds (15s per bucket)
    public static let bucketDurationSec: Double = 15.0
    
    /// Maximum buckets to track (120s total at 15s buckets = 8 buckets)
    public static let maxBuckets: Int = 8
    
    /// Decay weights per bucket (index 0 = newest)
    /// Computed from: exp(-0.693 * (bucketIndex * bucketDuration) / halfLife)
    /// With halfLife = 60s: [1.0, 0.84, 0.71, 0.59, 0.50, 0.42, 0.35, 0.30]
    public static let bucketWeights: [Double] = [
        1.0,    // 0-15s
        0.84,   // 15-30s
        0.71,   // 30-45s
        0.59,   // 45-60s
        0.50,   // 60-75s
        0.42,   // 75-90s
        0.35,   // 90-105s
        0.30    // 105-120s
    ]
    
    // MARK: - Bucket Storage
    
    /// Bucket containing aggregated contributions
    public struct Bucket {
        var weightedSum: Double = 0.0
        var totalWeight: Double = 0.0
        var patchCount: Int = 0
        let createdAt: TimeInterval
        
        init(createdAt: TimeInterval) {
            self.createdAt = createdAt
        }
    }
    
    /// Buckets ordered by time (index 0 = current)
    private var buckets: [Bucket] = []
    
    /// Patch -> (bucketIndex, evidence, weight) for incremental updates
    private var patchLocations: [String: (bucketIndex: Int, evidence: Double, weight: Double)] = [:]
    
    /// Current bucket start time
    private var currentBucketStart: TimeInterval = 0
    
    /// Recalculation interval (frames)
    public static let recalculationIntervalFrames: Int = 60
    
    /// Frame counter for recalculation
    private var frameCount: Int = 0
    
    // MARK: - Public API
    
    public init() {
        // Initialize with first bucket
        let now = Date().timeIntervalSince1970
        buckets = [Bucket(createdAt: now)]
        currentBucketStart = now
    }
    
    /// Update patch contribution
    /// O(1) for updates within same bucket
    public func updatePatch(
        patchId: String,
        evidence: Double,
        baseWeight: Double,  // From frequency cap, NOT including decay
        timestamp: TimeInterval
    ) {
        // Rotate buckets if needed
        rotateBucketsIfNeeded(timestamp: timestamp)
        
        // Remove old contribution
        if let old = patchLocations[patchId] {
            if old.bucketIndex < buckets.count {
                buckets[old.bucketIndex].weightedSum -= old.evidence * old.weight
                buckets[old.bucketIndex].totalWeight -= old.weight
                buckets[old.bucketIndex].patchCount -= 1
            }
        }
        
        // Add new contribution to current bucket (index 0)
        let currentBucket = 0
        buckets[currentBucket].weightedSum += evidence * baseWeight
        buckets[currentBucket].totalWeight += baseWeight
        buckets[currentBucket].patchCount += 1
        
        // Track location
        patchLocations[patchId] = (currentBucket, evidence, baseWeight)
        
        frameCount += 1
    }
    
    /// Get total evidence with decay applied
    /// O(k) where k = number of buckets (constant, typically 4-8)
    public var totalEvidence: Double {
        var weightedSum: Double = 0.0
        var totalWeight: Double = 0.0
        
        for (index, bucket) in buckets.enumerated() {
            let decayWeight = index < Self.bucketWeights.count
                ? Self.bucketWeights[index]
                : Self.bucketWeights.last!
            
            weightedSum += bucket.weightedSum * decayWeight
            totalWeight += bucket.totalWeight * decayWeight
        }
        
        return totalWeight > 0 ? weightedSum / totalWeight : 0.0
    }
    
    /// Periodic full recalculation (every N frames) to correct drift
    public func recalibrate(
        patches: [(patchId: String, evidence: Double, weight: Double, lastUpdate: TimeInterval)],
        currentTime: TimeInterval
    ) {
        // Reset
        buckets.removeAll()
        patchLocations.removeAll()
        currentBucketStart = currentTime
        frameCount = 0
        
        // Re-add all patches
        for patch in patches {
            let age = currentTime - patch.lastUpdate
            let bucketIndex = min(Self.maxBuckets - 1, Int(age / Self.bucketDurationSec))
            
            // Ensure bucket exists
            while buckets.count <= bucketIndex {
                let bucketTime = currentTime - Double(buckets.count) * Self.bucketDurationSec
                buckets.append(Bucket(createdAt: bucketTime))
            }
            
            buckets[bucketIndex].weightedSum += patch.evidence * patch.weight
            buckets[bucketIndex].totalWeight += patch.weight
            buckets[bucketIndex].patchCount += 1
            patchLocations[patch.patchId] = (bucketIndex, patch.evidence, patch.weight)
        }
    }
    
    /// Check if recalculation is needed
    public func shouldRecalibrate() -> Bool {
        return frameCount >= Self.recalculationIntervalFrames
    }
    
    // MARK: - Private
    
    /// Rotate buckets when time advances
    private func rotateBucketsIfNeeded(timestamp: TimeInterval) {
        let elapsed = timestamp - currentBucketStart
        let bucketsToRotate = Int(elapsed / Self.bucketDurationSec)
        
        if bucketsToRotate > 0 {
            // Insert new buckets at front
            for i in 0..<bucketsToRotate {
                let bucketTime = currentBucketStart + Double(bucketsToRotate - i) * Self.bucketDurationSec
                buckets.insert(Bucket(createdAt: bucketTime), at: 0)
                
                // Update patch locations (shift indices)
                for (patchId, var location) in patchLocations {
                    location.bucketIndex += 1
                    patchLocations[patchId] = location
                }
            }
            
            // Trim old buckets
            while buckets.count > Self.maxBuckets {
                let removed = buckets.removeLast()
                // Remove patches in deleted bucket
                patchLocations = patchLocations.filter { $0.value.bucketIndex < Self.maxBuckets }
            }
            
            currentBucketStart = timestamp
        }
    }
}
