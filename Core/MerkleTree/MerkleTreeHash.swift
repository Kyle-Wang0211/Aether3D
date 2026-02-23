// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MerkleTreeHash.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - RFC 9162 Hash Primitives
//
// **Standard:** RFC 9162 Certificate Transparency Version 2.0
// **Domain Separation:** 0x00 for leaf, 0x01 for interior node
//

import Foundation
import CAetherNativeBridge

/// RFC 9162 Merkle tree hash primitives
///
/// **Standard:** RFC 9162
/// **Domain Separation:**
/// - Leaf: SHA256(0x00 || leaf_bytes)
/// - Node: SHA256(0x01 || left_hash || right_hash)
///
/// **Invariants:**
/// - INV-C1: SHA-256 (32 bytes)
/// - INV-C6: RFC 9162 domain separation (0x00=leaf, 0x01=node)
public enum MerkleTreeHash {
    /// Domain separation prefix for leaf nodes (RFC 9162)
    public static let leafPrefix: UInt8 = 0x00
    
    /// Domain separation prefix for interior nodes (RFC 9162)
    public static let nodePrefix: UInt8 = 0x01
    
    /// Compute hash of a leaf entry (RFC 9162 domain separation)
    ///
    /// **Algorithm:** SHA256(0x00 || leaf_bytes)
    ///
    /// - Parameter data: Leaf data bytes
    /// - Returns: 32-byte hash
    public static func hashLeaf(_ data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(AETHER_MERKLE_HASH_BYTES))
        let rc = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            return aether_merkle_hash_leaf(bytes, Int32(data.count), &out)
        }
        precondition(rc == 0, "aether_merkle_hash_leaf failed: rc=\(rc)")
        return Data(out)
    }

    /// Compute hash of two child nodes (RFC 9162 domain separation)
    ///
    /// **Algorithm:** SHA256(0x01 || left_hash || right_hash)
    ///
    /// - Parameters:
    ///   - left: Left child hash (32 bytes)
    ///   - right: Right child hash (32 bytes)
    /// - Returns: 32-byte parent hash
    public static func hashNodes(_ left: Data, _ right: Data) -> Data {
        guard left.count == 32, right.count == 32 else {
            return Data(repeating: 0, count: 32)
        }
        var out = [UInt8](repeating: 0, count: Int(AETHER_MERKLE_HASH_BYTES))
        let rc = left.withUnsafeBytes { leftRaw in
            right.withUnsafeBytes { rightRaw in
                let leftPtr = leftRaw.bindMemory(to: UInt8.self).baseAddress
                let rightPtr = rightRaw.bindMemory(to: UInt8.self).baseAddress
                return aether_merkle_hash_nodes(leftPtr, rightPtr, &out)
            }
        }
        precondition(rc == 0, "aether_merkle_hash_nodes failed: rc=\(rc)")
        return Data(out)
    }
}
