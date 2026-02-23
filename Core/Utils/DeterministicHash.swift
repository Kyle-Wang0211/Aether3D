// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicHash.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Deterministic Hash Utility
//
// Deterministic hash computation for audit/replay (SHA-256 based)
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Deterministic hash utility
///
/// **MUST:** Hash MUST be deterministic across runs, platforms, and locales
/// DO NOT use Swift's default Hasher() because it is randomized between runs
///
/// **SECURITY FIX**: Removed insecure djb2 fallback. The previous `#else` branch
/// used a 64-bit djb2 hash function that:
///   1. Is NOT cryptographically secure (designed for hash tables, not integrity)
///   2. Produces only 64-bit output (vs SHA-256's 256-bit), trivially collisible
///   3. Violates INV-SEC-057: "all hash calculations must use CryptoKit SHA256"
///   4. Returns a 16-char hex string while the method name promises `sha256Hex`
///
/// The fix uses `#if canImport(CryptoKit)` / `#elseif canImport(Crypto)` to support
/// both Apple platforms (CryptoKit) and Linux (swift-crypto). Since swift-crypto is
/// a declared dependency in Package.swift, all supported platforms are covered.
/// If neither is available, the code fails at compile time with a clear error.
public struct DeterministicHash {
    /// Compute SHA-256 hex hash of data
    ///
    /// **Deterministic:** Same input produces same hash across all platforms/runs
    /// **Security:** Always uses cryptographic SHA-256 (never a weak fallback)
    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #else
        // SECURITY: No insecure fallback. swift-crypto (Package.swift dependency)
        // provides SHA256 on all supported platforms. If this fires, the build
        // configuration is broken — do NOT add a non-cryptographic fallback.
        #error("Neither CryptoKit nor swift-crypto available. SHA-256 is required for DeterministicHash.")
        #endif
    }

    /// Compute SHA-256 hex hash of UTF-8 string
    public static func sha256Hex(_ string: String) -> String {
        // String.data(using: .utf8) never returns nil, but we check for safety
        guard let data = string.data(using: .utf8) else { fatalError("Failed to convert string to UTF-8 data") }
        return sha256Hex(data)
    }

    /// Format double with fixed precision for canonical representation
    ///
    /// **MUST:** Use fixed format to ensure deterministic string representation
    public static func formatDouble(_ value: Double) -> String {
        return String(format: "%.8f", value)
    }
}
