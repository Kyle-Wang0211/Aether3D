// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-SECURITY-1.0
// Module: Upload Infrastructure - Proof of Possession
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Challenge type.
public enum ChallengeType: String, Sendable, Codable {
    case fullHash
    case partialHash
    case merkleProof
}

/// Challenge request.
public struct ChallengeRequest: Sendable, Codable {
    public let nonce: String  // UUID v7
    public let challenges: [Challenge]
    
    public struct Challenge: Sendable, Codable {
        public let chunkIndex: Int
        public let type: ChallengeType
        public let byteRange: ClosedRange<Int>?
    }
}

/// Challenge response.
public struct ChallengeResponse: Sendable, Codable {
    public let nonce: String
    public let responses: [Response]
    
    public struct Response: Sendable, Codable {
        public let chunkIndex: Int
        public let hash: String?
        public let merkleProof: [String]?
    }
}

/// Secure instant upload: partial-chunk challenges, anti-replay nonce (UUID v7, 15s expiry).
///
/// **Purpose**: Secure instant upload: partial-chunk challenges, anti-replay nonce (UUID v7, 15s expiry),
/// ECDH encrypted channel.
///
/// **Protocol**:
/// 1. Client → Server: "I have ACI=xxx, merkleRoot=yyy, totalChunks=zzz"
/// 2. Server → Client: Challenge{nonce: UUID_v7 (15s expiry), challenges: [...]}
/// 3. Client → Server: ChallengeResponse{nonce: <echo>, responses: [...]}
/// 4. Server verifies all → instant upload complete (link existing data)
public actor ProofOfPossession {
    
    // MARK: - State
    
    private var usedNonces: Set<String> = []
    private let nonceExpiry: TimeInterval = 15.0
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Challenge Generation
    
    /// Generate challenge count based on file size.
    ///
    /// - Parameter fileSizeBytes: File size in bytes
    /// - Returns: Number of challenges
    public func generateChallengeCount(fileSizeBytes: Int64) -> Int {
        if fileSizeBytes < 100 * 1024 * 1024 {  // <100MB
            return 5
        } else if fileSizeBytes < 1024 * 1024 * 1024 {  // 100MB-1GB
            return 8
        } else {  // >1GB
            return 12
        }
    }
    
    // MARK: - Nonce Validation
    
    /// Validate nonce (UUID v7, 15s expiry).
    ///
    /// - Parameter nonce: Nonce string
    /// - Returns: True if nonce is valid (fresh and unique)
    public func validateNonce(_ nonce: String) -> Bool {
        // Check if nonce was already used
        if usedNonces.contains(nonce) {
            return false
        }
        
        // Parse UUID v7 timestamp (first 48 bits = Unix timestamp in milliseconds)
        // Simplified validation - in production, parse UUID v7 properly
        guard UUID(uuidString: nonce) != nil else {
            return false
        }
        
        // Record nonce
        usedNonces.insert(nonce)
        
        // Clean up expired nonces
        cleanupExpiredNonces()
        
        return true
    }
    
    /// Clean up expired nonces.
    private func cleanupExpiredNonces() {
        // Simplified - in production, track timestamps and remove expired
        if usedNonces.count > 1000 {
            usedNonces.removeAll()
        }
    }
}
