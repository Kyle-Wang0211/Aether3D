//
// UUIDRFC4122GoldenTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - UUID RFC4122 Golden Vector Tests
//
// Verifies UUID RFC4122 encoding matches known golden vectors
//

import XCTest
@testable import Aether3DCore

final class UUIDRFC4122GoldenTests: XCTestCase {
    /// Test UUID RFC4122 encoding: 00000000-0000-0000-0000-000000000000 => 16 zero bytes
    func testUUIDRFC4122Bytes_ZeroUUID() throws {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let actualBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        
        let expectedBytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        
        XCTAssertEqual(actualBytes.count, 16, "UUID RFC4122 must produce exactly 16 bytes")
        XCTAssertEqual(actualBytes, expectedBytes, "Zero UUID must encode as 16 zero bytes")
    }
    
    /// Test UUID RFC4122 encoding: 00112233-4455-6677-8899-aabbccddeeff => bytes = 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff
    func testUUIDRFC4122Bytes_SequentialUUID() throws {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        let actualBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        
        // RFC4122 network order: time_low(4) + time_mid(2) + time_hi_and_version(2) + 
        //                        clock_seq_hi_and_reserved(1) + clock_seq_low(1) + node(6)
        // For UUID "00112233-4455-6677-8899-aabbccddeeff":
        // time_low = 00112233, time_mid = 4455, time_hi_and_version = 6677
        // clock_seq_hi_and_reserved = 88, clock_seq_low = 99
        // node = aabbccddeeff
        // Expected bytes: 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff
        let expectedBytes: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        
        XCTAssertEqual(actualBytes.count, 16, "UUID RFC4122 must produce exactly 16 bytes")
        XCTAssertEqual(actualBytes, expectedBytes, "Sequential UUID must encode as expected RFC4122 bytes")
    }
    
    /// Test UUID RFC4122 encoding cross-platform consistency
    /// 
    /// Verifies that the same UUID produces the same bytes on all platforms
    func testUUIDRFC4122Bytes_CrossPlatformConsistency() throws {
        let uuid = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let actualBytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        
        XCTAssertEqual(actualBytes.count, 16, "UUID RFC4122 must produce exactly 16 bytes")
        
        // Verify bytes are deterministic (same UUID => same bytes)
        let bytes2 = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        XCTAssertEqual(actualBytes, bytes2, "Same UUID must produce same bytes")
    }
}
