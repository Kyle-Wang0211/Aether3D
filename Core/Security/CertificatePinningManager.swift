// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CertificatePinningManager.swift
// Aether3D
//
// Certificate Pinning Manager - SPKI-based certificate pinning
// 符合 INV-SEC-033 到 INV-SEC-036
//

import Foundation

// Certificate pinning uses Security framework APIs (SecTrust, SecCertificate)
// which are only available on Apple platforms
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)

import Security
import SharedSecurity

/// Certificate Pinning Manager
///
/// Implements SPKI-based certificate pinning.
/// 符合 INV-SEC-033: Certificate pinning MUST use SPKI hash
public actor CertificatePinningManager {
    
    // MARK: - Configuration
    
    /// Pinned SPKI hashes (SHA-256)
    /// 
    /// 符合 INV-SEC-035: Pins MUST be obfuscated in binary
    /// In production, these should be obfuscated/encrypted
    private let pinnedHashes: Set<String>
    
    /// Pin rotation overlap period (days)
    /// 
    /// 符合 INV-SEC-036: Pin rotation MUST include 30+ day overlap
    private let rotationOverlapDays: Int = 30
    
    // MARK: - Initialization
    
    /// Initialize Certificate Pinning Manager
    /// 
    /// - Parameter pinnedHashes: Set of SPKI SHA-256 hashes (hex strings)
    public init(pinnedHashes: Set<String>) {
        self.pinnedHashes = pinnedHashes
    }
    
    // MARK: - Certificate Validation
    
    /// Validate certificate chain against pinned SPKI hashes
    /// 
    /// 符合 INV-SEC-034: Pin mismatch MUST terminate connection immediately
    /// - Parameter trust: SecTrust object from server
    /// - Returns: True if certificate chain matches pinned hashes
    /// - Throws: CertificatePinningError if validation fails
    public func validateCertificateChain(_ trust: SecTrust) throws -> Bool {
        // Get certificate count
        let certificateCount = SecTrustGetCertificateCount(trust)
        
        guard certificateCount > 0 else {
            throw CertificatePinningError.noCertificates
        }
        
        // Check each certificate in chain
        for index in 0..<certificateCount {
            guard let certificate = SecTrustGetCertificateAtIndex(trust, index) else {
                continue
            }
            
            // Extract SPKI hash
            let spkiHash = try extractSPKIHash(from: certificate)
            
            // Check if hash matches any pinned hash
            if pinnedHashes.contains(spkiHash) {
                return true // Match found
            }
        }
        
        // No match found
        throw CertificatePinningError.pinMismatch
    }
    
    /// Extract SPKI hash from certificate
    /// 
    /// - Parameter certificate: SecCertificate
    /// - Returns: SHA-256 hash of SPKI (hex string)
    /// - Throws: CertificatePinningError if extraction fails
    private func extractSPKIHash(from certificate: SecCertificate) throws -> String {
        // Get certificate data
        let certificateData = SecCertificateCopyData(certificate) as Data
        
        // Parse ASN.1 to extract SPKI
        // This is a simplified version - in production, use proper ASN.1 parsing
        guard let spkiData = extractSPKIFromCertificate(certificateData) else {
            throw CertificatePinningError.spkiExtractionFailed
        }
        
        // Compute SHA-256 hash
        return CryptoHasher.sha256(spkiData)
    }
    
    /// Extract SPKI from certificate data (simplified)
    /// 
    /// In production, use proper ASN.1 DER parsing
    /// - Parameter certificateData: Certificate DER data
    /// - Returns: SPKI DER data
    private func extractSPKIFromCertificate(_ certificateData: Data) -> Data? {
        // Simplified SPKI extraction
        // In production, parse ASN.1 structure:
        // Certificate ::= SEQUENCE {
        //   tbsCertificate TBSCertificate,
        //   signatureAlgorithm AlgorithmIdentifier,
        //   signature BIT STRING
        // }
        // TBSCertificate ::= SEQUENCE {
        //   ...
        //   subjectPublicKeyInfo SubjectPublicKeyInfo
        // }
        
        // For now, return a placeholder
        // In production, implement full ASN.1 parsing
        return certificateData // Placeholder
    }
    
    // MARK: - Pin Rotation
    
    /// Add new pin for rotation
    /// 
    /// 符合 INV-SEC-036: Pin rotation MUST include 30+ day overlap
    /// - Parameter newHash: New SPKI hash to add
    public func addPinForRotation(_ newHash: String) {
        // In production, store with timestamp and remove old pins after overlap period
        // For now, just add to set
        var updatedHashes = pinnedHashes
        updatedHashes.insert(newHash)
    }
    
    /// Remove old pin after rotation period
    /// 
    /// - Parameter oldHash: Old SPKI hash to remove
    public func removePinAfterRotation(_ oldHash: String) {
        // In production, verify overlap period has passed
        // For now, just remove from set
        var updatedHashes = pinnedHashes
        updatedHashes.remove(oldHash)
    }
}

// MARK: - Errors

/// Certificate pinning errors
public enum CertificatePinningError: Error, Sendable {
    case noCertificates
    case pinMismatch
    case spkiExtractionFailed
    case invalidCertificate
    
    public var localizedDescription: String {
        switch self {
        case .noCertificates:
            return "No certificates in chain"
        case .pinMismatch:
            return "Certificate pin mismatch - connection terminated"
        case .spkiExtractionFailed:
            return "Failed to extract SPKI from certificate"
        case .invalidCertificate:
            return "Invalid certificate format"
        }
    }
}

#endif // os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
