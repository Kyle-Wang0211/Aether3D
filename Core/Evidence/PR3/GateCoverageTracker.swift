// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GateCoverageTracker.swift
// Aether3D
//
// PR3 - Gate Coverage Tracker
// Tracks angular distribution using Bitset and Zero-Trig bucketing
//

import Foundation

/// Gate Coverage Tracker: Tracks angular distribution for gate quality
///
/// DESIGN:
/// - Uses Bitset for O(1) bucket operations
/// - Uses Zero-Trig bucketing (no atan2/asin)
/// - Deterministic eviction by frameIndex
/// - L2+/L3 counts only updated when new bucket is filled
/// - Does NOT reference ViewDiversityTracker (coexistence, not replacement)
public final class GateCoverageTracker: @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    /// View record for a single observation
    public struct ViewRecord: Sendable {
        /// Frame index (for deterministic eviction)
        public let frameIndex: Int

        /// Theta bucket index
        public let thetaBucket: Int

        /// Phi bucket index
        public let phiBucket: Int

        /// PR3 internal quality (for L2+/L3 classification)
        public let pr3Quality: Double

        public init(frameIndex: Int, thetaBucket: Int, phiBucket: Int, pr3Quality: Double) {
            self.frameIndex = frameIndex
            self.thetaBucket = thetaBucket
            self.phiBucket = phiBucket
            self.pr3Quality = pr3Quality
        }
    }

    /// Per-patch tracking state
    private struct PatchState: Sendable {
        /// Theta bucket bitset
        var thetaBuckets: ThetaBucketBitset = ThetaBucketBitset()

        /// Phi bucket bitset
        var phiBuckets: PhiBucketBitset = PhiBucketBitset()

        /// View records (for eviction)
        var records: [ViewRecord] = []

        /// L2+ count (cached, updated only when new bucket)
        var l2PlusCount: Int = 0

        /// L3 count (cached, updated only when new bucket)
        var l3Count: Int = 0

        /// Track which buckets have been counted for L2+/L3
        var countedBuckets: Set<Int> = []

        init() {}
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    /// Per-patch tracking state
    private var patchStates: [String: PatchState] = [:]

    /// Maximum records per patch
    private let maxRecordsPerPatch: Int = HardGatesV13.maxRecordsPerPatch

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init() {}

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Recording
    // ═══════════════════════════════════════════════════════════════════════

    /// Record a view observation
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - direction: Normalized direction vector (from camera to patch)
    ///   - pr3Quality: PR3 internal quality (for L2+/L3 classification)
    ///   - frameIndex: Frame index (for deterministic eviction)
    public func recordObservation(
        patchId: String,
        direction: EvidenceVector3,
        pr3Quality: Double,
        frameIndex: Int
    ) {
        // Normalize direction (defensive)
        let normalized = direction.normalized()
        guard normalized.isFinite() else { return }

        // Compute buckets using zero-trig methods
        let thetaBucket = ZeroTrigThetaBucketing.thetaBucketOptimized(
            dx: normalized.x,
            dz: normalized.z
        )
        let phiBucket = ZeroTrigPhiBucketing.phiBucket(dy: normalized.y)

        // Get or create patch state
        var state = patchStates[patchId] ?? PatchState()

        // Check if this is a new bucket (for L2+/L3 counting)
        let bucketKey = thetaBucket * 100 + phiBucket  // Unique key for (theta, phi) pair
        let isNewBucket = !state.countedBuckets.contains(bucketKey)

        // Insert into bitsets
        state.thetaBuckets.insert(thetaBucket)
        state.phiBuckets.insert(phiBucket)

        // Add record
        let record = ViewRecord(
            frameIndex: frameIndex,
            thetaBucket: thetaBucket,
            phiBucket: phiBucket,
            pr3Quality: pr3Quality
        )
        state.records.append(record)

        // Update L2+/L3 counts only if new bucket
        if isNewBucket {
            state.countedBuckets.insert(bucketKey)
            if PR3InternalQuality.isL2Plus(quality: pr3Quality) {
                state.l2PlusCount += 1
            }
            if PR3InternalQuality.isL3(quality: pr3Quality) {
                state.l3Count += 1
            }
        }

        // Deterministic eviction: remove oldest by frameIndex if over limit
        if state.records.count > maxRecordsPerPatch {
            // Find oldest record (minimum frameIndex)
            if let oldestIndex = state.records.enumerated().min(by: { $0.element.frameIndex < $1.element.frameIndex })?.offset {
                let removed = state.records.remove(at: oldestIndex)

                // Update bitsets: check if bucket is still used
                var thetaStillUsed = false
                var phiStillUsed = false
                for rec in state.records {
                    if rec.thetaBucket == removed.thetaBucket {
                        thetaStillUsed = true
                    }
                    if rec.phiBucket == removed.phiBucket {
                        phiStillUsed = true
                    }
                }

                // Clear bucket bits if not used
                if !thetaStillUsed {
                    // Note: Bitset doesn't have remove, so we rebuild
                    var newThetaBitset = ThetaBucketBitset()
                    for rec in state.records {
                        newThetaBitset.insert(rec.thetaBucket)
                    }
                    state.thetaBuckets = newThetaBitset
                }

                if !phiStillUsed {
                    var newPhiBitset = PhiBucketBitset()
                    for rec in state.records {
                        newPhiBitset.insert(rec.phiBucket)
                    }
                    state.phiBuckets = newPhiBitset
                }

                // Remove from counted buckets if bucket no longer exists
                let removedBucketKey = removed.thetaBucket * 100 + removed.phiBucket
                var bucketStillExists = false
                for rec in state.records {
                    let key = rec.thetaBucket * 100 + rec.phiBucket
                    if key == removedBucketKey {
                        bucketStillExists = true
                        break
                    }
                }
                if !bucketStillExists {
                    state.countedBuckets.remove(removedBucketKey)
                    // Decrement counts if removed record was L2+/L3
                    if PR3InternalQuality.isL2Plus(quality: removed.pr3Quality) {
                        state.l2PlusCount = max(0, state.l2PlusCount - 1)
                    }
                    if PR3InternalQuality.isL3(quality: removed.pr3Quality) {
                        state.l3Count = max(0, state.l3Count - 1)
                    }
                }
            }
        }

        patchStates[patchId] = state
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Queries
    // ═══════════════════════════════════════════════════════════════════════

    /// Get view gain inputs for a patch
    ///
    /// - Parameter patchId: Patch identifier
    /// - Returns: Tuple of (thetaSpanDeg, phiSpanDeg, l2PlusCount, l3Count)
    public func viewGainInputs(for patchId: String) -> (
        thetaSpanDeg: Double,
        phiSpanDeg: Double,
        l2PlusCount: Int,
        l3Count: Int
    ) {
        guard let state = patchStates[patchId] else {
            return (0, 0, 0, 0)
        }

        // Compute spans using bitset
        let thetaSpanBuckets = CircularSpanBitset.computeSpanBuckets(state.thetaBuckets)
        let phiSpanBuckets = CircularSpanBitset.computeLinearSpanBuckets(state.phiBuckets)

        let thetaSpanDeg = CircularSpanBitset.spanToDegrees(
            thetaSpanBuckets,
            bucketSizeDeg: HardGatesV13.thetaBucketSizeDeg
        )
        let phiSpanDeg = CircularSpanBitset.spanToDegrees(
            phiSpanBuckets,
            bucketSizeDeg: HardGatesV13.phiBucketSizeDeg
        )

        return (thetaSpanDeg, phiSpanDeg, state.l2PlusCount, state.l3Count)
    }

    /// Reset tracking for a patch
    ///
    /// - Parameter patchId: Patch identifier
    public func reset(patchId: String) {
        patchStates.removeValue(forKey: patchId)
    }

    /// Reset all tracking
    public func resetAll() {
        patchStates.removeAll()
    }
}
