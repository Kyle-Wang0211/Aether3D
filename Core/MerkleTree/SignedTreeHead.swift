//
// SignedTreeHead.swift
// Aether3D
//
// Phase 2: Merkle Audit Tree - Signed Tree Head
//
// **Standard:** RFC 9162 Section 4.3
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Signed Tree Head (STH) for Merkle audit tree
///
/// **Standard:** RFC 9162 Section 4.3
/// **Signature:** Ed25519
///
/// **Invariants:**
/// - INV-C1: SHA-256 for logId
/// - INV-C4: Ed25519 signature
/// - INV-C2: Big-Endian encoding for message
public struct SignedTreeHead: Codable, Sendable {
    /// Tree size (number of entries)
    public let treeSize: UInt64
    
    /// Root hash (32 bytes)
    public let rootHash: Data
    
    /// Timestamp in nanoseconds since Unix epoch
    public let timestampNanos: UInt64
    
    /// Ed25519 signature over message
    public let signature: Data
    
    /// Log ID (SHA-256 of public key)
    public let logId: Data
    
    /// Log parameters hash (for future extensibility)
    public let logParamsHash: Data
    
    /// Create signed tree head
    ///
    /// **Message format:** BE(treeSize) || BE(timestampNanos) || rootHash
    ///
    /// - Parameters:
    ///   - treeSize: Tree size
    ///   - rootHash: Root hash (32 bytes)
    ///   - timestampNanos: Timestamp in nanoseconds
    ///   - privateKey: Ed25519 private key for signing
    /// - Returns: SignedTreeHead
    /// - Throws: Error if signing fails
    public static func sign(
        treeSize: UInt64,
        rootHash: Data,
        timestampNanos: UInt64,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedTreeHead {
        guard rootHash.count == 32 else {
            throw MerkleTreeError.invalidHashLength(expected: 32, actual: rootHash.count)
        }
        
        // Construct message: BE(treeSize) || BE(timestampNanos) || rootHash
        var message = Data()
        withUnsafeBytes(of: treeSize.bigEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampNanos.bigEndian) { message.append(contentsOf: $0) }
        message.append(rootHash)
        
        // Sign with Ed25519
        let signature = try privateKey.signature(for: message)
        
        // Log ID is SHA-256 of public key
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let logId = Data(SHA256.hash(data: publicKeyData))
        
        // Log parameters hash (hash algorithm, signature algorithm, domain separation constants)
        let logParams = "SHA256:Ed25519:0x00:0x01"
        let logParamsHash = Data(SHA256.hash(data: Data(logParams.utf8)))
        
        return SignedTreeHead(
            treeSize: treeSize,
            rootHash: rootHash,
            timestampNanos: timestampNanos,
            signature: Data(signature),
            logId: logId,
            logParamsHash: logParamsHash
        )
    }
    
    /// Verify signature
    ///
    /// - Parameter publicKey: Ed25519 public key
    /// - Returns: true if signature is valid
    public func verify(publicKey: Curve25519.Signing.PublicKey) -> Bool {
        var message = Data()
        withUnsafeBytes(of: treeSize.bigEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampNanos.bigEndian) { message.append(contentsOf: $0) }
        message.append(rootHash)
        
        return publicKey.isValidSignature(signature, for: message)
    }
}
