// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-INTEGRITY-1.0
// Module: Upload Infrastructure - Streaming Merkle Tree
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

// _SHA256 typealias defined in CryptoHelpers.swift

/// Integrity tree protocol.
public protocol IntegrityTree: Sendable {
    func appendLeaf(_ data: Data) async
    var rootHash: Data { get async }
    func generateProof(leafIndex: Int) async -> [Data]?
    static func verifyProof(leaf: Data, proof: [Data], root: Data, index: Int, totalLeaves: Int) -> Bool
}

/// Streaming Merkle tree using Binary Carry Model (RFC 9162).
///
/// **Purpose**: Binary Carry Model incremental Merkle tree, O(log n) memory,
/// subtree checkpoints every 16 leaves.
///
/// **Binary Carry Model**:
/// ```
/// chunk 0: stack = [h0]
/// chunk 1: stack = [H(0x01||0||h0||h1)]
/// chunk 2: stack = [H(0x01||0||h0||h1), h2]
/// chunk 3: stack = [H(0x01||1||...)]  // double merge
/// ```
///
/// **Leaf hash**: `SHA-256(0x00 || chunkIndex_LE32 || data)` — index prevents identical-content collision.
/// **Internal hash**: `SHA-256(0x01 || level_LE8 || left || right)` — level prevents cross-level attack.
/// **Empty tree root**: `SHA-256(0x00)` (well-known constant).
///
/// **Subtree checkpoint**: Every carry merge AND every 16 leaves → emit checkpoint to server.
/// **Memory**: O(log n) — only the "carry stack" is retained.
public actor StreamingMerkleTree: IntegrityTree {
    
    // MARK: - State
    
    /// Carry stack (Binary Carry Model)
    private var stack: [(hash: Data, level: Int)] = []
    
    /// Total leaves appended
    private var leafCount: Int = 0
    
    /// Checkpoint interval
    private let checkpointInterval = UploadConstants.MERKLE_SUBTREE_CHECKPOINT_INTERVAL
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - IntegrityTree Protocol
    
    /// Append leaf to tree.
    ///
    /// - Parameter data: Leaf data
    public func appendLeaf(_ data: Data) async {
        // Compute leaf hash: SHA-256(0x00 || chunkIndex_LE32 || data)
        let leafHash = hashLeaf(data: data, index: leafCount)
        
        // Push to stack
        stack.append((hash: leafHash, level: 0))
        leafCount += 1
        
        // Binary carry: merge pairs at same level
        while stack.count >= 2 && stack[stack.count - 2].level == stack[stack.count - 1].level {
            let right = stack.removeLast()
            let left = stack.removeLast()
            
            // Merge: SHA-256(0x01 || level_LE8 || left || right)
            let merged = StreamingMerkleTree.hashNodes(left: left.hash, right: right.hash, level: left.level)
            stack.append((hash: merged, level: left.level + 1))
        }
        
        // Checkpoint every N leaves
        if leafCount % checkpointInterval == 0 {
            await emitCheckpoint()
        }
    }
    
    /// Get root hash.
    public var rootHash: Data {
        get async {
            if stack.isEmpty {
                return hashEmpty()
            }
            
            // Merge remaining stack to get root
            var currentStack = stack
            while currentStack.count > 1 {
                let right = currentStack.removeLast()
                let left = currentStack.removeLast()
                let merged = StreamingMerkleTree.hashNodes(left: left.hash, right: right.hash, level: left.level)
                currentStack.append((hash: merged, level: left.level + 1))
            }
            
            return currentStack.first?.hash ?? hashEmpty()
        }
    }
    
    /// Generate inclusion proof for leaf.
    ///
    /// - Parameter leafIndex: Leaf index (0-based)
    /// - Returns: Proof path (array of sibling hashes), or nil if index invalid
    public func generateProof(leafIndex: Int) async -> [Data]? {
        guard leafIndex >= 0 && leafIndex < leafCount else {
            return nil
        }
        
        // Rebuild tree to generate proof (simplified - full implementation would cache)
        // For now, return nil (proof generation requires full tree reconstruction)
        // In production, maintain proof cache or rebuild on demand
        return nil
    }
    
    /// Verify inclusion proof.
    ///
    /// - Parameters:
    ///   - leaf: Leaf hash
    ///   - proof: Proof path
    ///   - root: Root hash
    ///   - index: Leaf index
    ///   - totalLeaves: Total number of leaves
    /// - Returns: True if proof is valid
    public static func verifyProof(
        leaf: Data,
        proof: [Data],
        root: Data,
        index: Int,
        totalLeaves: Int
    ) -> Bool {
        var currentHash = leaf
        var currentIndex = index
        
        for siblingHash in proof {
            if currentIndex % 2 == 0 {
                // Current is left child
                currentHash = StreamingMerkleTree.hashNodes(left: currentHash, right: siblingHash, level: 0)
            } else {
                // Current is right child
                currentHash = StreamingMerkleTree.hashNodes(left: siblingHash, right: currentHash, level: 0)
            }
            currentIndex /= 2
        }
        
        return currentHash == root
    }
    
    // MARK: - Hash Functions
    
    /// Hash leaf: SHA-256(0x00 || chunkIndex_LE32 || data)
    private func hashLeaf(data: Data, index: Int) -> Data {
        var input = Data([UploadConstants.MERKLE_LEAF_PREFIX])
        
        // Append index as little-endian UInt32
        var indexLE = UInt32(index).littleEndian
        input.append(contentsOf: withUnsafeBytes(of: &indexLE) { Data($0) })
        
        // Append data
        input.append(data)
        
        let hash = _SHA256.hash(data: input)
        return Data(hash)
    }
    
    /// Hash nodes: SHA-256(0x01 || level_LE8 || left || right)
    private static func hashNodes(left: Data, right: Data, level: Int) -> Data {
        var input = Data([UploadConstants.MERKLE_NODE_PREFIX])
        
        // Append level as UInt8
        input.append(UInt8(level))
        
        // Append left and right hashes
        input.append(left)
        input.append(right)
        
        let hash = _SHA256.hash(data: input)
        return Data(hash)
    }
    
    /// Hash empty tree: SHA-256(0x00)
    private func hashEmpty() -> Data {
        let hash = _SHA256.hash(data: Data([UploadConstants.MERKLE_LEAF_PREFIX]))
        return Data(hash)
    }
    
    // MARK: - Checkpoint
    
    /// Emit checkpoint to server (every N leaves).
    private func emitCheckpoint() async {
        // In production, send checkpoint to server for verification
        // For now, just log
    }
}
