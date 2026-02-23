// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MerkleTreeError.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Error Types
//

import Foundation

/// Errors for Merkle tree operations
///
/// **Fail-closed:** All errors are explicit
public enum MerkleTreeError: Error, Sendable {
    /// Invalid leaf index (out of bounds)
    case invalidLeafIndex(index: UInt64, treeSize: UInt64)
    
    /// Invalid tree size for consistency proof
    case invalidTreeSize(first: UInt64, second: UInt64)
    
    /// Proof verification failed
    case proofVerificationFailed(reason: String)
    
    /// Invalid hash length (must be 32 bytes)
    case invalidHashLength(expected: Int, actual: Int)
}
