//
// MerkleAuditLog.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Integration with Audit/Evidence Engine
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Import MonotonicClock from Quality module
// Note: This assumes MonotonicClock is accessible - may need to adjust import path

/// Merkle audit log combining SignedAuditLog with MerkleTree
///
/// **Purpose:** Enable O(log n) inclusion proof verification for audit entries
///
/// **Invariants:**
/// - INV-C1: SHA-256
/// - INV-C6: RFC 9162 domain separation
/// - INV-A1: Actor isolation
public actor MerkleAuditLog {
    private let merkleTree: MerkleTree
    private var entries: [Data] = [] // Entry hashes
    
    public init() {
        self.merkleTree = MerkleTree()
    }
    
    /// Append entry to both signed log and Merkle tree
    ///
    /// - Parameter entryHash: SHA-256 hash of audit entry (32 bytes)
    public func append(_ entryHash: Data) async throws {
        guard entryHash.count == 32 else {
            throw MerkleTreeError.invalidHashLength(expected: 32, actual: entryHash.count)
        }
        await merkleTree.appendHash(entryHash)
        entries.append(entryHash)
    }
    
    /// Generate inclusion proof for entry
    ///
    /// - Parameter entryIndex: Index of entry (0-based)
    /// - Returns: InclusionProof
    /// - Throws: MerkleTreeError if index is invalid
    public func generateInclusionProof(entryIndex: UInt64) async throws -> InclusionProof {
        return try await merkleTree.generateInclusionProof(leafIndex: entryIndex)
    }
    
    /// Get current Signed Tree Head
    ///
    /// - Parameter privateKey: Ed25519 private key for signing
    /// - Returns: SignedTreeHead
    /// - Throws: Error if signing fails
    public func getSignedTreeHead(privateKey: Curve25519.Signing.PrivateKey) async throws -> SignedTreeHead {
        let rootHash = await merkleTree.rootHash
        let treeSize = await merkleTree.size
        // Use MonotonicClock - it's in the same module (Core)
        let timestampNanos = UInt64(MonotonicClock.nowNs())
        
        return try SignedTreeHead.sign(
            treeSize: treeSize,
            rootHash: rootHash,
            timestampNanos: timestampNanos,
            privateKey: privateKey
        )
    }
    
    /// Get current tree size
    public var size: UInt64 {
        get async {
            await merkleTree.size
        }
    }
    
    /// Get current root hash
    public var rootHash: Data {
        get async {
            await merkleTree.rootHash
        }
    }
}
