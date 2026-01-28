//
// VoxelKeySpecTests.swift
// Aether3D
//
// Tests for VoxelKeySpec (integer domain, canonical serialization)
//

import XCTest
@testable import Aether3DCore

final class VoxelKeySpecTests: XCTestCase {
    
    // MARK: - Creation Tests
    
    func testCreateValidVoxelKeySpec() {
        let key = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        XCTAssertEqual(key.qX, 100)
        XCTAssertEqual(key.qY, 200)
        XCTAssertEqual(key.qZ, 300)
        XCTAssertEqual(key.resLevelId, 1)
        XCTAssertEqual(key.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertEqual(key.profileId, CaptureProfile.standard.profileId)
    }
    
    // MARK: - Validation Tests
    
    func testValidateValidKey() {
        let key = VoxelKeySpec(
            qX: 0,
            qY: 0,
            qZ: 0,
            resLevelId: 0,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let errors = VoxelKeySpec.validate(key)
        XCTAssertTrue(errors.isEmpty, "Valid key should have no errors")
    }
    
    func testValidateInvalidProfileId() {
        let invalidProfileId: UInt8 = 255
        let key = VoxelKeySpec(
            qX: 0,
            qY: 0,
            qZ: 0,
            resLevelId: 0,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: invalidProfileId
        )
        
        let errors = VoxelKeySpec.validate(key)
        XCTAssertFalse(errors.isEmpty, "Invalid profileId should produce errors")
        XCTAssertTrue(errors.contains { $0.contains("profileId") && $0.contains("invalid") })
    }
    
    func testValidateInvalidSchemaVersionId() {
        let key = VoxelKeySpec(
            qX: 0,
            qY: 0,
            qZ: 0,
            resLevelId: 0,
            schemaVersionId: 999, // Invalid
            profileId: CaptureProfile.standard.profileId
        )
        
        let errors = VoxelKeySpec.validate(key)
        XCTAssertFalse(errors.isEmpty, "Invalid schemaVersionId should produce errors")
        XCTAssertTrue(errors.contains { $0.contains("schemaVersionId") && $0.contains("mismatch") })
    }
    
    func testValidateNegativeResLevelId() {
        let key = VoxelKeySpec(
            qX: 0,
            qY: 0,
            qZ: 0,
            resLevelId: -1, // Invalid
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let errors = VoxelKeySpec.validate(key)
        XCTAssertFalse(errors.isEmpty, "Negative resLevelId should produce errors")
        XCTAssertTrue(errors.contains { $0.contains("resLevelId") && $0.contains("non-negative") })
    }
    
    // MARK: - Canonical Serialization Tests
    
    func testCanonicalSerializeStable() {
        let key = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let bytes1 = key.canonicalSerialize()
        let bytes2 = key.canonicalSerialize()
        let bytes3 = key.canonicalSerialize()
        
        XCTAssertEqual(bytes1, bytes2, "Serialization must be stable (run 1 vs 2)")
        XCTAssertEqual(bytes2, bytes3, "Serialization must be stable (run 2 vs 3)")
    }
    
    func testCanonicalSerializeDeterministic() {
        let key1 = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let key2 = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let bytes1 = key1.canonicalSerialize()
        let bytes2 = key2.canonicalSerialize()
        
        XCTAssertEqual(bytes1, bytes2, "Same key must serialize to same bytes")
    }
    
    func testCanonicalSerializeOrder() {
        // Verify serialization order: qX, qY, qZ, resLevelId, schemaVersionId, profileId
        let key = VoxelKeySpec(
            qX: 0x0102030405060708,
            qY: 0x1112131415161718,
            qZ: 0x2122232425262728,
            resLevelId: 42,
            schemaVersionId: 0xABCD,
            profileId: 0xEF
        )
        
        let bytes = key.canonicalSerialize()
        XCTAssertEqual(bytes.count, 8 + 8 + 8 + 8 + 2 + 1, // Int64 + Int64 + Int64 + Int64 + UInt16 + UInt8
                      "Serialization must have correct length")
    }
    
    // MARK: - Hashable Tests
    
    func testHashable() {
        let key1 = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let key2 = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        XCTAssertEqual(key1.hashValue, key2.hashValue, "Equal keys must have same hash")
    }
    
    // MARK: - Equatable Tests
    
    func testEquatable() {
        let key1 = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let key2 = VoxelKeySpec(
            qX: 100,
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        let key3 = VoxelKeySpec(
            qX: 101, // Different
            qY: 200,
            qZ: 300,
            resLevelId: 1,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: CaptureProfile.standard.profileId
        )
        
        XCTAssertEqual(key1, key2, "Equal keys must be equal")
        XCTAssertNotEqual(key1, key3, "Different keys must not be equal")
    }
}
