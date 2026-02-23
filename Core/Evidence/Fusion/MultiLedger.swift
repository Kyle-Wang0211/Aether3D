// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MultiLedger.swift
// Aether3D
//
// PR6 Evidence Grid System - Multi-Ledger
// Wraps SplitLedger and adds Provenance + Advanced ledgers
//

import Foundation

/// **Rule ID:** PR6_GRID_LEDGER_001
/// Multi-Ledger: 4-ledger wrapper (Gate + Soft + Provenance + Advanced)
/// Wraps existing SplitLedger without modifying it
public final class MultiLedger: @unchecked Sendable {
    
    /// Core ledger (Gate + Soft)
    private let splitLedger: SplitLedger
    
    /// Provenance ledger (new)
    public let provenanceLedger: PatchEvidenceMap
    
    /// Advanced ledger (new)
    public let advancedLedger: PatchEvidenceMap
    
    public init() {
        self.splitLedger = SplitLedger()
        self.provenanceLedger = PatchEvidenceMap()
        self.advancedLedger = PatchEvidenceMap()
    }
    
    /// **Rule ID:** PR6_GRID_LEDGER_002
    /// Update core ledgers (delegates to SplitLedger.update)
    public func updateCore(
        observation: EvidenceObservation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestamp: TimeInterval
    ) {
        splitLedger.update(
            observation: observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict,
            frameId: frameId,
            timestamp: timestamp
        )
    }
    
    /// **Rule ID:** PR6_GRID_LEDGER_003
    /// Update provenance ledger (new method)
    public func updateProvenance(
        patchId: String,
        provenanceQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestampMs: Int64,
        errorType: ObservationErrorType? = nil
    ) {
        provenanceLedger.update(
            patchId: patchId,
            ledgerQuality: provenanceQuality,
            verdict: verdict,
            frameId: frameId,
            timestampMs: timestampMs,
            errorType: errorType
        )
    }
    
    /// **Rule ID:** PR6_GRID_LEDGER_004
    /// Update advanced ledger (new method)
    public func updateAdvanced(
        patchId: String,
        advancedQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestampMs: Int64,
        errorType: ObservationErrorType? = nil
    ) {
        advancedLedger.update(
            patchId: patchId,
            ledgerQuality: advancedQuality,
            verdict: verdict,
            frameId: frameId,
            timestampMs: timestampMs,
            errorType: errorType
        )
    }
    
    /// Get patch evidence from core ledgers
    public func patchEvidence(for patchId: String, currentProgress: Double) -> Double {
        return splitLedger.patchEvidence(for: patchId, currentProgress: currentProgress)
    }
    
    /// Get total evidence from all ledgers
    public func totalEvidence(currentProgress: Double) -> (gate: Double, soft: Double, provenance: Double, advanced: Double, combined: Double) {
        let coreTotal = splitLedger.totalEvidence(currentProgress: currentProgress)
        
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let provenanceSnapshot = provenanceLedger.weightedTotals(nowMs: nowMs)
        let advancedSnapshot = advancedLedger.weightedTotals(nowMs: nowMs)
        
        let provenanceTotal = provenanceSnapshot.totalEvidence
        let advancedTotal = advancedSnapshot.totalEvidence
        
        // 4-way weight fusion (will use DynamicWeights.weights4)
        // For now, use equal weights
        let combined = (coreTotal.combined + provenanceTotal + advancedTotal) / 3.0
        
        return (coreTotal.gate, coreTotal.soft, provenanceTotal, advancedTotal, combined)
    }
}
