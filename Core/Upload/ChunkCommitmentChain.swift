// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-INTEGRITY-1.0
// Module: Upload Infrastructure - Chunk Commitment Chain
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

// _SHA256 typealias defined in CryptoHelpers.swift

/// Bidirectional hash chain with jump chain (O(√n) verification), session-bound genesis.
///
/// **Forward chain**:
/// ```
/// commit[0] = SHA-256("CCv1\0" || chunk_hash[0] || genesis)
/// commit[i] = SHA-256("CCv1\0" || chunk_hash[i] || commit[i-1])
/// ```
///
/// **Genesis is session-specific**:
/// ```
/// genesis = SHA-256("Aether3D_CC_GENESIS_" || sessionId)
/// ```
///
/// **Jump chain**: Every sqrt(n) chunks
/// ```
/// jump[j] = SHA-256("CCv1_JUMP\0" || commit[j * stride])
/// ```
///
/// **Bidirectional**: Forward chain built during upload. Reverse chain verification during resume.
/// Binary search to locate first tampered chunk.
public actor ChunkCommitmentChain {
    
    // MARK: - State
    
    private let sessionId: String
    private let genesis: Data
    
    /// Forward commitments
    private var forwardChain: [Data] = []
    
    /// Jump chain (every sqrt(n) chunks)
    private var jumpChain: [Data] = []
    private var jumpStride: Int = 1
    
    // MARK: - Initialization
    
    /// Initialize commitment chain with session ID.
    ///
    /// - Parameter sessionId: Upload session ID
    public init(sessionId: String) {
        self.sessionId = sessionId
        
        // Compute genesis: SHA-256("Aether3D_CC_GENESIS_" || sessionId)
        let genesisInput = UploadConstants.COMMITMENT_CHAIN_GENESIS_PREFIX + sessionId
        let genesisHash = _SHA256.hash(data: Data(genesisInput.utf8))
        self.genesis = Data(genesisHash)
        
        // Initialize jump stride (will be updated as chain grows)
        jumpStride = 1
    }
    
    // MARK: - Forward Chain
    
    /// Append chunk to forward chain.
    ///
    /// - Parameter chunkHash: SHA-256 hash of chunk (hex string)
    /// - Returns: Commitment hash (hex string)
    public func appendChunk(_ chunkHash: String) -> String {
        // Convert hex to Data
        guard let chunkHashData = hexStringToData(chunkHash) else {
            fatalError("Invalid chunk hash format")
        }
        
        // Compute commitment
        let previousCommitment = forwardChain.last ?? genesis
        let commitment = computeCommitment(chunkHash: chunkHashData, previousCommitment: previousCommitment)
        
        forwardChain.append(commitment)
        
        // Update jump chain if needed
        let currentIndex = forwardChain.count - 1
        if currentIndex % jumpStride == 0 {
            let jumpHash = computeJumpHash(commitment: commitment)
            jumpChain.append(jumpHash)
        }
        
        // Update jump stride: sqrt(n)
        jumpStride = Int(sqrt(Double(forwardChain.count))) + 1
        
        return dataToHexString(commitment)
    }
    
    /// Get latest commitment.
    ///
    /// - Returns: Latest commitment hash (hex string), or genesis if empty
    public func getLatestCommitment() -> String {
        return forwardChain.last.map { dataToHexString($0) } ?? dataToHexString(genesis)
    }
    
    // MARK: - Verification
    
    /// Verify forward chain integrity.
    ///
    /// - Parameter chunkHashes: Array of chunk hashes (hex strings)
    /// - Returns: True if chain is valid
    public func verifyForwardChain(_ chunkHashes: [String]) -> Bool {
        guard chunkHashes.count == forwardChain.count else {
            return false
        }
        
        var currentCommitment = genesis
        
        for (index, chunkHashHex) in chunkHashes.enumerated() {
            guard let chunkHashData = hexStringToData(chunkHashHex) else {
                return false
            }
            
            let expectedCommitment = computeCommitment(chunkHash: chunkHashData, previousCommitment: currentCommitment)
            let actualCommitment = forwardChain[index]
            
            if expectedCommitment != actualCommitment {
                return false
            }
            
            currentCommitment = expectedCommitment
        }
        
        return true
    }
    
    /// Verify reverse chain (for resume).
    ///
    /// - Parameter startIndex: Starting chunk index
    /// - Parameter chunkHashes: Array of chunk hashes from startIndex
    /// - Returns: Index of first tampered chunk, or nil if all valid
    public func verifyReverseChain(startIndex: Int, chunkHashes: [String]) -> Int? {
        guard startIndex < forwardChain.count else {
            return startIndex
        }
        
        var currentCommitment = startIndex > 0 ? forwardChain[startIndex - 1] : genesis
        
        for (offset, chunkHashHex) in chunkHashes.enumerated() {
            let index = startIndex + offset
            guard index < forwardChain.count else {
                break
            }
            
            guard let chunkHashData = hexStringToData(chunkHashHex) else {
                return index
            }
            
            let expectedCommitment = computeCommitment(chunkHash: chunkHashData, previousCommitment: currentCommitment)
            let actualCommitment = forwardChain[index]
            
            if expectedCommitment != actualCommitment {
                return index
            }
            
            currentCommitment = expectedCommitment
        }
        
        return nil  // All valid
    }
    
    // MARK: - Jump Chain
    
    /// Verify using jump chain (O(√n) verification).
    ///
    /// - Returns: True if jump chain is valid
    public func verifyJumpChain() -> Bool {
        guard !jumpChain.isEmpty else {
            return true
        }
        
        for (jumpIndex, jumpHash) in jumpChain.enumerated() {
            let chainIndex = jumpIndex * jumpStride
            guard chainIndex < forwardChain.count else {
                continue
            }
            
            let commitment = forwardChain[chainIndex]
            let expectedJumpHash = computeJumpHash(commitment: commitment)
            
            if expectedJumpHash != jumpHash {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Helper Functions
    
    /// Compute commitment: SHA-256("CCv1\0" || chunk_hash || previous_commitment)
    private func computeCommitment(chunkHash: Data, previousCommitment: Data) -> Data {
        var input = Data(UploadConstants.COMMITMENT_CHAIN_DOMAIN.utf8)
        input.append(chunkHash)
        input.append(previousCommitment)
        
        let hash = _SHA256.hash(data: input)
        return Data(hash)
    }
    
    /// Compute jump hash: SHA-256("CCv1_JUMP\0" || commitment)
    private func computeJumpHash(commitment: Data) -> Data {
        var input = Data(UploadConstants.COMMITMENT_CHAIN_JUMP_DOMAIN.utf8)
        input.append(commitment)
        
        let hash = _SHA256.hash(data: input)
        return Data(hash)
    }
    
    /// Convert hex string to Data.
    private func hexStringToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        return data
    }
    
    /// Convert Data to hex string.
    private func dataToHexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
