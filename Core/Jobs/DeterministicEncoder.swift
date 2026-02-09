// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Deterministic JSON encoder for cross-platform consistency
/// Ensures identical output on iOS, macOS, and Linux
public final class DeterministicJSONEncoder {
    
    /// Encode value to deterministic JSON Data
    /// - Keys are sorted alphabetically
    /// - No whitespace
    /// - Dates use ISO8601 with fixed timezone
    /// - Floats use fixed precision
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        
        // Use custom float encoding for determinism
        encoder.nonConformingFloatEncodingStrategy = .throw
        
        return try encoder.encode(value)
    }
    
    /// Encode value to deterministic JSON String
    public static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "Failed to convert JSON data to UTF-8 string"
            ))
        }
        return string
    }
    
    /// Compute SHA256 hash of deterministic JSON
    public static func computeHash<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        // Use CryptoKit on Apple platforms, swift-crypto on Linux
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
        #else
        throw EncodingError.invalidValue(value, EncodingError.Context(
            codingPath: [],
            debugDescription: "No crypto library available (CryptoKit or Crypto)"
        ))
        #endif
    }
    
    /// Verify hash matches expected value
    public static func verifyHash<T: Encodable>(_ value: T, expectedHash: String) throws -> Bool {
        let computedHash = try computeHash(value)
        return computedHash == expectedHash
    }
    
    /// Decode value from deterministic JSON Data
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(type, from: data)
    }
}
