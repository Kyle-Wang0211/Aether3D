// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MerkleTree.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Core Merkle Tree Implementation
//
// **Standard:** RFC 9162
//

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// RFC 9162 Merkle tree implementation
///
/// **Standard:** RFC 9162 Certificate Transparency Version 2.0
/// **Domain Separation:** 0x00 for leaf, 0x01 for interior node
///
/// **Invariants:**
/// - INV-C1: SHA-256 (32 bytes)
/// - INV-C6: RFC 9162 domain separation
/// - INV-A1: Actor isolation
public actor MerkleTree {
    /// Current tree size (number of leaves)
    public private(set) var size: UInt64 = 0
    
    /// Current root hash (32 bytes)
    public private(set) var rootHash: Data = Data(repeating: 0, count: 32)
    
    /// Leaf hashes (for proof generation)
    private var leaves: [Data] = []

    #if canImport(CAetherNativeBridge)
    nonisolated(unsafe) private var nativeTree: OpaquePointer?
    #endif

    public init() {
        #if canImport(CAetherNativeBridge)
        var tree: OpaquePointer?
        if aether_merkle_tree_create(&tree) == 0 {
            nativeTree = tree
        }
        #endif
    }

    deinit {
        #if canImport(CAetherNativeBridge)
        if let tree = nativeTree {
            _ = aether_merkle_tree_destroy(tree)
            nativeTree = nil
        }
        #endif
    }
    
    /// Append a leaf to the tree
    ///
    /// - Parameter leafData: Leaf data bytes
    public func append(_ leafData: Data) {
        #if canImport(CAetherNativeBridge)
        if let tree = nativeTree {
            let rc = leafData.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self).baseAddress
                return aether_merkle_tree_append(tree, bytes, Int32(leafData.count))
            }
            if rc == 0 {
                refreshNativeState()
            }
            return
        }
        #endif

        let leafHash = MerkleTreeHash.hashLeaf(leafData)
        leaves.append(leafHash)
        size += 1
        rootHash = computeRoot()
    }
    
    /// Append a leaf hash directly (if already hashed)
    ///
    /// - Parameter leafHash: Pre-computed leaf hash (32 bytes)
    public func appendHash(_ leafHash: Data) {
        guard leafHash.count == 32 else { return }
        #if canImport(CAetherNativeBridge)
        if let tree = nativeTree {
            var hash = [UInt8](leafHash)
            let rc = aether_merkle_tree_append_hash(tree, &hash)
            if rc == 0 {
                refreshNativeState()
            }
            return
        }
        #endif

        leaves.append(leafHash)
        size += 1
        rootHash = computeRoot()
    }
    
    /// Generate inclusion proof for a leaf
    ///
    /// - Parameter leafIndex: Index of leaf (0-based)
    /// - Returns: InclusionProof
    /// - Throws: MerkleTreeError if index is invalid
    public func generateInclusionProof(leafIndex: UInt64) throws -> InclusionProof {
        #if canImport(CAetherNativeBridge)
        if let tree = nativeTree {
            var proof = aether_merkle_inclusion_proof_t()
            let rc = aether_merkle_tree_inclusion_proof(tree, leafIndex, &proof)
            guard rc == 0 else {
                throw MerkleTreeError.invalidLeafIndex(index: leafIndex, treeSize: size)
            }
            let path = decodeHashPath(
                tuple: proof.path_hashes,
                count: Int(proof.path_length),
                maxHashes: Int(AETHER_MERKLE_MAX_INCLUSION_HASHES)
            )
            return InclusionProof(
                treeSize: proof.tree_size,
                leafIndex: proof.leaf_index,
                path: path.reversed()
            )
        }
        #endif

        guard leafIndex < size else {
            throw MerkleTreeError.invalidLeafIndex(index: leafIndex, treeSize: size)
        }
        
        var path: [Data] = []
        var currentIndex = leafIndex
        var currentLevel = leaves
        var remaining = size
        
        while remaining > 1 {
            if currentIndex % 2 == 0 {
                // Left child - need right sibling
                if currentIndex + 1 < remaining {
                    path.append(currentLevel[Int(currentIndex + 1)])
                }
            } else {
                // Right child - need left sibling
                path.append(currentLevel[Int(currentIndex - 1)])
            }
            
            // Move to parent level
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: remaining, by: 2) {
                if i + 1 < remaining {
                    nextLevel.append(MerkleTreeHash.hashNodes(currentLevel[Int(i)], currentLevel[Int(i + 1)]))
                } else {
                    nextLevel.append(currentLevel[Int(i)])
                }
            }
            currentLevel = nextLevel
            currentIndex /= 2
            remaining = (remaining + 1) / 2
        }
        
        return InclusionProof(
            treeSize: size,
            leafIndex: leafIndex,
            path: path.reversed() // Reverse to go from leaf to root
        )
    }
    
    /// Generate consistency proof between two tree sizes
    ///
    /// - Parameters:
    ///   - firstSize: First tree size
    ///   - secondSize: Second tree size
    /// - Returns: ConsistencyProof
    /// - Throws: MerkleTreeError if sizes are invalid
    public func generateConsistencyProof(firstSize: UInt64, secondSize: UInt64) throws -> ConsistencyProof {
        #if canImport(CAetherNativeBridge)
        if let tree = nativeTree {
            var proof = aether_merkle_consistency_proof_t()
            let rc = aether_merkle_tree_consistency_proof(tree, firstSize, secondSize, &proof)
            guard rc == 0 else {
                throw MerkleTreeError.invalidTreeSize(first: firstSize, second: secondSize)
            }
            let path = decodeHashPath(
                tuple: proof.path_hashes,
                count: Int(proof.path_length),
                maxHashes: Int(AETHER_MERKLE_MAX_CONSISTENCY_HASHES)
            )
            return ConsistencyProof(
                firstTreeSize: proof.first_tree_size,
                secondTreeSize: proof.second_tree_size,
                path: path
            )
        }
        #endif

        guard firstSize <= secondSize, secondSize <= size else {
            throw MerkleTreeError.invalidTreeSize(first: firstSize, second: secondSize)
        }

        if firstSize == 0 {
            let secondRoot = computeRoot(from: Array(leaves.prefix(Int(secondSize))))
            return ConsistencyProof(firstTreeSize: firstSize, secondTreeSize: secondSize, path: [secondRoot])
        }

        let firstRoot = computeRoot(from: Array(leaves.prefix(Int(firstSize))))
        let secondRoot = computeRoot(from: Array(leaves.prefix(Int(secondSize))))
        return ConsistencyProof(
            firstTreeSize: firstSize,
            secondTreeSize: secondSize,
            path: [firstRoot, secondRoot]
        )
    }
    
    // MARK: - Private Helpers
    
    private func computeRoot() -> Data {
        return computeRoot(from: leaves)
    }

    private func computeRoot(from leafHashes: [Data]) -> Data {
        guard !leafHashes.isEmpty else {
            return Data(repeating: 0, count: 32)
        }
        
        var currentLevel = leafHashes
        while currentLevel.count > 1 {
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                if i + 1 < currentLevel.count {
                    nextLevel.append(MerkleTreeHash.hashNodes(currentLevel[i], currentLevel[i + 1]))
                } else {
                    nextLevel.append(currentLevel[i])
                }
            }
            currentLevel = nextLevel
        }
        
        return currentLevel[0]
    }

    #if canImport(CAetherNativeBridge)
    private func refreshNativeState() {
        guard let tree = nativeTree else { return }

        var nativeSize: UInt64 = 0
        if aether_merkle_tree_size(tree, &nativeSize) == 0 {
            size = nativeSize
        }

        var nativeRoot = [UInt8](repeating: 0, count: Int(AETHER_MERKLE_HASH_BYTES))
        if aether_merkle_tree_root_hash(tree, &nativeRoot) == 0 {
            rootHash = Data(nativeRoot)
        }
    }

    private func decodeHashPath<T>(tuple: T, count: Int, maxHashes: Int) -> [Data] {
        guard count >= 0 && count <= maxHashes else { return [] }
        return withUnsafeBytes(of: tuple) { raw in
            var path: [Data] = []
            path.reserveCapacity(count)
            let bytesPerHash = Int(AETHER_MERKLE_HASH_BYTES)
            for index in 0..<count {
                let start = index * bytesPerHash
                let end = start + bytesPerHash
                guard end <= raw.count else { break }
                path.append(Data(raw[start..<end]))
            }
            return path
        }
    }
    #endif
}
