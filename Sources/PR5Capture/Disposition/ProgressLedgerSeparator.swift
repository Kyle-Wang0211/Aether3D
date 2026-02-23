// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ProgressLedgerSeparator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART D: 账本完整性增强
// 显示进度 vs 账本分离
//

import Foundation

/// Progress ledger separator
///
/// Separates display progress from ledger entries.
/// Ensures ledger integrity while allowing progress display.
public actor ProgressLedgerSeparator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Display progress (optimistic, for UI)
    private var displayProgress: [UInt64: Double] = [:]
    
    /// Ledger entries (pessimistic, for audit)
    private var ledgerEntries: [LedgerEntry] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Progress Management
    
    /// Update display progress
    ///
    /// Updates optimistic progress for UI display
    public func updateDisplayProgress(frameId: UInt64, progress: Double) {
        displayProgress[frameId] = progress
        
        // Keep only recent (last 100)
        if displayProgress.count > 100 {
            let sortedKeys = displayProgress.keys.sorted()
            for key in sortedKeys.prefix(displayProgress.count - 100) {
                displayProgress.removeValue(forKey: key)
            }
        }
    }
    
    /// Commit to ledger
    ///
    /// Commits verified progress to ledger (pessimistic)
    public func commitToLedger(
        frameId: UInt64,
        verifiedProgress: Double,
        proof: LedgerProof
    ) {
        let entry = LedgerEntry(
            frameId: frameId,
            progress: verifiedProgress,
            proof: proof,
            timestamp: Date()
        )
        
        ledgerEntries.append(entry)
        
        // Keep only recent entries (last 1000)
        if ledgerEntries.count > 1000 {
            ledgerEntries.removeFirst()
        }
    }
    
    // MARK: - Queries
    
    /// Get display progress
    public func getDisplayProgress(for frameId: UInt64) -> Double? {
        return displayProgress[frameId]
    }
    
    /// Get ledger entry
    public func getLedgerEntry(for frameId: UInt64) -> LedgerEntry? {
        return ledgerEntries.first { $0.frameId == frameId }
    }
    
    /// Get progress discrepancy
    ///
    /// Returns difference between display and ledger progress
    public func getProgressDiscrepancy(for frameId: UInt64) -> Double? {
        guard let display = displayProgress[frameId],
              let ledger = ledgerEntries.first(where: { $0.frameId == frameId }) else {
            return nil
        }
        
        return display - ledger.progress
    }
    
    // MARK: - Data Types
    
    /// Ledger proof
    public struct LedgerProof: Codable, Sendable {
        public let hash: String
        public let signature: Data?
        public let verifiedBy: String
        
        public init(hash: String, signature: Data? = nil, verifiedBy: String) {
            self.hash = hash
            self.signature = signature
            self.verifiedBy = verifiedBy
        }
    }
    
    /// Ledger entry
    public struct LedgerEntry: Sendable {
        public let frameId: UInt64
        public let progress: Double
        public let proof: LedgerProof
        public let timestamp: Date
    }
}
