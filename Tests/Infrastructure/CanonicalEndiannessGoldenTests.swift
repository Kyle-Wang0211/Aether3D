// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CanonicalEndiannessGoldenTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Endianness Golden Tests
//
// Verifies BE encoding for all integer types (including negative Int64)
//

import XCTest
@testable import Aether3DCore

final class CanonicalEndiannessGoldenTests: XCTestCase {
    /// Test UInt16 BE encoding
    func testUInt16_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeUInt16BE(0x1234)
        let data = writer.toData()
        
        // Expected: 0x12 0x34 (BE)
        let expected: [UInt8] = [0x12, 0x34]
        XCTAssertEqual(Array(data), expected, "UInt16 BE encoding must match expected")
    }
    
    /// Test UInt32 BE encoding
    func testUInt32_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeUInt32BE(0x12345678)
        let data = writer.toData()
        
        // Expected: 0x12 0x34 0x56 0x78 (BE)
        let expected: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        XCTAssertEqual(Array(data), expected, "UInt32 BE encoding must match expected")
    }
    
    /// Test UInt64 BE encoding
    func testUInt64_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeUInt64BE(0x123456789ABCDEF0)
        let data = writer.toData()
        
        // Expected: 0x12 0x34 0x56 0x78 0x9A 0xBC 0xDE 0xF0 (BE)
        let expected: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
        XCTAssertEqual(Array(data), expected, "UInt64 BE encoding must match expected")
    }
    
    /// Test Int32 BE encoding (positive)
    func testInt32_Positive_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeInt32BE(0x12345678)
        let data = writer.toData()
        
        // Expected: 0x12 0x34 0x56 0x78 (BE, two's complement)
        let expected: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        XCTAssertEqual(Array(data), expected, "Int32 positive BE encoding must match expected")
    }
    
    /// Test Int32 BE encoding (negative, two's complement)
    func testInt32_Negative_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeInt32BE(-1)
        let data = writer.toData()
        
        // Expected: 0xFF 0xFF 0xFF 0xFF (BE, two's complement for -1)
        let expected: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(Array(data), expected, "Int32 negative BE encoding must match expected")
    }
    
    /// Test Int64 BE encoding (positive)
    func testInt64_Positive_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeInt64BE(0x123456789ABCDEF0)
        let data = writer.toData()
        
        // Expected: 0x12 0x34 0x56 0x78 0x9A 0xBC 0xDE 0xF0 (BE, two's complement)
        let expected: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
        XCTAssertEqual(Array(data), expected, "Int64 positive BE encoding must match expected")
    }
    
    /// Test Int64 BE encoding (negative, two's complement)
    func testInt64_Negative_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeInt64BE(-1)
        let data = writer.toData()
        
        // Expected: 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF (BE, two's complement for -1)
        let expected: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(Array(data), expected, "Int64 negative BE encoding must match expected")
    }
    
    /// Test Int64 BE encoding (large negative value)
    func testInt64_LargeNegative_BigEndian() {
        let writer = CanonicalBytesWriter()
        writer.writeInt64BE(-0x123456789ABCDEF0)
        let data = writer.toData()
        
        // Expected: two's complement of -0x123456789ABCDEF0
        // -0x123456789ABCDEF0 = 0xEDCBA98765432110 (two's complement)
        let expected: [UInt8] = [0xED, 0xCB, 0xA9, 0x87, 0x65, 0x43, 0x21, 0x10]
        XCTAssertEqual(Array(data), expected, "Int64 large negative BE encoding must match expected")
    }
}
