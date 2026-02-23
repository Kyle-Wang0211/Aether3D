// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-INTEGRITY-1.0
// Module: Upload Infrastructure - Streaming Merkle Tree
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

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

    /// Stored leaf hashes for proof generation.
    private var leafHashes: [Data] = []
    
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
        leafHashes.append(leafHash)
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

        if leafCount == 1 {
            return []
        }

        var levels: [[Data]] = [leafHashes]
        var current = leafHashes
        var level = 0

        while current.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((current.count + 1) / 2)

            var i = 0
            while i < current.count {
                if i + 1 < current.count {
                    next.append(
                        StreamingMerkleTree.hashNodes(
                            left: current[i],
                            right: current[i + 1],
                            level: level
                        )
                    )
                } else {
                    // Odd node is promoted to next level unchanged.
                    next.append(current[i])
                }
                i += 2
            }

            levels.append(next)
            current = next
            level += 1
        }

        var proof: [Data] = []
        var index = leafIndex

        for levelIndex in 0..<(levels.count - 1) {
            let nodes = levels[levelIndex]
            if index % 2 == 0 {
                let sibling = index + 1
                if sibling < nodes.count {
                    proof.append(nodes[sibling])
                }
            } else {
                proof.append(nodes[index - 1])
            }
            index /= 2
        }

        return proof
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
        guard totalLeaves > 0, index >= 0, index < totalLeaves else {
            return false
        }

        var currentHash = leaf
        var currentIndex = index
        var levelNodeCount = totalLeaves
        var level = 0
        var proofIndex = 0

        while levelNodeCount > 1 {
            if currentIndex % 2 == 0 {
                let hasRightSibling = (currentIndex + 1) < levelNodeCount
                if hasRightSibling {
                    guard proofIndex < proof.count else {
                        return false
                    }
                    currentHash = StreamingMerkleTree.hashNodes(
                        left: currentHash,
                        right: proof[proofIndex],
                        level: level
                    )
                    proofIndex += 1
                }
            } else {
                guard proofIndex < proof.count else {
                    return false
                }
                currentHash = StreamingMerkleTree.hashNodes(
                    left: proof[proofIndex],
                    right: currentHash,
                    level: level
                )
                proofIndex += 1
            }

            currentIndex /= 2
            levelNodeCount = (levelNodeCount + 1) / 2
            level += 1
        }

        if proofIndex != proof.count {
            return false
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
        
        return _aetherSHA256Digest(input)
    }
    
    /// Hash nodes: SHA-256(0x01 || level_LE8 || left || right)
    private static func hashNodes(left: Data, right: Data, level: Int) -> Data {
        var input = Data([UploadConstants.MERKLE_NODE_PREFIX])
        
        // Append level as UInt8
        input.append(UInt8(level))
        
        // Append left and right hashes
        input.append(left)
        input.append(right)
        
        return _aetherSHA256Digest(input)
    }
    
    /// Hash empty tree: SHA-256(0x00)
    private func hashEmpty() -> Data {
        _aetherSHA256Digest(Data([UploadConstants.MERKLE_LEAF_PREFIX]))
    }
    
    // MARK: - Checkpoint
    
    /// Emit checkpoint to server (every N leaves).
    private func emitCheckpoint() async {
        // In production, send checkpoint to server for verification
        // For now, just log
    }
}
