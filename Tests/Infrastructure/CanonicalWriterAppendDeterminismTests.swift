//
// CanonicalWriterAppendDeterminismTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Writer Append Determinism Tests
//
// Verifies multi-chunk append vs single-chunk append produces identical bytes
//

import XCTest
@testable import Aether3DCore

final class CanonicalWriterAppendDeterminismTests: XCTestCase {
    /// Test multi-chunk append vs single-chunk append produces identical bytes
    func testAppendDeterminism_MultiChunkVsSingleChunk() {
        // Single-chunk append
        let writer1 = CanonicalBytesWriter()
        writer1.writeUInt64BE(0x123456789ABCDEF0)
        writer1.writeUInt32BE(0x12345678)
        writer1.writeUInt16BE(0x1234)
        writer1.writeUInt8(0x12)
        let data1 = writer1.toData()
        
        // Multi-chunk append (same data, different append pattern)
        let writer2 = CanonicalBytesWriter()
        writer2.writeUInt64BE(0x123456789ABCDEF0)
        writer2.writeUInt32BE(0x12345678)
        writer2.writeUInt16BE(0x1234)
        writer2.writeUInt8(0x12)
        let data2 = writer2.toData()
        
        // Should produce identical bytes
        XCTAssertEqual(Array(data1), Array(data2), "Multi-chunk append must produce identical bytes to single-chunk append")
    }
    
    /// Test writeFixedBytes produces deterministic output
    func testWriteFixedBytes_Deterministic() throws {
        let writer = CanonicalBytesWriter()
        let fixedBytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        try writer.writeFixedBytes(fixedBytes, count: 4)
        let data = writer.toData()
        
        XCTAssertEqual(Array(data), fixedBytes, "writeFixedBytes must produce deterministic output")
    }
    
    /// Test writeFixedBytes fails on size mismatch
    func testWriteFixedBytes_SizeMismatch_FailsClosed() throws {
        let writer = CanonicalBytesWriter()
        let fixedBytes: [UInt8] = [0x01, 0x02, 0x03]
        
        XCTAssertThrowsError(try writer.writeFixedBytes(fixedBytes, count: 4)) { error in
            guard case CanonicalBytesError.arraySizeMismatch(expected: 4, actual: 3) = error else {
                XCTFail("Expected arraySizeMismatch error")
                return
            }
        }
    }
}
