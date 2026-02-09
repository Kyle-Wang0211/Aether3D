// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  HashCalculator.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Hash Calculator
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Relationship to CryptoHashFacade: This module provides bundle-specific
/// hash operations (streaming file hash, domain-separated hash, OCI digest format).
/// For raw SHA-256 byte output, see CryptoHashFacade.sha256(data:).
/// For hex↔bytes conversion, this module delegates to CryptoHashFacade.

/// Result of streaming file hash computation.
/// Contains both the SHA-256 hash and the byte count, computed in a single pass
/// to eliminate TOCTOU (Time-of-Check-to-Time-of-Use) vulnerabilities.
public struct FileHashResult: Sendable {
    /// SHA-256 hash as 64 lowercase hexadecimal characters
    public let sha256Hex: String
    
    /// Actual bytes read (matches the hash)
    public let byteCount: Int64
}

/// SHA-256 hash calculator for bundle operations.
///
/// Provides streaming file hashing, in-memory data hashing, domain-separated
/// hashing, OCI digest formatting, and timing-safe comparison operations.
public enum HashCalculator {
    
    // MARK: - File Hashing
    
    /// Compute SHA-256 hash of a file using streaming reads.
    ///
    /// **TOCTOU Prevention**: Computes hash and byte count in a single pass.
    /// The file size is determined from the actual bytes read, not from
    /// FileManager.attributesOfItem, eliminating the TOCTOU window.
    ///
    /// **Memory Usage**: O(256 KB) constant memory regardless of file size.
    /// Uses FileHandle with 256 KB chunks optimized for Apple Silicon SHA-256 hardware.
    ///
    /// **Why FileHandle not mmap**:
    /// - mmap on iOS counts against virtual address space → low-memory devices may be jetsam-killed
    /// - mmap on NFS/SMB has undefined behavior for files modified during read
    /// - FileHandle with 256 KB blocks achieves 99% of SHA-256 hardware throughput on Apple Silicon
    ///
    /// - Parameter url: File URL to hash
    /// - Returns: FileHashResult containing hash and byte count
    /// - Throws: File system errors, read errors
    public static func sha256OfFile(at url: URL) throws -> FileHashResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() } // Use try? - hash is already computed, close error is non-critical
        
        var hasher = _SHA256()
        var totalBytes: Int64 = 0
        
        while true {
            let chunk = handle.readData(ofLength: BundleConstants.HASH_STREAM_CHUNK_BYTES)
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
            totalBytes += Int64(chunk.count)
        }
        
        let digest = hasher.finalize()
        let hexString = _hexLowercase(Array(digest))
        
        return FileHashResult(sha256Hex: hexString, byteCount: totalBytes)
    }
    
    // MARK: - In-Memory Hashing
    
    /// Compute SHA-256 hash of in-memory data.
    ///
    /// - Parameter data: Data to hash
    /// - Returns: 64 lowercase hexadecimal characters
    public static func sha256(of data: Data) -> String {
        let digest = _SHA256.hash(data: data)
        return _hexLowercase(Array(digest))
    }
    
    // MARK: - Domain-Separated Hashing
    
    /// Compute SHA-256 hash with domain separation tag.
    ///
    /// **SEAL FIX**: Domain tag is the ONLY parameter that changes the hash namespace.
    /// This prevents hash collisions between different contexts (bundle hash vs manifest hash).
    ///
    /// **Performance**: Uses reserveCapacity to pre-allocate combined buffer,
    /// avoiding O(n^2) reallocations in loops.
    ///
    /// Formula: `SHA256(tag.data(using: .ascii)! + data)`
    ///
    /// - Parameters:
    ///   - tag: Domain separation tag (must be ASCII, NUL-terminated)
    ///   - data: Data to hash
    /// - Returns: 64 lowercase hexadecimal characters
    public static func sha256WithDomain(_ tag: String, data: Data) -> String {
        guard let tagData = tag.data(using: .ascii) else { fatalError("Domain tag must be ASCII: \(tag)") }
        
        var combined = Data()
        combined.reserveCapacity(tagData.count + data.count)
        combined.append(tagData)
        combined.append(data)
        
        let digest = _SHA256.hash(data: combined)
        return _hexLowercase(Array(digest))
    }
    
    // MARK: - OCI Digest Format
    
    /// Convert hex string to OCI digest format.
    ///
    /// Format: "sha256:<64hex>"
    ///
    /// - Parameter hex: 64 lowercase hexadecimal characters
    /// - Returns: OCI digest string
    public static func ociDigest(fromHex hex: String) -> String {
        return "\(BundleConstants.DIGEST_PREFIX)\(hex)"
    }
    
    /// Extract hex string from OCI digest format.
    ///
    /// Validates the prefix and hex format using _validateSHA256.
    ///
    /// - Parameter digest: OCI digest string ("sha256:<64hex>")
    /// - Returns: 64 lowercase hexadecimal characters
    /// - Throws: BundleError.invalidDigestFormat if format is invalid
    public static func hexFromOCIDigest(_ digest: String) throws -> String {
        guard digest.hasPrefix(BundleConstants.DIGEST_PREFIX) else {
            throw BundleError.invalidDigestFormat("Digest must start with '\(BundleConstants.DIGEST_PREFIX)'")
        }
        
        let hex = String(digest.dropFirst(BundleConstants.DIGEST_PREFIX.count))
        try _validateSHA256(hex)
        return hex
    }
    
    // MARK: - Timing-Safe Comparison
    
    /// Timing-safe comparison of two Data values using Double-HMAC strategy.
    ///
    /// **SEAL FIX**: Uses Double-HMAC, NOT XOR accumulation.
    /// Rationale: LLVM dead-store elimination can optimize XOR loops (arXiv:2410.13489).
    /// CryptoKit's MessageAuthenticationCode == delegates to safeCompare() — guaranteed timing-safe.
    /// GATE: Do not change to XOR without security team review + formal verification.
    ///
    /// **CRITICAL**: Compares MessageAuthenticationCode values directly (NOT extracted to [UInt8]).
    /// The [UInt8] == operator is NOT timing-safe. CryptoKit's MessageAuthenticationCode ==
    /// calls safeCompare() internally, which is guaranteed timing-safe.
    ///
    /// Algorithm:
    /// 1. Generate random 32-byte symmetric key
    /// 2. Compute HMAC<SHA256>(key, data: lhs)
    /// 3. Compute HMAC<SHA256>(key, data: rhs)
    /// 4. Compare the two MessageAuthenticationCode values using ==
    ///
    /// - Parameters:
    ///   - a: First data value
    ///   - b: Second data value
    /// - Returns: true if equal, false otherwise
    public static func timingSafeEqual(_ a: Data, _ b: Data) -> Bool {
        // Generate random key for this comparison
        let key = SymmetricKey(size: .bits256)
        
        // Compute HMACs
        let mac1 = HMAC<_SHA256>.authenticationCode(for: a, using: key)
        let mac2 = HMAC<_SHA256>.authenticationCode(for: b, using: key)
        
        // CRITICAL: Compare MessageAuthenticationCode directly, NOT extracted bytes
        // CryptoKit's == operator delegates to safeCompare() which is timing-safe
        return mac1 == mac2
    }
    
    /// Timing-safe comparison of two hex strings.
    ///
    /// Converts both strings to lowercase, then to Data, then uses timingSafeEqual.
    ///
    /// - Parameters:
    ///   - a: First hex string
    ///   - b: Second hex string
    /// - Returns: true if equal (case-insensitive), false otherwise
    public static func timingSafeEqualHex(_ a: String, _ b: String) -> Bool {
        let aLower = a.lowercased()
        let bLower = b.lowercased()
        
        // Convert hex strings to Data
        guard let aBytes = try? CryptoHashFacade.hexStringToBytes(aLower),
              let bBytes = try? CryptoHashFacade.hexStringToBytes(bLower) else {
            return false
        }
        
        let aData = Data(aBytes)
        let bData = Data(bBytes)
        
        return timingSafeEqual(aData, bData)
    }
    
    // MARK: - File Verification
    
    /// Verify file hash matches expected value using timing-safe comparison.
    ///
    /// - Parameters:
    ///   - url: File URL to verify
    ///   - expectedSHA256Hex: Expected SHA-256 hash (64 hex chars)
    /// - Returns: true if hash matches
    /// - Throws: File system errors, read errors
    public static func verifyFile(at url: URL, expectedSHA256Hex: String) throws -> Bool {
        let result = try sha256OfFile(at: url)
        return timingSafeEqualHex(result.sha256Hex, expectedSHA256Hex)
    }
}
