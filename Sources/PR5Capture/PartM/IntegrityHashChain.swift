//
// IntegrityHashChain.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 完整性哈希链，Merkle树结构
//

import Foundation
import SharedSecurity

/// Integrity hash chain
///
/// Maintains integrity hash chain with Merkle tree structure.
/// Provides tamper-evident data structure.
public actor IntegrityHashChain {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Hash chain
    private var chain: [HashNode] = []
    
    /// Merkle root
    private var merkleRoot: String?
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Chain Operations
    
    /// Add hash to chain
    public func addHash(_ data: Data) -> ChainResult {
        let hash = computeHash(data)
        let previousHash = chain.last?.hash ?? ""
        
        let node = HashNode(
            hash: hash,
            previousHash: previousHash,
            data: data,
            timestamp: Date()
        )
        
        chain.append(node)
        
        // Update Merkle root periodically
        if chain.count % 10 == 0 {
            merkleRoot = computeMerkleRoot()
        }
        
        // Keep only recent chain (last 1000)
        if chain.count > 1000 {
            chain.removeFirst()
        }
        
        return ChainResult(
            nodeId: node.id,
            hash: hash,
            chainLength: chain.count
        )
    }
    
    /// Verify chain integrity
    public func verifyIntegrity() -> IntegrityResult {
        guard chain.count >= 2 else {
            return IntegrityResult(isValid: true, invalidIndices: [])
        }
        
        var invalidIndices: [Int] = []
        var expectedPreviousHash = ""
        
        for (index, node) in chain.enumerated() {
            if index > 0 && node.previousHash != expectedPreviousHash {
                invalidIndices.append(index)
            }
            expectedPreviousHash = node.hash
        }
        
        return IntegrityResult(
            isValid: invalidIndices.isEmpty,
            invalidIndices: invalidIndices
        )
    }
    
    /// Compute hash
    /// 
    /// 使用密码学安全的SHA256哈希，符合INV-SEC-057。
    private func computeHash(_ data: Data) -> String {
        return CryptoHasher.sha256(data)
    }
    
    /// Compute Merkle root
    private func computeMerkleRoot() -> String {
        guard !chain.isEmpty else { return "" }
        
        var hashes = chain.map { $0.hash }
        
        // Build Merkle tree
        while hashes.count > 1 {
            var nextLevel: [String] = []
            for i in stride(from: 0, to: hashes.count, by: 2) {
                if i + 1 < hashes.count {
                    let combined = hashes[i] + hashes[i+1]
                    // 使用密码学安全的SHA256哈希，符合INV-SEC-057
                    let combinedData = combined.data(using: .utf8) ?? Data()
                    nextLevel.append(CryptoHasher.sha256(combinedData))
                } else {
                    nextLevel.append(hashes[i])
                }
            }
            hashes = nextLevel
        }
        
        return hashes.first ?? ""
    }
    
    // MARK: - Data Types
    
    /// Hash node
    public struct HashNode: Sendable {
        public let id: UUID
        public let hash: String
        public let previousHash: String
        public let data: Data
        public let timestamp: Date
        
        public init(id: UUID = UUID(), hash: String, previousHash: String, data: Data, timestamp: Date) {
            self.id = id
            self.hash = hash
            self.previousHash = previousHash
            self.data = data
            self.timestamp = timestamp
        }
    }
    
    /// Chain result
    public struct ChainResult: Sendable {
        public let nodeId: UUID
        public let hash: String
        public let chainLength: Int
    }
    
    /// Integrity result
    public struct IntegrityResult: Sendable {
        public let isValid: Bool
        public let invalidIndices: [Int]
    }
}
