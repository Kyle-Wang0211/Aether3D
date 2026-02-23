// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ConsistencyProof.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Consistency Proof
//
// **Standard:** RFC 9162 Section 2.1.4
//

import Foundation
import CAetherNativeBridge

/// Consistency proof for append-only log verification
///
/// **Standard:** RFC 9162 Section 2.1.4
/// **Purpose:** Prove tree at size N is prefix of tree at size M
///
/// **Invariants:**
/// - INV-C6: RFC 9162 domain separation
public struct ConsistencyProof: Codable, Sendable {
    /// First tree size
    public let firstTreeSize: UInt64
    
    /// Second tree size
    public let secondTreeSize: UInt64
    
    /// Proof path
    public let path: [Data]
    
    /// Verify consistency between two tree roots
    ///
    /// **Algorithm:** RFC 9162 Section 2.1.4.2
    ///
    /// - Parameters:
    ///   - firstRoot: Root hash of first tree
    ///   - secondRoot: Root hash of second tree
    /// - Returns: true if proof is valid
    public func verify(firstRoot: Data, secondRoot: Data) -> Bool {
        guard firstTreeSize <= secondTreeSize else { return false }
        guard firstRoot.count == 32, secondRoot.count == 32 else { return false }
        guard path.count <= Int(AETHER_MERKLE_MAX_CONSISTENCY_HASHES) else { return false }

        var nativeProof = aether_merkle_consistency_proof_t()
        nativeProof.first_tree_size = firstTreeSize
        nativeProof.second_tree_size = secondTreeSize
        nativeProof.path_length = UInt32(path.count)

        withUnsafeMutableBytes(of: &nativeProof.path_hashes) { dst in
            var cursor = 0
            for hash in path {
                guard hash.count == Int(AETHER_MERKLE_HASH_BYTES) else { continue }
                let upper = cursor + Int(AETHER_MERKLE_HASH_BYTES)
                guard upper <= dst.count else { break }
                dst[cursor..<upper].copyBytes(from: hash)
                cursor = upper
            }
        }

        var first = [UInt8](firstRoot)
        var second = [UInt8](secondRoot)
        var valid: Int32 = 0
        let rc = aether_merkle_verify_consistency(&nativeProof, &first, &second, &valid)
        return rc == 0 && valid != 0
    }
}
