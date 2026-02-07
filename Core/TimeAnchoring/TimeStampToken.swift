//
// TimeStampToken.swift
// Aether3D
//
// Phase 1: Time Anchoring - RFC 3161 TimeStampToken Data Structure
//

import Foundation

/// RFC 3161 TimeStampToken
///
/// **Standard:** RFC 3161 Section 2.4.2
/// **Encoding:** ASN.1 DER
///
/// **Invariants:**
/// - INV-C1: messageImprint uses SHA-256 (32 bytes)
/// - INV-C2: All numeric fields use Big-Endian encoding
public struct TimeStampToken: Codable, Sendable {
    /// Generation time (UTC) from TSTInfo
    public let genTime: Date
    
    /// Message imprint (hash algorithm + digest)
    public let messageImprint: MessageImprint
    
    /// Serial number from TSTInfo
    public let serialNumber: Data
    
    /// TSA name (from TSTInfo.tsa field, optional)
    public let tsaName: String?
    
    /// Policy OID from TSTInfo
    public let policyOID: String
    
    /// Nonce from request (must match request nonce)
    public let nonce: Data?
    
    /// Full DER-encoded TimeStampToken
    public let derEncoded: Data
    
    /// Message imprint structure (algorithm + digest)
    public struct MessageImprint: Codable, Sendable {
        /// Hash algorithm OID (e.g., "2.16.840.1.101.3.4.2.1" for SHA-256)
        public let algorithmOID: String
        
        /// Hash digest (32 bytes for SHA-256)
        public let digest: Data
        
        /// Verify this imprint matches the given hash
        public func matches(hash: Data) -> Bool {
            guard digest.count == 32, hash.count == 32 else { return false }
            return digest == hash
        }
    }
    
    /// Verify this token matches the original hash
    public func verify(hash: Data) -> Bool {
        return messageImprint.matches(hash: hash)
    }
}
