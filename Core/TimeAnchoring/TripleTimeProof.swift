// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TripleTimeProof.swift
// Aether3D
//
// Phase 1: Time Anchoring - Triple Time Anchor Fusion Proof
//

import Foundation

/// Time interval structure (for Codable conformance)
public struct TimeIntervalNs: Codable, Sendable {
    public let lowerNs: UInt64
    public let upperNs: UInt64
    
    public init(lowerNs: UInt64, upperNs: UInt64) {
        self.lowerNs = lowerNs
        self.upperNs = upperNs
    }
}

/// Excluded evidence with rejection reason (for Codable conformance)
public struct ExcludedEvidence: Codable, Sendable {
    public let evidence: TimeEvidence
    public let reason: String
    
    public init(evidence: TimeEvidence, reason: String) {
        self.evidence = evidence
        self.reason = reason
    }
}

/// Triple time anchor fusion proof
///
/// **Strategy:** Multi-source fusion with Byzantine fault tolerance
/// **Minimum:** 2-of-3 agreement required for validity
///
/// **Invariants:**
/// - INV-C2: All time values use Big-Endian encoding
public struct TripleTimeProof: Codable, Sendable {
    /// Data hash that was anchored
    public let dataHash: Data
    
    /// Fused time interval: [lowerNs, upperNs]
    public let fusedTimeInterval: TimeIntervalNs
    
    /// Included evidences (at least 2)
    public let includedEvidences: [TimeEvidence]
    
    /// Excluded evidences with rejection reasons
    public let excludedEvidences: [ExcludedEvidence]
    
    /// Anchoring timestamp (local)
    public let anchoredAt: Date
    
    /// Number of included evidences
    public var evidenceCount: Int {
        return includedEvidences.count
    }
    
    /// Check if proof is valid (at least 2 evidences)
    public var isValid: Bool {
        return includedEvidences.count >= 2
    }
}
