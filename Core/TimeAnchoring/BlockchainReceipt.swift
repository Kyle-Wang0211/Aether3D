// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BlockchainReceipt.swift
// Aether3D
//
// Phase 1: Time Anchoring - OpenTimestamps Blockchain Receipt
//
// **Protocol:** OpenTimestamps (opentimestamps.org)
//

import Foundation

/// OpenTimestamps blockchain receipt
///
/// **Protocol:** OpenTimestamps
/// **Blockchain:** Bitcoin (primary), Ethereum (optional)
///
/// **Invariants:**
/// - INV-C1: Hash must be SHA-256 (32 bytes)
/// - INV-C2: All numeric encoding is Big-Endian
public struct BlockchainReceipt: Codable, Sendable {
    /// Hash that was anchored
    public let hash: Data
    
    /// OpenTimestamps proof (binary format)
    public let otsProof: Data
    
    /// Submission timestamp (local)
    public let submittedAt: Date
    
    /// Anchor status
    public let status: AnchorStatus
    
    /// Bitcoin block height (if confirmed)
    public var bitcoinBlockHeight: UInt64?
    
    /// Bitcoin transaction ID (if confirmed)
    public var bitcoinTxId: String?
    
    /// Anchor status enumeration
    public enum AnchorStatus: String, Codable, Sendable {
        case pending
        case confirmed
        case failed
    }
}
