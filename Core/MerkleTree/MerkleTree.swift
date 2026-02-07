//
// MerkleTree.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Core Merkle Tree Implementation
//
// **Standard:** RFC 9162
//

import Foundation

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
    
    /// Append a leaf to the tree
    ///
    /// - Parameter leafData: Leaf data bytes
    public func append(_ leafData: Data) {
        let leafHash = MerkleTreeHash.hashLeaf(leafData)
        leaves.append(leafHash)
        size += 1
        rootHash = computeRoot()
    }
    
    /// Append a leaf hash directly (if already hashed)
    ///
    /// - Parameter leafHash: Pre-computed leaf hash (32 bytes)
    public func appendHash(_ leafHash: Data) {
        guard leafHash.count == 32 else { fatalError("Leaf hash must be 32 bytes") }
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
    /// **Note:** This requires maintaining history. For now, returns error.
    ///
    /// - Parameters:
    ///   - firstSize: First tree size
    ///   - secondSize: Second tree size
    /// - Returns: ConsistencyProof
    /// - Throws: MerkleTreeError if sizes are invalid
    public func generateConsistencyProof(firstSize: UInt64, secondSize: UInt64) throws -> ConsistencyProof {
        guard firstSize <= secondSize, secondSize <= size else {
            throw MerkleTreeError.invalidTreeSize(first: firstSize, second: secondSize)
        }
        
        // TODO: Implement consistency proof generation
        // This requires maintaining historical tree states
        throw MerkleTreeError.proofVerificationFailed(reason: "Consistency proof not yet implemented")
    }
    
    // MARK: - Private Helpers
    
    private func computeRoot() -> Data {
        guard !leaves.isEmpty else {
            return Data(repeating: 0, count: 32)
        }
        
        var currentLevel = leaves
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
}
