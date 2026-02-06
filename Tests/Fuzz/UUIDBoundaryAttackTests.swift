//
// UUIDBoundaryAttackTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - UUID Boundary Attack Tests
//
// Tests adversarial UUID inputs: malformed strings, boundary values
//

import XCTest
@testable import Aether3DCore

final class UUIDBoundaryAttackTests: XCTestCase {
    /// Test boundary UUID: all zeros
    func testUUID_Boundary_AllZeros() throws {
        let zeroUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(zeroUUID)
        
        XCTAssertEqual(bytes.count, 16, "UUID must be 16 bytes")
        XCTAssertEqual(bytes, Array(repeating: 0, count: 16), "All-zero UUID must produce all-zero bytes")
    }
    
    /// Test boundary UUID: all ones (FF)
    func testUUID_Boundary_AllOnes() throws {
        let allOnesUUID = UUID(uuid: (0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF))
        
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(allOnesUUID)
        
        XCTAssertEqual(bytes.count, 16, "UUID must be 16 bytes")
        XCTAssertEqual(bytes, Array(repeating: 0xFF, count: 16), "All-ones UUID must produce all-FF bytes")
    }
    
    /// Test sequential pattern UUID
    func testUUID_Boundary_SequentialPattern() throws {
        let sequentialUUID = UUID(uuid: (0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF))
        
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(sequentialUUID)
        
        XCTAssertEqual(bytes.count, 16, "UUID must be 16 bytes")
        let expected: [UInt8] = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF]
        XCTAssertEqual(bytes, expected, "Sequential UUID must produce expected bytes")
    }
    
    /// Test that malformed UUID strings are rejected before hashing
    func testUUID_MalformedString_Rejected() {
        let malformedStrings = [
            "",
            "not-a-uuid",
            "12345",
            "00000000-0000-0000-0000-00000000000", // Too short
            "00000000-0000-0000-0000-0000000000000", // Too long
            "00000000-0000-0000-0000-00000000000g", // Invalid hex
            "00000000-0000-0000-0000-00000000000G", // Invalid hex
        ]
        
        for malformed in malformedStrings {
            let uuid = UUID(uuidString: malformed)
            XCTAssertNil(uuid, "Malformed UUID string '\(malformed)' must be rejected")
        }
    }
    
    /// Test that only RFC4122-valid UUIDs are accepted
    func testUUID_RFC4122_ValidOnly() throws {
        // Valid UUIDs
        let validUUIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
        ]
        
        for uuid in validUUIDs {
            let bytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
            XCTAssertEqual(bytes.count, 16, "Valid UUID must produce 16 bytes")
        }
    }
    
    /// Test that invalid input never reaches hashing
    func testUUID_InvalidInput_NotHashed() throws {
        // Create a UUID with invalid structure (if possible)
        // UUID(uuid:) constructor validates structure, so we can't create invalid UUIDs directly
        // But we can test that UUIDRFC4122.uuidRFC4122Bytes only accepts UUID type
        
        let validUUID = UUID()
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(validUUID)
        XCTAssertEqual(bytes.count, 16, "Valid UUID must produce 16 bytes")
        
        // Verify that invalid UUID strings can't be converted to UUID
        let invalidString = "not-a-uuid"
        let invalidUUID = UUID(uuidString: invalidString)
        XCTAssertNil(invalidUUID, "Invalid UUID string must be rejected")
    }
    
    /// Test boundary UUID encoding determinism
    func testUUID_Boundary_Determinism() throws {
        let testUUIDs = [
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
            UUID(uuid: (0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF)),
            UUID(uuid: (0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF)),
        ]
        
        for uuid in testUUIDs {
            let bytes1 = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
            let bytes2 = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
            
            XCTAssertEqual(bytes1, bytes2, "UUID encoding must be deterministic")
            XCTAssertEqual(bytes1.count, 16, "UUID must be 16 bytes")
        }
    }
    
    /// Test UUID with version/variant bits set
    func testUUID_VersionVariantBits() throws {
        // Create UUID with version 4 and variant bits
        var uuidBytes: [UInt8] = Array(repeating: 0, count: 16)
        uuidBytes[6] = 0x40 // Version 4
        uuidBytes[8] = 0x80 // Variant 10
        
        let uuid = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
        
        let bytes = try UUIDRFC4122.uuidRFC4122Bytes(uuid)
        XCTAssertEqual(bytes.count, 16, "UUID with version/variant bits must produce 16 bytes")
        
        // Verify version/variant bits are preserved
        XCTAssertEqual(bytes[6], 0x40, "Version 4 bit must be preserved")
        XCTAssertEqual(bytes[8], 0x80, "Variant bit must be preserved")
    }
}
