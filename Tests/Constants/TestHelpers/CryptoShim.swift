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
#endif

// Pure Swift SHA-256 fallback for Linux (test-only safety net)
// Used when native crypto backend triggers SIGILL despite OPENSSL_ia32cap=:0
// This is a minimal, self-contained implementation following RFC 6234 / FIPS 180-4
// Only used as fallback when Crypto/CryptoKit imports fail or cause SIGILL
#if !canImport(CryptoKit) && !canImport(Crypto)
// Fallback: Pure Swift SHA-256 (test-only, Linux fallback)
// This implementation is deterministic and produces correct SHA-256 output
// Based on FIPS 180-4 specification
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
    /// Returns the active backend name as a stable string identifier.
    ///
    /// - Returns: "PURE_SWIFT" if using pure Swift implementation, "NATIVE" if using native crypto backend
    /// - Note: This is an executable assertion API for test policy enforcement, not just logging
    public static func activeBackendName() -> String {
        #if canImport(CryptoKit)
        // Apple platforms: use CryptoKit (native)
        return "NATIVE"
        #elseif canImport(Crypto)
        // Linux: check if pure Swift backend is enabled
        #if os(Linux)
        if ProcessInfo.processInfo.environment["SSOT_PURE_SWIFT_SHA256"] == "1" {
            return "PURE_SWIFT"
        } else {
            return "NATIVE"
        }
        #else
        return "NATIVE"
        #endif
        #else
        // No crypto module available: use pure Swift fallback
        return "PURE_SWIFT"
        #endif
    }
    
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
        // Linux: use swift-crypto Crypto by default
        // Pure Swift fallback can be enabled via SSOT_PURE_SWIFT_SHA256=1 env var (Linux-only)
        // This allows explicit control for testing or when native crypto fails
        #if os(Linux)
        let usePureSwift = ProcessInfo.processInfo.environment["SSOT_PURE_SWIFT_SHA256"] == "1"
        if usePureSwift {
            // Explicitly use pure Swift fallback (for testing or SIGILL mitigation)
            // Log backend selection for CI auditability (test-only, early in Gate 2 runs)
            print("🔍 CryptoShim backend: PURE_SWIFT (SSOT_PURE_SWIFT_SHA256=1)")
            return SHA256PureSwift.sha256Digest(data)
        } else {
            // Default: use native crypto backend (with OPENSSL_ia32cap=:0 mitigation)
            print("🔍 CryptoShim backend: NATIVE (swift-crypto Crypto module)")
        }
        #endif
        // Default: use native crypto backend (with OPENSSL_ia32cap=:0 mitigation)
        let hash = Crypto.SHA256.hash(data: data)
        return Array(hash)
        #else
        // No crypto module available: use pure Swift fallback (test-only safety net)
        // This ensures tests can run even if swift-crypto dependency is missing
        // SHA256PureSwift is in the same module, so it's always available
        print("🔍 CryptoShim backend: PURE_SWIFT (no crypto module available)")
        return SHA256PureSwift.sha256Digest(data)
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
