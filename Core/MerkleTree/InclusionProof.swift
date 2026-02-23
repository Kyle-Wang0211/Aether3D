// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// InclusionProof.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Inclusion Proof
//
// **Standard:** RFC 9162 Section 2.1.3
//

import Foundation
import CAetherNativeBridge

/// Merkle tree inclusion proof (O(log n) verification)
///
/// **Standard:** RFC 9162 Section 2.1.3
/// **Verification:** Recompute root from leaf hash and proof path
///
/// **Invariants:**
/// - INV-C6: RFC 9162 domain separation
public struct InclusionProof: Codable, Sendable {
    /// Tree size at proof generation
    public let treeSize: UInt64
    
    /// Index of the leaf being proven
    public let leafIndex: UInt64
    
    /// Sibling hashes along path to root
    public let path: [Data]
    
    /// Verify this proof
    ///
    /// **Algorithm:** RFC 9162 Section 2.1.3.2
    ///
    /// - Parameters:
    ///   - leafHash: Hash of the leaf data (with domain separation)
    ///   - rootHash: Expected tree root hash
    /// - Returns: true if proof is valid
    public func verify(leafHash: Data, rootHash: Data) -> Bool {
        guard leafIndex < treeSize else { return false }
        guard leafHash.count == 32, rootHash.count == 32 else { return false }
        guard path.count <= Int(AETHER_MERKLE_MAX_INCLUSION_HASHES) else { return false }

        var nativeProof = aether_merkle_inclusion_proof_t()
        nativeProof.tree_size = treeSize
        nativeProof.leaf_index = leafIndex
        nativeProof.path_length = UInt32(path.count)

        leafHash.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &nativeProof.leaf_hash) { dst in
                dst.copyBytes(from: raw.prefix(Int(AETHER_MERKLE_HASH_BYTES)))
            }
        }

        let orderedPath = path.reversed()
        withUnsafeMutableBytes(of: &nativeProof.path_hashes) { dst in
            var cursor = 0
            for hash in orderedPath {
                guard hash.count == Int(AETHER_MERKLE_HASH_BYTES) else { continue }
                let upper = cursor + Int(AETHER_MERKLE_HASH_BYTES)
                guard upper <= dst.count else { break }
                dst[cursor..<upper].copyBytes(from: hash)
                cursor = upper
            }
        }

        var expectedRoot = [UInt8](rootHash)
        var valid: Int32 = 0
        let rc = aether_merkle_verify_inclusion(&nativeProof, &expectedRoot, &valid)
        return rc == 0 && valid != 0
    }
}
