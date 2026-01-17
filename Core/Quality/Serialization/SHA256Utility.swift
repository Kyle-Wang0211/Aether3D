//
//  SHA256Utility.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  SHA256 utility - single source of truth for hash computation
//  H2: All hash inputs must be raw bytes, strings must be explicitly converted to UTF-8
//

import Foundation
import CryptoKit

/// SHA256Utility - SHA256 hash computation utility
/// SSOT for all commit_sha256, audit_sha256, coverage_delta_sha256 calculations
public struct SHA256Utility {
    /// Compute SHA256 hash of raw bytes
    /// H2: Input must be raw bytes (Data), not strings or platform-dependent types
    /// PR5.1: Ensures output is always exactly 64 hex characters
    public static func sha256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        // PR5.1: Validate output length (SHA256 = 32 bytes = 64 hex characters)
        // Use precondition instead of assert to ensure it fails in all builds
        precondition(hexString.count == 64, "SHA256 hash must be exactly 64 hex characters, got \(hexString.count)")
        return hexString
    }
    
    /// Compute SHA256 hash of string (converts to UTF-8 bytes first)
    /// H2: String must be explicitly converted to UTF-8 bytes
    public static func sha256(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else {
            fatalError("Failed to convert string to UTF-8")
        }
        return sha256(data)
    }
    
    /// Compute SHA256 hash of multiple data chunks concatenated
    public static func sha256(concatenating chunks: Data...) -> String {
        var combined = Data()
        for chunk in chunks {
            combined.append(chunk)
        }
        return sha256(combined)
    }
}

