//
// InclusionProof.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Inclusion Proof
//
// **Standard:** RFC 9162 Section 2.1.3
//

import Foundation

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
        
        var currentHash = leafHash
        var currentIndex = leafIndex
        var remaining = treeSize
        
        for siblingHash in path {
            guard siblingHash.count == 32 else { return false }
            
            if currentIndex % 2 == 0 {
                // Current is left child
                if currentIndex + 1 < remaining {
                    currentHash = MerkleTreeHash.hashNodes(currentHash, siblingHash)
                }
            } else {
                // Current is right child
                currentHash = MerkleTreeHash.hashNodes(siblingHash, currentHash)
            }
            currentIndex /= 2
            remaining = (remaining + 1) / 2
        }
        
        return currentHash == rootHash
    }
}
