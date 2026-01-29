//
// DeterministicEncoding.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Deterministic Encoding Module (A2 Implementation)
//
// This module provides deterministic encoding functions for cross-platform consistency.
// All identity-related hashing MUST use these functions.
//

import Foundation

/// Deterministic encoding module for cross-platform consistency.
///
/// **Rule ID:** CROSS_PLATFORM_HASH_001, CROSS_PLATFORM_HASH_001A
/// **Status:** IMMUTABLE
///
/// **Hash Impact Warning:** Any change to byte order, string termination, or length field size
/// will irreversibly change patchId, geomId, and meshEpochSalt.
public enum DeterministicEncoding {
    
    // MARK: - Constants
    
    /// Hash algorithm identifier (v1.1.1 finalized)
    /// **Rule ID:** G2
    /// **Status:** IMMUTABLE
    public static let HASH_ALGO_ID = "SHA256"
    
    // MARK: - Integer Encoding
    
    /// Encodes an integer as Big-Endian bytes.
    ///
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter value: The integer value to encode
    /// - Returns: Big-Endian byte representation
    public static func encodeIntegerBE<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    
    /// Encodes a UInt32 as Big-Endian bytes.
    ///
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static func encodeUInt32BE(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    
    /// Encodes an Int64 as Big-Endian bytes.
    ///
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static func encodeInt64BE(_ value: Int64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    
    // MARK: - String Encoding (A2 + A2 Canonicalization)
    
    /// Encodes a string using length-prefixed UTF-8 encoding (no NUL terminator).
    ///
    /// **Rule ID:** A2, A2 (v1.1.1)
    /// **Status:** IMMUTABLE
    ///
    /// **Canonicalization:** String is normalized to Unicode NFC before encoding.
    ///
    /// Format:
    /// - uint32_be byteLength (counts bytes, not characters)
    /// - UTF-8 encoded bytes (exact length, no NUL terminator)
    ///
    /// - Parameter string: The string to encode (will be normalized to NFC)
    /// - Returns: Encoded data
    /// - Throws: If string contains embedded NUL bytes (forbidden)
    public static func encodeString(_ string: String) throws -> Data {
        // A2: Normalize to Unicode NFC before encoding
        let normalized = string.precomposedStringWithCanonicalMapping
        
        // Check for embedded NUL bytes (forbidden)
        if normalized.utf8.contains(0) {
            throw EncodingError.embeddedNulByte
        }
        
        let utf8Bytes = normalized.data(using: .utf8)!
        let byteLength = UInt32(utf8Bytes.count)
        
        var result = Data()
        result.append(encodeUInt32BE(byteLength))
        result.append(utf8Bytes)
        
        return result
    }
    
    /// Encodes an empty string (length = 0).
    ///
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static func encodeEmptyString() -> Data {
        return encodeUInt32BE(0)
    }
    
    // MARK: - Domain Separation Prefix Encoding
    
    /// Encodes a domain separation prefix using the same string encoding rules.
    ///
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    ///
    /// All domain prefixes must be registered in DOMAIN_PREFIXES.json.
    ///
    /// - Parameter prefix: The domain prefix string
    /// - Returns: Encoded prefix data
    /// - Throws: If prefix contains embedded NUL bytes
    public static func encodeDomainPrefix(_ prefix: String) throws -> Data {
        return try encodeString(prefix)
    }
    
    // MARK: - Array Encoding
    
    /// Encodes an array by writing length (uint32) followed by elements.
    ///
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter elements: Array of encodable elements
    /// - Parameter encodeElement: Function to encode each element
    /// - Returns: Encoded data
    public static func encodeArray<T>(
        _ elements: [T],
        encodeElement: (T) throws -> Data
    ) rethrows -> Data {
        let count = UInt32(elements.count)
        var result = Data()
        result.append(encodeUInt32BE(count))
        
        for element in elements {
            result.append(try encodeElement(element))
        }
        
        return result
    }
    
    // MARK: - Errors
    
    public enum EncodingError: Error {
        case embeddedNulByte
        case invalidInput
    }
}

// MARK: - Domain Separation Prefixes

extension DeterministicEncoding {
    /// Domain separation prefix for patchId.
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static let DOMAIN_PREFIX_PATCH_ID = "AETHER3D:PATCH_ID"
    
    /// Domain separation prefix for geomId.
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static let DOMAIN_PREFIX_GEOM_ID = "AETHER3D:GEOM_ID"
    
    /// Domain separation prefix for meshEpochSalt.
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static let DOMAIN_PREFIX_MESH_EPOCH = "AETHER3D:MESH_EPOCH"
    
    /// Domain separation prefix for assetRoot.
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static let DOMAIN_PREFIX_ASSET_ROOT = "AETHER3D:ASSET_ROOT"
    
    /// Domain separation prefix for evidenceHash.
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static let DOMAIN_PREFIX_EVIDENCE = "AETHER3D:EVIDENCE"
}
