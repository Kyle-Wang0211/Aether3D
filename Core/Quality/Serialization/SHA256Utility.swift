// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SHA256Utility.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  SHA256 utility - single source of truth for hash computation
//  H2: All hash inputs must be raw bytes, strings must be explicitly converted to UTF-8
//  Cross-platform: uses CryptoKit on Apple platforms, swift-crypto Crypto on Linux
//

import Foundation
import CAetherNativeBridge

/// SHA256Utility - SHA256 hash computation utility
/// SSOT for all commit_sha256, audit_sha256, coverage_delta_sha256 calculations
public struct SHA256Utility {
    /// Compute SHA256 hash of raw bytes
    /// H2: Input must be raw bytes (Data), not strings or platform-dependent types
    /// PR5.1: Ensures output is always exactly 64 hex characters
    public static func sha256(_ data: Data) -> String {
        var hex = [CChar](repeating: 0, count: Int(AETHER_SHA256_HEX_BYTES))
        let rc = data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return aether_sha256_hex(bytes, Int32(data.count), &hex)
        }
        precondition(rc == 0, "aether_sha256_hex failed with rc=\(rc)")
        let bytes = hex.prefix(64).map { UInt8(bitPattern: $0) }
        let hexString = String(decoding: bytes, as: UTF8.self)
        precondition(hexString.count == 64, "SHA256 hash must be exactly 64 hex characters, got \(hexString.count)")
        return hexString
    }
    
    /// Compute SHA256 hash of string (converts to UTF-8 bytes first)
    /// H2: String must be explicitly converted to UTF-8 bytes
    public static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
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
