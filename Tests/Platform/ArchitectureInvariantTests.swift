// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ArchitectureInvariantTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Architecture Invariant Tests
//
// Ensures correctness across architectures (endianness, word size)
//

import XCTest
@testable import Aether3DCore

final class ArchitectureInvariantTests: XCTestCase {
    /// Test that endianness assumptions are explicit
    func testArchitecture_EndiannessExplicit() {
        // Verify we're using Big-Endian encoding explicitly
        let value: UInt64 = 0x0123456789ABCDEF
        
        // Manual Big-Endian encoding
        let beBytes: [UInt8] = [
            0x01, 0x23, 0x45, 0x67,
            0x89, 0xAB, 0xCD, 0xEF
        ]
        
        // Use CanonicalBytesWriter to encode
        let writer = CanonicalBytesWriter()
        writer.writeUInt64BE(value)
        let encodedBytes = writer.toData()
        
        // Verify encoding matches expected BE bytes
        XCTAssertEqual(Array(encodedBytes), beBytes, "UInt64 BE encoding must match expected bytes")
    }
    
    /// Test that word size doesn't affect encoding
    func testArchitecture_WordSizeInvariant() {
        // UInt16, UInt32, UInt64 should all encode correctly regardless of platform word size
        
        let values: [(UInt16, [UInt8])] = [
            (0x0123, [0x01, 0x23]),
            (0xFFFF, [0xFF, 0xFF]),
            (0x0000, [0x00, 0x00]),
        ]
        
        for (value, expectedBytes) in values {
            let writer = CanonicalBytesWriter()
            writer.writeUInt16BE(value)
            let encodedBytes = writer.toData()
            XCTAssertEqual(Array(encodedBytes), expectedBytes, "UInt16 BE encoding must be invariant (value: 0x\(String(value, radix: 16)))")
        }
        
        let values32: [(UInt32, [UInt8])] = [
            (0x01234567, [0x01, 0x23, 0x45, 0x67]),
            (0xFFFFFFFF, [0xFF, 0xFF, 0xFF, 0xFF]),
            (0x00000000, [0x00, 0x00, 0x00, 0x00]),
        ]
        
        for (value, expectedBytes) in values32 {
            let writer = CanonicalBytesWriter()
            writer.writeUInt32BE(value)
            let encodedBytes = writer.toData()
            XCTAssertEqual(Array(encodedBytes), expectedBytes, "UInt32 BE encoding must be invariant (value: 0x\(String(value, radix: 16)))")
        }
    }
    
    /// Test that UUID encoding is architecture-invariant
    func testArchitecture_UUIDInvariant() throws {
        let uuid = UUID(uuid: (0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF))
        
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        
        let expected: [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF]
        
        XCTAssertEqual(bytes, expected, "UUID encoding must be architecture-invariant")
    }
    
    /// Runtime assert endianness == expected
    func testArchitecture_RuntimeEndiannessCheck() {
        #if _endian(big)
        // Big-endian platform
        XCTAssertTrue(true, "Platform is big-endian")
        #else
        // Little-endian platform (most common)
        // Our encoding uses explicit BE conversion, so this is fine
        XCTAssertTrue(true, "Platform is little-endian, but we use explicit BE encoding")
        #endif
        
        // Verify our encoding produces BE regardless of platform
        let value: UInt16 = 0x1234
        let writer = CanonicalBytesWriter()
        writer.writeUInt16BE(value)
        let bytes = writer.toData()
        
        // BE encoding: 0x12, 0x34
        XCTAssertEqual(bytes[0], 0x12, "First byte must be high byte (BE)")
        XCTAssertEqual(bytes[1], 0x34, "Second byte must be low byte (BE)")
    }
}
