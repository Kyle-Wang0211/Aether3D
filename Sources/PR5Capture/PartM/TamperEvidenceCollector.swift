// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TamperEvidenceCollector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 篡改证据收集，完整性校验链
//

import Foundation

/// Tamper evidence collector
///
/// Collects evidence of tampering with integrity verification chains.
/// Maintains tamper-evident logs.
public actor TamperEvidenceCollector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Evidence chain
    private var evidenceChain: [Evidence] = []
    
    /// Chain hash
    private var chainHash: String = ""
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Evidence Collection
    
    /// Collect tamper evidence
    public func collectEvidence(_ event: String, hash: String) -> CollectionResult {
        let evidence = Evidence(
            timestamp: Date(),
            event: event,
            hash: hash,
            previousHash: chainHash
        )
        
        evidenceChain.append(evidence)
        
        // Update chain hash
        let combined = chainHash + event + hash
        chainHash = String(combined.hash)
        
        // Keep only recent evidence (last 1000)
        if evidenceChain.count > 1000 {
            evidenceChain.removeFirst()
        }
        
        return CollectionResult(
            evidenceId: evidence.id,
            chainHash: chainHash,
            chainLength: evidenceChain.count
        )
    }
    
    /// Verify chain integrity
    public func verifyIntegrity() -> IntegrityResult {
        guard evidenceChain.count >= 2 else {
            return IntegrityResult(isValid: true, invalidIndices: [])
        }
        
        var invalidIndices: [Int] = []
        var expectedHash = ""
        
        for (index, evidence) in evidenceChain.enumerated() {
            if index > 0 && evidence.previousHash != expectedHash {
                invalidIndices.append(index)
            }
            
            let combined = expectedHash + evidence.event + evidence.hash
            expectedHash = String(combined.hash)
        }
        
        return IntegrityResult(
            isValid: invalidIndices.isEmpty,
            invalidIndices: invalidIndices
        )
    }
    
    // MARK: - Data Types
    
    /// Evidence
    public struct Evidence: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let event: String
        public let hash: String
        public let previousHash: String
        
        public init(id: UUID = UUID(), timestamp: Date, event: String, hash: String, previousHash: String) {
            self.id = id
            self.timestamp = timestamp
            self.event = event
            self.hash = hash
            self.previousHash = previousHash
        }
    }
    
    /// Collection result
    public struct CollectionResult: Sendable {
        public let evidenceId: UUID
        public let chainHash: String
        public let chainLength: Int
    }
    
    /// Integrity result
    public struct IntegrityResult: Sendable {
        public let isValid: Bool
        public let invalidIndices: [Int]
    }
}
