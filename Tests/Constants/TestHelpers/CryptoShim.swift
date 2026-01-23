//
//  CryptoShim.swift
//  Aether3D
//
//  PR#1 SSOT Foundation v1.1.1 - Cross-Platform Crypto Shim
//  Provides SHA-256 hashing for tests on both Apple and Linux platforms
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("No cryptography module available. Add swift-crypto dependency (module: Crypto).")
#endif

/// Cross-platform cryptography shim for test code.
///
/// **Purpose:** Provides SHA-256 hashing that works on both Apple platforms (CryptoKit)
/// and Linux (swift-crypto Crypto module).
///
/// **Rule ID:** Cross-platform compatibility (Linux CI)
/// **Status:** IMMUTABLE
///
/// This shim ensures tests can compute SHA-256 hashes without platform-specific imports.
/// All test code should use this shim instead of directly importing CryptoKit.
public enum CryptoShim {
    /// Compute SHA-256 digest as bytes from input data.
    ///
    /// - Parameter data: Input data to hash
    /// - Returns: SHA-256 digest as array of bytes
    public static func sha256Digest(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        // Apple platforms: use CryptoKit
        let hash = CryptoKit.SHA256.hash(data: data)
        return Array(hash)
        #elseif canImport(Crypto)
        // Linux: use swift-crypto Crypto
        let hash = Crypto.SHA256.hash(data: data)
        return Array(hash)
        #else
        fatalError("No crypto backend available")
        #endif
    }
    
    /// Compute SHA-256 hash as hexadecimal string from input data.
    ///
    /// - Parameter data: Input data to hash
    /// - Returns: SHA-256 hash as lowercase hexadecimal string (64 characters)
    public static func sha256Hex(_ data: Data) -> String {
        let digest = sha256Digest(data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Compute SHA-256 hash as hexadecimal string from input string (UTF-8 encoded).
    ///
    /// - Parameter string: Input string to hash (converted to UTF-8 bytes)
    /// - Returns: SHA-256 hash as lowercase hexadecimal string (64 characters)
    public static func sha256Hex(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else {
            fatalError("Failed to convert string to UTF-8")
        }
        return sha256Hex(data)
    }
}
