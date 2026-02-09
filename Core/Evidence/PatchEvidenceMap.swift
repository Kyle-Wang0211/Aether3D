// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PatchEvidenceMap.swift
// Aether3D
//
// PR2 Patch V4 - Patch Evidence Map (Complete Implementation)
// Per-patch ledger storage with deterministic updates
//

import Foundation

/// Patch evidence entry
public struct PatchEntry: Codable, Sendable {
    /// Current evidence value [0, 1] (clamped)
    @ClampedEvidence public var evidence: Double
    
    /// Last update timestamp (milliseconds)
    public var lastUpdateMs: Int64
    
    /// Observation count (for weight calculation)
    public var observationCount: Int
    
    /// Best observation frame ID
    public var bestFrameId: String?
    
    /// Total error count (for analytics)
    public var errorCount: Int
    
    /// Consecutive error streak (for penalty calculation)
    public var errorStreak: Int
    
    /// Last good (non-error) update timestamp (milliseconds, optional)
    public var lastGoodUpdateMs: Int64?
    
    /// Suspect observation count
    public var suspectCount: Int
    
    /// Whether patch is locked (computed property, not stored)
    public var isLocked: Bool {
        return EvidenceLocking.isLocked(
            evidence: evidence,
            observationCount: observationCount
        )
    }
    
    public init(
        evidence: Double = 0.0,
        lastUpdateMs: Int64 = 0,
        observationCount: Int = 0,
        bestFrameId: String? = nil,
        errorCount: Int = 0,
        errorStreak: Int = 0,
        lastGoodUpdateMs: Int64? = nil,
        suspectCount: Int = 0
    ) {
        self._evidence = ClampedEvidence(wrappedValue: evidence)
        self.lastUpdateMs = lastUpdateMs
        self.observationCount = observationCount
        self.bestFrameId = bestFrameId
        self.errorCount = errorCount
        self.errorStreak = errorStreak
        self.lastGoodUpdateMs = lastGoodUpdateMs
        self.suspectCount = suspectCount
    }
}

/// Patch entry update result
public struct PatchEntryUpdateResult: Sendable {
    /// Whether evidence was updated
    public let wasUpdated: Bool
    
    /// Previous evidence value
    public let previousEvidence: Double
    
    /// New evidence value
    public let newEvidence: Double
    
    /// Whether patch is now locked
    public let isLocked: Bool
}

/// Total evidence snapshot
public struct TotalEvidenceSnapshot: Sendable {
    public let totalEvidence: Double
    public let patchCount: Int
    public let weightedSum: Double
    public let totalWeight: Double
}

/// Patch-level evidence storage
public final class PatchEvidenceMap {
    
    /// Patch ID → Entry storage
    private var patches: [String: PatchEntry] = [:]
    
    /// Bucketed aggregator for O(k) total computation
    private var aggregator: BucketedAmortizedAggregator
    
    public init() {
        self.aggregator = BucketedAmortizedAggregator()
    }
    
    // MARK: - Read
    
    /// Get evidence for a specific patch
    public func evidence(for patchId: String) -> Double {
        return patches[patchId]?.evidence ?? 0.0
    }
    
    /// Get entry for patch
    public func entry(for patchId: String) -> PatchEntry? {
        return patches[patchId]
    }
    
    /// Get entry for patch (alias for compatibility)
    public func getEntry(for patchId: String) -> PatchEntry? {
        return entry(for: patchId)
    }
    
    /// Get all patch IDs (deterministic sorted order)
    public var allPatchIds: [String] {
        return patches.keys.sorted()
    }
    
    /// Get all entries sorted by patch ID (deterministic)
    public func allEntriesSnapshotSorted() -> [PatchEntry] {
        return patches.sorted { $0.key < $1.key }.map { $0.value }
    }
    
    // MARK: - Write
    
    /// Update patch evidence with gradual penalty for errors
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - ledgerQuality: Quality from Gate/Soft (NOT observation.quality)
    ///   - verdict: Observation verdict (good/suspect/bad/unknown)
    ///   - frameId: Source frame ID
    ///   - timestampMs: Current timestamp in milliseconds
    ///   - errorType: Error type (if applicable)
    /// - Returns: Update result
    @discardableResult
    public func update(
        patchId: String,
        ledgerQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestampMs: Int64,
        errorType: ObservationErrorType? = nil
    ) -> PatchEntryUpdateResult {
        var entry = patches[patchId] ?? PatchEntry(lastUpdateMs: timestampMs)
        
        let previousEvidence = entry.evidence
        let wasLockedBefore = entry.isLocked
        
        // Handle unknown verdict as suspect
        let effectiveVerdict: ObservationVerdict
        if verdict == .unknown {
            effectiveVerdict = .suspect
            EvidenceLogger.warn("Unknown verdict treated as suspect for patch \(patchId)")
        } else {
            effectiveVerdict = verdict
        }
        
        // Check locking FIRST (V4: locking only affects ledger, not display)
        if entry.isLocked {
            // LOCKED: Only allow increases, no penalties
            switch effectiveVerdict {
            case .good:
                if ledgerQuality > entry.evidence {
                    entry.evidence = ledgerQuality
                    entry.bestFrameId = frameId
                    entry.lastGoodUpdateMs = timestampMs
                }
                entry.errorStreak = 0
            case .suspect, .bad:
                // Record but don't penalize (V4: locking only protects ledger)
                entry.suspectCount += 1
                if effectiveVerdict == .bad {
                    entry.errorCount += 1
                }
            case .unknown:
                entry.suspectCount += 1
            }
            
            entry.lastUpdateMs = timestampMs
            entry.observationCount += 1
            patches[patchId] = entry
            
            // Update aggregator
            let weight = computeBaseWeight(entry: entry, timestampMs: timestampMs)
            aggregator.updatePatch(
                patchId: patchId,
                evidence: entry.evidence,
                baseWeight: weight,
                timestamp: Double(timestampMs) / 1000.0
            )
            
            return PatchEntryUpdateResult(
                wasUpdated: entry.evidence > previousEvidence,
                previousEvidence: previousEvidence,
                newEvidence: entry.evidence,
                isLocked: true
            )
        }
        
        // Normal (unlocked) update logic
        switch effectiveVerdict {
        case .good:
            // Reset error streak, update evidence if better
            entry.errorStreak = 0
            entry.lastGoodUpdateMs = timestampMs
            
            if ledgerQuality > entry.evidence {
                entry.evidence = ledgerQuality
                entry.bestFrameId = frameId
            }
            
        case .suspect:
            // Don't penalize, but don't reset error streak
            // Just record the observation (for analytics)
            entry.suspectCount += 1
            
        case .bad:
            // Apply gradual penalty with cooldown
            entry.errorStreak += 1
            entry.errorCount += 1
            
            let penalty = computePenalty(
                errorStreak: entry.errorStreak,
                lastGoodUpdateMs: entry.lastGoodUpdateMs,
                currentTimeMs: timestampMs
            )
            
            entry.evidence = max(0.0, entry.evidence - penalty)
            
        case .unknown:
            // Treat as suspect
            entry.suspectCount += 1
        }
        
        entry.lastUpdateMs = timestampMs
        entry.observationCount += 1
        patches[patchId] = entry
        
        // Update aggregator
        let weight = computeBaseWeight(entry: entry, timestampMs: timestampMs)
        aggregator.updatePatch(
            patchId: patchId,
            evidence: entry.evidence,
            baseWeight: weight,
            timestamp: Double(timestampMs) / 1000.0
        )
        
        return PatchEntryUpdateResult(
            wasUpdated: entry.evidence != previousEvidence,
            previousEvidence: previousEvidence,
            newEvidence: entry.evidence,
            isLocked: entry.isLocked
        )
    }
    
    /// Convenience update using TimeInterval
    public func update(
        patchId: String,
        ledgerQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestamp: TimeInterval,
        errorType: ObservationErrorType? = nil
    ) -> PatchEntryUpdateResult {
        let timestampMs = Int64(timestamp * 1000.0)
        return update(
            patchId: patchId,
            ledgerQuality: ledgerQuality,
            verdict: verdict,
            frameId: frameId,
            timestampMs: timestampMs,
            errorType: errorType
        )
    }
    
    // MARK: - Aggregation
    
    /// Compute weighted totals with decay
    /// Uses BucketedAmortizedAggregator for O(k) performance
    public func weightedTotals(
        nowMs: Int64,
        decay: ConfidenceDecay.Type = ConfidenceDecay.self,
        weightComputer: PatchWeightComputer.Type = PatchWeightComputer.self,
        aggregator: BucketedAmortizedAggregator? = nil
    ) -> TotalEvidenceSnapshot {
        let agg = aggregator ?? self.aggregator
        
        // Recalibrate periodically (every 60s or when bucket count exceeds max)
        // For now, always use current aggregator state
        // TODO: Add periodic recalibration trigger
        
        let totalEvidence = agg.totalEvidence
        
        return TotalEvidenceSnapshot(
            totalEvidence: totalEvidence,
            patchCount: patches.count,
            weightedSum: 0.0,  // Not exposed by aggregator
            totalWeight: 0.0   // Not exposed by aggregator
        )
    }
    
    /// Total evidence (convenience method)
    public func totalEvidence(currentTime: TimeInterval) -> Double {
        let nowMs = Int64(currentTime * 1000.0)
        return weightedTotals(nowMs: nowMs).totalEvidence
    }
    
    // MARK: - Pruning
    
    /// Prune patches based on strategy
    public func prunePatches(keepCount: Int, strategy: MemoryPressureHandler.TrimPriority) {
        guard patches.count > keepCount else { return }
        
        let sortedEntries: [(String, PatchEntry)]
        
        switch strategy {
        case .lowestEvidence:
            sortedEntries = patches.sorted { $0.value.evidence < $1.value.evidence }
        case .oldestLastUpdate:
            sortedEntries = patches.sorted { $0.value.lastUpdateMs < $1.value.lastUpdateMs }
        case .lowestDiversity:
            // Default to lowest evidence if diversity not available
            sortedEntries = patches.sorted { $0.value.evidence < $1.value.evidence }
        case .notLocked:
            // First remove non-locked, then by evidence
            sortedEntries = patches.sorted { entry1, entry2 in
                let locked1 = entry1.value.isLocked
                let locked2 = entry2.value.isLocked
                if locked1 != locked2 {
                    return !locked1  // Non-locked first
                }
                return entry1.value.evidence < entry2.value.evidence
            }
        }
        
        // Keep top N
        let toKeep = sortedEntries.suffix(keepCount)
        let keepIds = Set(toKeep.map { $0.0 })
        
        // Remove others
        patches = patches.filter { keepIds.contains($0.key) }
        
        // Recalibrate aggregator
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let patchesForRecal = allPatchesForRecalibration(currentTimeMs: nowMs)
        aggregator.recalibrate(patches: patchesForRecal, currentTime: Double(nowMs) / 1000.0)
    }
    
    /// Get all patches for recalibration
    public func allPatchesForRecalibration(currentTimeMs: Int64) -> [(patchId: String, evidence: Double, weight: Double, lastUpdate: TimeInterval)] {
        var result: [(patchId: String, evidence: Double, weight: Double, lastUpdate: TimeInterval)] = []
        
        for (patchId, entry) in patches {
            let weight = computeBaseWeight(entry: entry, timestampMs: currentTimeMs)
            result.append((
                patchId: patchId,
                evidence: entry.evidence,
                weight: weight,
                lastUpdate: Double(entry.lastUpdateMs) / 1000.0
            ))
        }
        
        return result
    }
    
    // MARK: - Private Helpers
    
    /// Compute base weight (frequency cap only, decay applied separately)
    private func computeBaseWeight(entry: PatchEntry, timestampMs: Int64) -> Double {
        // Frequency cap: min(1, observationCount / 8)
        let frequencyWeight = min(1.0, Double(entry.observationCount) / EvidenceConstants.weightCapDenominator)
        
        // Note: Decay is applied by BucketedAmortizedAggregator, not here
        return frequencyWeight
    }
    
    /// Compute penalty using FrameRateIndependentPenalty
    private func computePenalty(
        errorStreak: Int,
        lastGoodUpdateMs: Int64?,
        currentTimeMs: Int64
    ) -> Double {
        guard let lastGood = lastGoodUpdateMs else {
            return 0.0  // No good update, don't penalize
        }
        
        // Check cooldown (time-based, frame-rate independent)
        let lastGoodTime = Double(lastGood) / 1000.0
        let currentTime = Double(currentTimeMs) / 1000.0
        let age = currentTime - lastGoodTime
        
        // CORPSE PROTECTION: If patch hasn't been updated in a long time (>10s),
        // don't penalize it (it's effectively "dead" and shouldn't be penalized retroactively)
        let corpseProtectionThreshold: Double = 10.0  // seconds
        if age > corpseProtectionThreshold {
            return 0.0  // Patch is stale, don't penalize
        }
        
        // Check cooldown window
        if !FrameRateIndependentPenalty.isCooldownElapsed(
            lastPenaltyTime: lastGoodTime,
            currentTime: currentTime
        ) {
            return 0.0  // Still in cooldown
        }
        
        // Scale penalty by streak (but cap per-second rate)
        let streakMultiplier = min(3.0, 1.0 + Double(errorStreak) * 0.2)
        let basePenalty = FrameRateIndependentPenalty.basePenaltyPerObservation
        let maxPerFrame = FrameRateIndependentPenalty.maxPenaltyPerSecond / FrameRateIndependentPenalty.currentFrameRate
        
        return min(basePenalty * streakMultiplier, maxPerFrame)
    }
    
    /// Reset all patches
    public func reset() {
        patches.removeAll()
        aggregator = BucketedAmortizedAggregator()
    }
}

/// Evidence locking configuration
public enum EvidenceLocking {
    
    /// Evidence threshold for locking
    public static let lockThreshold: Double = EvidenceConstants.lockThreshold
    
    /// Minimum observations for locking
    public static let minObservationsForLock: Int = EvidenceConstants.minObservationsForLock
    
    /// Check if patch should be locked
    public static func isLocked(evidence: Double, observationCount: Int) -> Bool {
        return evidence >= lockThreshold && observationCount >= minObservationsForLock
    }
}
