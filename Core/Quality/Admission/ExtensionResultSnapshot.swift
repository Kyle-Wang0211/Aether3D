// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ExtensionResultSnapshot.swift
// Aether3D
//
// PR1 v2.4 Addendum - Extension Result Snapshot for Idempotency
//
// Canonical bytes encode ONLY original snapshot {extended, denied}
// Public API may return alreadyProcessed(originalSnapshot), but canonical bytes MUST equal originalSnapshot bytes
//

import Foundation

/// Extension result snapshot (for idempotency)
/// 
/// **P0 Contract:**
/// - canonicalBytesForIdempotency() encodes ONLY original snapshot {extended, denied}
/// - Public API may return alreadyProcessed(originalSnapshot), but canonical bytes MUST equal originalSnapshot bytes
/// - resultTag: 0=extended, 1=denied (does NOT include alreadyProcessed)
public struct ExtensionResultSnapshot {
    /// Extension request ID
    public let extensionRequestId: UUID
    
    /// Trigger enum value
    public let trigger: UInt8
    
    /// Tier ID
    public let tierId: UInt16
    
    /// Schema version
    public let schemaVersion: UInt16
    
    /// Policy hash
    public let policyHash: UInt64
    
    /// Extension count
    public let extensionCount: UInt8
    
    /// Result tag (0=extended, 1=denied)
    public let resultTag: UInt8
    
    /// Denial reason tag (0=absent, 1=present)
    public let denialReasonTag: UInt8
    
    /// Denial reason (only if denialReasonTag==1)
    public let denialReason: UInt8?
    
    /// EEB ceiling
    public let eebCeiling: Int64
    
    /// EEB added
    public let eebAdded: Int64
    
    /// New EEB remaining (only meaningful if extended; otherwise encode 0)
    public let newEebRemaining: Int64
    
    /// Initialize extension result snapshot
    public init(
        extensionRequestId: UUID,
        trigger: UInt8,
        tierId: UInt16,
        schemaVersion: UInt16,
        policyHash: UInt64,
        extensionCount: UInt8,
        resultTag: UInt8,
        denialReasonTag: UInt8,
        denialReason: UInt8?,
        eebCeiling: Int64,
        eebAdded: Int64,
        newEebRemaining: Int64
    ) {
        self.extensionRequestId = extensionRequestId
        self.trigger = trigger
        self.tierId = tierId
        self.schemaVersion = schemaVersion
        self.policyHash = policyHash
        self.extensionCount = extensionCount
        self.resultTag = resultTag
        self.denialReasonTag = denialReasonTag
        self.denialReason = denialReason
        self.eebCeiling = eebCeiling
        self.eebAdded = eebAdded
        self.newEebRemaining = newEebRemaining
    }
    
    /// Generate canonical bytes for idempotency (ExtensionRequestIdempotencySnapshotBytesLayout_v1)
    /// 
    /// **P0 Contract:**
    /// - Encodes ONLY original snapshot {extended, denied}
    /// - Does NOT encode API wrapper "alreadyProcessed"
    /// - resultTag: 0=extended, 1=denied (does NOT include alreadyProcessed=2)
    /// - Byte-stable: same snapshot => same bytes
    /// 
    /// **Fail-closed:** Throws FailClosedError on encoding failure
    public func canonicalBytesForIdempotency() throws -> Data {
        let writer = CanonicalBytesWriter()
        
        // Layout version (fixed as 1 for v1)
        writer.writeUInt8(1) // layoutVersion = 1
        
        // Extension request ID (RFC4122 network order)
        try writer.writeUUIDRfc4122(extensionRequestId)
        
        // Trigger
        writer.writeUInt8(trigger)
        
        // Tier ID
        writer.writeUInt16BE(tierId)
        
        // Schema version
        writer.writeUInt16BE(schemaVersion)
        
        // Policy hash
        writer.writeUInt64BE(policyHash)
        
        // Extension count
        writer.writeUInt8(extensionCount)
        
        // Result tag (0=extended, 1=denied; does NOT include alreadyProcessed=2)
        writer.writeUInt8(resultTag)
        
        // Denial reason tag (0=absent, 1=present)
        writer.writeUInt8(denialReasonTag)
        
        // Denial reason (only if denialReasonTag==1)
        if denialReasonTag == 1, let reason = denialReason {
            writer.writeUInt8(reason)
        }
        
        // EEB ceiling
        writer.writeInt64BE(eebCeiling)
        
        // EEB added
        writer.writeInt64BE(eebAdded)
        
        // New EEB remaining
        writer.writeInt64BE(newEebRemaining)
        
        // Reserved padding (4 bytes, must be zeros)
        writer.writeZeroBytes(count: 4)
        
        return writer.toData()
    }
}

/// Extension result wrapper (for public API)
/// 
/// **P0 Contract:**
/// - Public API may return alreadyProcessed(originalSnapshot)
/// - canonicalBytesForIdempotency() from originalSnapshot MUST equal first call bytes
public enum ExtensionResult {
    /// Extended (original snapshot)
    case extended(ExtensionResultSnapshot)
    
    /// Denied (original snapshot)
    case denied(ExtensionResultSnapshot)
    
    /// Already processed (wraps original snapshot)
    /// 
    /// **P0 Contract:**
    /// - originalSnapshot.canonicalBytesForIdempotency() MUST equal first call bytes
    case alreadyProcessed(originalSnapshot: ExtensionResultSnapshot)
    
    /// Get original snapshot (for idempotency bytes)
    public var originalSnapshot: ExtensionResultSnapshot {
        switch self {
        case .extended(let snapshot), .denied(let snapshot), .alreadyProcessed(let snapshot):
            return snapshot
        }
    }
    
    /// Get canonical bytes for idempotency
    /// 
    /// **P0 Contract:**
    /// - Always returns originalSnapshot.canonicalBytesForIdempotency()
    /// - Byte-stable: same originalSnapshot => same bytes (even if wrapped in alreadyProcessed)
    public func canonicalBytesForIdempotency() throws -> Data {
        return try originalSnapshot.canonicalBytesForIdempotency()
    }
}
