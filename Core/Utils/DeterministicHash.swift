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
#endif

/// Deterministic hash utility
/// 
/// **MUST:** Hash MUST be deterministic across runs, platforms, and locales
/// DO NOT use Swift's default Hasher() because it is randomized between runs
public struct DeterministicHash {
    /// Compute SHA-256 hex hash of data
    /// 
    /// **Deterministic:** Same input produces same hash across all platforms/runs
    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: simple deterministic hash for platforms without CryptoKit
        var hashValue: UInt64 = 5381
        for byte in data {
            hashValue = ((hashValue << 5) &+ hashValue) &+ UInt64(byte)
        }
        return String(format: "%016llx", hashValue)
        #endif
    }
    
    /// Compute SHA-256 hex hash of UTF-8 string
    public static func sha256Hex(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else {
            fatalError("Failed to convert string to UTF-8 data")
        }
        return sha256Hex(data)
    }
    
    /// Format double with fixed precision for canonical representation
    /// 
    /// **MUST:** Use fixed format to ensure deterministic string representation
    public static func formatDouble(_ value: Double) -> String {
        return String(format: "%.8f", value)
    }
}
