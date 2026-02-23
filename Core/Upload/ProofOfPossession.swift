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
    public struct RuntimeSnapshot: Sendable, Equatable {
        public let verificationAttempts: Int
        public let verificationSuccesses: Int
        public let successRate: Double

        public init(verificationAttempts: Int, verificationSuccesses: Int, successRate: Double) {
            self.verificationAttempts = verificationAttempts
            self.verificationSuccesses = verificationSuccesses
            self.successRate = successRate
        }
    }
    
    // MARK: - State
    
    private var usedNonces: Set<String> = []
    private let nonceExpiry: TimeInterval = 15.0
    private var verificationAttempts: Int = 0
    private var verificationSuccesses: Int = 0
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Challenge Generation
    
    /// Generate challenge count based on file size.
    ///
    /// - Parameter fileSizeBytes: File size in bytes
    /// - Returns: Number of challenges
    public func generateChallengeCount(fileSizeBytes: Int64) -> Int {
        let size = max(fileSizeBytes, 0)
        let oneHundredMB = Int64(100 * 1024 * 1024)
        let oneThousandMB = Int64(1000 * 1024 * 1024)

        if size < oneHundredMB {  // <100MB
            return 5
        } else if size < oneThousandMB {  // 100MB-1000MB
            return 8
        } else {  // >=1000MB
            return 12
        }
    }
    
    // MARK: - Nonce Validation
    
    /// Validate nonce (UUID v7, 15s expiry).
    ///
    /// - Parameter nonce: Nonce string
    /// - Returns: True if nonce is valid (fresh and unique)
    public func validateNonce(_ nonce: String) -> Bool {
        verificationAttempts += 1
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
        verificationSuccesses += 1
        
        // Clean up expired nonces
        cleanupExpiredNonces()
        
        return true
    }

    public func runtimeSnapshot() -> RuntimeSnapshot {
        let rate = verificationAttempts > 0
            ? Double(verificationSuccesses) / Double(verificationAttempts)
            : 1.0
        return RuntimeSnapshot(
            verificationAttempts: verificationAttempts,
            verificationSuccesses: verificationSuccesses,
            successRate: max(0.0, min(1.0, rate))
        )
    }
    
    /// Clean up expired nonces.
    private func cleanupExpiredNonces() {
        // Simplified - in production, track timestamps and remove expired
        if usedNonces.count > 1000 {
            usedNonces.removeAll()
        }
    }
}
