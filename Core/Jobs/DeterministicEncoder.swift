// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Deterministic JSON encoder for cross-platform consistency
/// Ensures identical output on iOS, macOS, and Linux
public final class DeterministicJSONEncoder {
    
    /// Encode value to deterministic JSON Data
    /// - Keys are sorted alphabetically
    /// - No whitespace
    /// - Dates use ISO8601 with fixed timezone
    /// - Floats use fixed precision
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        if let state = value as? EvidenceState {
            return try TrueDeterministicJSONEncoder.encodeEvidenceState(state)
        }
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
        return SHA256Utility.sha256(data)
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
