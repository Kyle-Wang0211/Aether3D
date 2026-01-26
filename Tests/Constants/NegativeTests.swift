//
// NegativeTests.swift
// Aether3D
//
// Negative tests (must fail if invariants are violated)
//

import XCTest
@testable import Aether3DCore

final class NegativeTests: XCTestCase {
    
    // MARK: - Float Rejection Tests
    
    func testRejectDoubleInDigest() throws {
        struct WithDouble: Codable {
            let value: Double
        }
        
        let input = WithDouble(value: 3.14)
        
        XCTAssertThrowsError(try CanonicalDigest.computeDigest(input)) { error in
            if case CanonicalDigestError.floatForbidden(_, _) = error {
                // Expected
            } else {
                XCTFail("Expected floatForbidden error, got: \(error)")
            }
        }
    }
    
    func testRejectFloatInDigest() throws {
        struct WithFloat: Codable {
            let value: Float
        }
        
        let input = WithFloat(value: 3.14)
        
        XCTAssertThrowsError(try CanonicalDigest.computeDigest(input)) { error in
            if case CanonicalDigestError.floatForbidden(_, _) = error {
                // Expected
            } else {
                XCTFail("Expected floatForbidden error, got: \(error)")
            }
        }
    }
    
    // MARK: - Closed Set Violation Tests
    
    func testInvalidProfileId() {
        // Try to create a VoxelKeySpec with invalid profileId
        let invalidProfileId: UInt8 = 255  // Not a valid CaptureProfile
        let key = VoxelKeySpec(
            qX: 0,
            qY: 0,
            qZ: 0,
            resLevelId: 0,
            schemaVersionId: SSOTVersion.schemaVersionId,
            profileId: invalidProfileId
        )
        
        let errors = VoxelKeySpec.validate(key)
        XCTAssertFalse(errors.isEmpty, "Invalid profileId should be caught")
        XCTAssertTrue(errors.contains { $0.contains("profileId") && $0.contains("invalid") })
    }
    
    func testInvalidSchemaVersionId() {
        let key = VoxelKeySpec(
            qX: 0,
            qY: 0,
            qZ: 0,
            resLevelId: 0,
            schemaVersionId: 999,  // Invalid
            profileId: CaptureProfile.standard.profileId
        )
        
        let errors = VoxelKeySpec.validate(key)
        XCTAssertFalse(errors.isEmpty, "Invalid schemaVersionId should be caught")
        XCTAssertTrue(errors.contains { $0.contains("schemaVersionId") && $0.contains("mismatch") })
    }
    
    func testResolutionNotInClosedSet() {
        let invalidResolution = LengthQ(scaleId: .geomId, quanta: 999)  // Not in closed set
        
        XCTAssertFalse(GridResolutionPolicy.validateResolution(invalidResolution),
                      "Resolution not in closed set should be rejected")
    }
    
    func testResolutionNotAllowedForProfile() {
        let resolution = LengthQ(scaleId: .geomId, quanta: 50)  // 5cm
        let profile = CaptureProfile.smallObjectMacro
        
        // 5cm might not be in smallObjectMacro's allowed set
        let allowed = GridResolutionPolicy.allowedResolutions(for: profile)
        if !allowed.contains(resolution) {
            XCTAssertFalse(GridResolutionPolicy.validateResolution(resolution, for: profile),
                          "Resolution not allowed for profile should be rejected")
        }
    }
    
    // MARK: - VoxelKeySpec Serialization Stability
    
    func testVoxelKeySpecCanonicalSerializeStable() {
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
    
    func testVoxelKeySpecCanonicalSerializeDeterministic() {
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
}
