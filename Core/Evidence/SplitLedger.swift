//
// SplitLedger.swift
// Aether3D
//
// PR2 Patch V4 - Split Ledger Architecture
// Separate Gate and Soft ledgers for semantic clarity
//

import Foundation

/// Split ledger architecture
/// Gate and Soft ledgers are separate to avoid semantic pollution
public final class SplitLedger {
    
    /// Gate ledger: stores reachability evidence
    public let gateLedger: PatchEvidenceMap
    
    /// Soft ledger: stores quality evidence
    public let softLedger: PatchEvidenceMap
    
    public init() {
        self.gateLedger = PatchEvidenceMap()
        self.softLedger = PatchEvidenceMap()
    }
    
    /// Update both ledgers with their respective qualities
    public func update(
        observation: EvidenceObservation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestamp: TimeInterval
    ) {
        let timestampMs = Int64(timestamp * 1000.0)
        
        // Gate ledger only receives gateQuality
        gateLedger.update(
            patchId: observation.patchId,
            ledgerQuality: gateQuality,
            verdict: verdict,
            frameId: frameId,
            timestampMs: timestampMs,
            errorType: observation.errorType
        )
        
        // Soft ledger only receives softQuality (with stricter write policy)
        // Soft ledger only writes if gateQuality is also decent
        if gateQuality > EvidenceConstants.softWriteRequiresGateMin {
            softLedger.update(
                patchId: observation.patchId,
                ledgerQuality: softQuality,
                verdict: verdict,
                frameId: frameId,
                timestampMs: timestampMs,
                errorType: observation.errorType
            )
        }
    }
    
    /// Compute patch evidence with dynamic weight fusion
    public func patchEvidence(for patchId: String, currentProgress: Double) -> Double {
        let gateEvidence = gateLedger.evidence(for: patchId)
        let softEvidence = softLedger.evidence(for: patchId)
        
        // Dynamic weights based on progress
        let (gateWeight, softWeight) = DynamicWeights.weights(currentTotal: currentProgress)
        
        return gateWeight * gateEvidence + softWeight * softEvidence
    }
    
    /// Total evidence across all patches
    public func totalEvidence(currentProgress: Double) -> (gate: Double, soft: Double, combined: Double) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        
        let gateSnapshot = gateLedger.weightedTotals(nowMs: nowMs)
        let softSnapshot = softLedger.weightedTotals(nowMs: nowMs)
        
        let gateTotal = gateSnapshot.totalEvidence
        let softTotal = softSnapshot.totalEvidence
        
        let (gateWeight, softWeight) = DynamicWeights.weights(currentTotal: currentProgress)
        let combined = gateWeight * gateTotal + softWeight * softTotal
        
        return (gateTotal, softTotal, combined)
    }
    
    /// Total patch count
    public func totalPatchCount() -> Int {
        let gatePatches = Set(gateLedger.allPatchIds)
        let softPatches = Set(softLedger.allPatchIds)
        return Set(gatePatches).union(softPatches).count
    }
    
    /// Prune patches
    public func prunePatches(keepCount: Int, strategy: MemoryPressureHandler.TrimPriority) {
        gateLedger.prunePatches(keepCount: keepCount, strategy: strategy)
        softLedger.prunePatches(keepCount: keepCount, strategy: strategy)
    }
    
    /// Get all patches for recalibration
    public func allPatchesForRecalibration(currentTime: TimeInterval) -> [(patchId: String, evidence: Double, weight: Double, lastUpdate: TimeInterval)] {
        let currentTimeMs = Int64(currentTime * 1000.0)
        
        // Get patches from gate ledger (primary)
        var gatePatches = gateLedger.allPatchesForRecalibration(currentTimeMs: currentTimeMs)
        
        // Merge with soft ledger patches (use max evidence)
        let softPatches = softLedger.allPatchesForRecalibration(currentTimeMs: currentTimeMs)
        var patchMap: [String: (evidence: Double, weight: Double, lastUpdate: TimeInterval)] = [:]
        
        for patch in gatePatches {
            patchMap[patch.patchId] = (patch.evidence, patch.weight, patch.lastUpdate)
        }
        
        for patch in softPatches {
            if let existing = patchMap[patch.patchId] {
                // Use max evidence, max weight
                patchMap[patch.patchId] = (
                    max(existing.evidence, patch.evidence),
                    max(existing.weight, patch.weight),
                    max(existing.lastUpdate, patch.lastUpdate)
                )
            } else {
                patchMap[patch.patchId] = (patch.evidence, patch.weight, patch.lastUpdate)
            }
        }
        
        return Array(patchMap.values).map { (patchId: "", evidence: $0.evidence, weight: $0.weight, lastUpdate: $0.lastUpdate) }
    }
    
    /// Export patches for serialization
    public func exportPatches() -> [String: PatchEntrySnapshot] {
        var result: [String: PatchEntrySnapshot] = [:]
        
        // Export gate ledger patches
        for (patchId, entry) in gateLedger.allEntriesSnapshotSorted().enumerated() {
            let snapshot = PatchEntrySnapshot(
                evidence: entry.evidence,
                lastUpdateMs: entry.lastUpdateMs,
                observationCount: entry.observationCount,
                bestFrameId: entry.bestFrameId,
                errorCount: entry.errorCount,
                errorStreak: entry.errorStreak,
                lastGoodUpdateMs: entry.lastGoodUpdateMs
            )
            result["gate_\(patchId)"] = snapshot
        }
        
        // Export soft ledger patches
        for (patchId, entry) in softLedger.allEntriesSnapshotSorted().enumerated() {
            let snapshot = PatchEntrySnapshot(
                evidence: entry.evidence,
                lastUpdateMs: entry.lastUpdateMs,
                observationCount: entry.observationCount,
                bestFrameId: entry.bestFrameId,
                errorCount: entry.errorCount,
                errorStreak: entry.errorStreak,
                lastGoodUpdateMs: entry.lastGoodUpdateMs
            )
            result["soft_\(patchId)"] = snapshot
        }
        
        return result
    }
}

// PatchEvidenceMap and PatchEntry are now implemented in PatchEvidenceMap.swift

// DynamicWeights is now implemented in DynamicWeights.swift
