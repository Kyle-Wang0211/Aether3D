// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MemoryPressureHandler.swift
// Aether3D
//
// PR2 Patch V4 - Memory Pressure Handler
// Graceful degradation under memory pressure
//

import Foundation

/// Memory pressure handler for evidence system
public final class MemoryPressureHandler {
    
    /// Maximum patch count before pruning
    public static let maxPatchCount: Int = 10000
    
    /// Patches to keep on prune
    public static let keepPatchCount: Int = 5000
    
    /// Trim policy priority
    public enum TrimPriority {
        case lowestEvidence
        case oldestLastUpdate
        case lowestDiversity
        case notLocked
    }
    
    /// Handle memory pressure
    /// - Parameters:
    ///   - ledger: SplitLedger to trim
    ///   - aggregator: BucketedAmortizedAggregator to recalibrate
    ///   - currentTime: Current timestamp
    public static func handleMemoryPressure(
        ledger: SplitLedger,
        aggregator: BucketedAmortizedAggregator,
        currentTime: TimeInterval
    ) {
        let patchCount = ledger.totalPatchCount()
        
        if patchCount > maxPatchCount {
            // Prune oldest, lowest-evidence patches
            ledger.prunePatches(
                keepCount: keepPatchCount,
                strategy: .lowestEvidence
            )
            
            // Recalibrate aggregator
            let patches = ledger.allPatchesForRecalibration(currentTime: currentTime)
            aggregator.recalibrate(patches: patches, currentTime: currentTime)
            
            EvidenceLogger.warn("Pruned patches due to memory pressure: \(patchCount) -> \(keepPatchCount)")
        }
    }
}

// SplitLedger methods are now implemented in SplitLedger.swift
