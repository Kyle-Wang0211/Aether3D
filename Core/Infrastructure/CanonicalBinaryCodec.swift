// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CanonicalBinaryCodec.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Binary Codec
//
// Byte-stable encoding for hashing/idempotency (NO JSONEncoder/Codable)
//

import Foundation

/// Canonical bytes writer for deterministic encoding
/// 
/// **P0 Rules:**
/// - Fixed-order, fixed-width, big-endian integers only
/// - Explicit optional field encoding (presenceTag)
/// - No JSON, no Codable, no variable-length encodings without rules
/// Canonical bytes buffer size constant (P0)
public let CANONICAL_BYTES_BUFFER_SIZE: Int = 256

public class CanonicalBytesWriter {
    private var buffer: [UInt8]
    
    /// Initialize with pre-allocated buffer (deterministic capacity)
    /// 
    /// **P0 Contract:**
    /// - Uses CANONICAL_BYTES_BUFFER_SIZE for pre-allocation
    /// - Never relies on Data's internal growth heuristics for determinism
    public init(initialCapacity: Int = CANONICAL_BYTES_BUFFER_SIZE) {
        buffer = []
        buffer.reserveCapacity(initialCapacity)
    }
    
    /// Write UInt8 (direct, no endian conversion)
    public func writeUInt8(_ value: UInt8) {
        buffer.append(value)
    }
    
    /// Write UInt16 as Big-Endian
    /// 
    /// **P0 Contract:**
    /// - Writes bytes in network order (high byte first, low byte second)
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    public func writeUInt16BE(_ value: UInt16) {
        // Extract bytes in network order (BE): high byte first, low byte second
        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)
        buffer.append(highByte)
        buffer.append(lowByte)
    }
    
    /// Write UInt32 as Big-Endian
    /// 
    /// **P0 Contract:**
    /// - Writes bytes in network order (most significant byte first)
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    public func writeUInt32BE(_ value: UInt32) {
        // Extract bytes in network order (BE): byte0 (MSB) ... byte3 (LSB)
        buffer.append(UInt8((value >> 24) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8(value & 0xFF))
    }
    
    /// Write UInt64 as Big-Endian
    /// 
    /// **P0 Contract:**
    /// - Writes bytes in network order (most significant byte first)
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    public func writeUInt64BE(_ value: UInt64) {
        // Extract bytes in network order (BE): byte0 (MSB) ... byte7 (LSB)
        buffer.append(UInt8((value >> 56) & 0xFF))
        buffer.append(UInt8((value >> 48) & 0xFF))
        buffer.append(UInt8((value >> 40) & 0xFF))
        buffer.append(UInt8((value >> 32) & 0xFF))
        buffer.append(UInt8((value >> 24) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8(value & 0xFF))
    }
    
    /// Write Int32 as Big-Endian (two's complement)
    /// 
    /// **P0 Contract:**
    /// - Writes bytes in network order (most significant byte first)
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    public func writeInt32BE(_ value: Int32) {
        // Extract bytes in network order (BE): byte0 (MSB) ... byte3 (LSB)
        let uvalue = UInt32(bitPattern: value)
        buffer.append(UInt8((uvalue >> 24) & 0xFF))
        buffer.append(UInt8((uvalue >> 16) & 0xFF))
        buffer.append(UInt8((uvalue >> 8) & 0xFF))
        buffer.append(UInt8(uvalue & 0xFF))
    }
    
    /// Write Int64 as Big-Endian (two's complement)
    /// 
    /// **P0 Contract:**
    /// - Writes bytes in network order (most significant byte first)
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    public func writeInt64BE(_ value: Int64) {
        // Extract bytes in network order (BE): byte0 (MSB) ... byte7 (LSB)
        let uvalue = UInt64(bitPattern: value)
        buffer.append(UInt8((uvalue >> 56) & 0xFF))
        buffer.append(UInt8((uvalue >> 48) & 0xFF))
        buffer.append(UInt8((uvalue >> 40) & 0xFF))
        buffer.append(UInt8((uvalue >> 32) & 0xFF))
        buffer.append(UInt8((uvalue >> 24) & 0xFF))
        buffer.append(UInt8((uvalue >> 16) & 0xFF))
        buffer.append(UInt8((uvalue >> 8) & 0xFF))
        buffer.append(UInt8(uvalue & 0xFF))
    }
    
    /// Write UUID as RFC4122 network order (16 bytes)
    /// 
    /// **P0 Contract:**
    /// - Uses UUIDRFC4122.uuidRFC4122Bytes() for cross-platform consistency
    /// - Explicit field-level RFC4122 network order (no memory layout assumptions)
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    public func writeUUIDRfc4122(_ uuid: UUID) throws {
        let uuidBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        buffer.append(contentsOf: uuidBytes)
    }
    
    /// Write fixed number of zeros (padding)
    public func writeFixedZeros(count: Int) {
        buffer.append(contentsOf: Array(repeating: 0, count: count))
    }
    
    /// Write zero bytes (helper for reserved/padding fields)
    /// 
    /// **P0 Contract:**
    /// - Writes exactly `count` zero bytes
    /// - Used for reserved/padding fields in canonical layouts
    public func writeZeroBytes(count: Int) {
        writeFixedZeros(count: count)
    }
    
    /// Write bytes array (explicit append ordering)
    /// 
    /// **P0 Contract:**
    /// - Provides explicit append ordering for determinism
    /// - Used for DOMAIN_TAG concatenation and fixed-size sequences
    public func writeBytes(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }
    
    /// Write fixed-size array of UInt16 as Big-Endian
    /// 
    /// **Fail-closed:** Throws if array.count != expectedCount
    public func writeFixedArrayUInt16BE(array: [UInt16], expectedCount: Int) throws {
        guard array.count == expectedCount else {
            throw CanonicalBytesError.arraySizeMismatch(
                expected: expectedCount,
                actual: array.count
            )
        }
        for value in array {
            writeUInt16BE(value)
        }
    }
    
    /// Write fixed number of bytes (explicit append ordering)
    /// 
    /// **P0 Contract:**
    /// - Provides explicit append ordering for determinism
    /// - Used for fixed-size padding or known-size sequences
    public func writeFixedBytes(_ bytes: [UInt8], count: Int) throws {
        guard bytes.count == count else {
            throw CanonicalBytesError.arraySizeMismatch(expected: count, actual: bytes.count)
        }
        buffer.append(contentsOf: bytes)
    }
    
    /// Get final data
    public func toData() -> Data {
        return Data(buffer)
    }
    
    /// Get current byte count
    public var count: Int {
        return buffer.count
    }
}

/// Canonical bytes encoding errors
public enum CanonicalBytesError: Error {
    case arraySizeMismatch(expected: Int, actual: Int)
    case missingMandatoryField(fieldName: String)
    case unknownEnumValue(typeName: String, rawValue: UInt8)
}
