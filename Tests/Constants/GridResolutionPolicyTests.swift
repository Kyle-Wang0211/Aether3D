//
// GridResolutionPolicyTests.swift
// Aether3D
//
// Tests for GridResolutionPolicy (closed-set validation, profile mappings)
//

import XCTest
@testable import Aether3DCore

#if canImport(Crypto)
import Crypto
#else
#error("Crypto module required")
#endif

final class GridResolutionPolicyTests: XCTestCase {
    
    // MARK: - System Minimum Quantum Tests
    
    func testSystemMinimumQuantum() {
        let quantum = GridResolutionPolicy.systemMinimumQuantum
        XCTAssertEqual(quantum.scaleId, .systemMinimum)
        XCTAssertEqual(quantum.quanta, 1)
        XCTAssertEqual(quantum.toMeters(), 0.00005, accuracy: 1e-6) // 0.05mm
    }
    
    // MARK: - Recommended Capture Floor Tests
    
    func testRecommendedCaptureFloorForAllProfiles() {
        for profile in CaptureProfile.allCases {
            let floor = GridResolutionPolicy.recommendedCaptureFloor(for: profile)
            XCTAssertGreaterThan(floor.quanta, 0, "Floor must be positive for \(profile.name)")
            
            // Floor must be >= system minimum
            let systemMin = GridResolutionPolicy.systemMinimumQuantum
            XCTAssertGreaterThanOrEqual(floor.scaleId.quantumInNanometers, systemMin.scaleId.quantumInNanometers,
                                       "Floor scale must be >= system minimum for \(profile.name)")
        }
    }
    
    func testRecommendedCaptureFloorValues() {
        let standardFloor = GridResolutionPolicy.recommendedCaptureFloorStandard
        XCTAssertEqual(standardFloor.scaleId, .geomId)
        XCTAssertEqual(standardFloor.quanta, 1) // 1mm
        
        let macroFloor = GridResolutionPolicy.recommendedCaptureFloorSmallObjectMacro
        XCTAssertEqual(macroFloor.scaleId, .systemMinimum)
        XCTAssertEqual(macroFloor.quanta, 5) // 0.25mm
        
        let sceneFloor = GridResolutionPolicy.recommendedCaptureFloorLargeScene
        XCTAssertEqual(sceneFloor.scaleId, .geomId)
        XCTAssertEqual(sceneFloor.quanta, 5) // 5mm
    }
    
    // MARK: - Closed Set Validation Tests
    
    func testAllowedGridCellSizesIsClosedSet() {
        let allowed = GridResolutionPolicy.allowedGridCellSizes
        XCTAssertGreaterThan(allowed.count, 0, "Must have at least one allowed resolution")
        
        // Verify all are unique
        var seen: Set<LengthQ> = []
        for resolution in allowed {
            XCTAssertFalse(seen.contains(resolution), "Duplicate resolution: \(resolution)")
            seen.insert(resolution)
        }
    }
    
    func testValidateResolutionInClosedSet() {
        for resolution in GridResolutionPolicy.allowedGridCellSizes {
            XCTAssertTrue(GridResolutionPolicy.validateResolution(resolution),
                          "Resolution \(resolution) should be valid")
        }
    }
    
    func testValidateResolutionNotInClosedSet() {
        // Create a resolution not in the closed set
        let invalidResolution = LengthQ(scaleId: .geomId, quanta: 999)
        XCTAssertFalse(GridResolutionPolicy.validateResolution(invalidResolution),
                      "Resolution not in closed set should be rejected")
    }
    
    // MARK: - Profile Mapping Tests
    
    func testAllowedResolutionsForStandardProfile() {
        let resolutions = GridResolutionPolicy.allowedResolutions(for: .standard)
        XCTAssertGreaterThan(resolutions.count, 0)
        
        // Verify all are in closed set
        for resolution in resolutions {
            XCTAssertTrue(GridResolutionPolicy.validateResolution(resolution),
                         "Resolution \(resolution) must be in closed set")
        }
        
        // Verify specific values (2mm, 5mm, 1cm, 2cm, 5cm)
        let expected = [
            LengthQ(scaleId: .geomId, quanta: 2),
            LengthQ(scaleId: .geomId, quanta: 5),
            LengthQ(scaleId: .geomId, quanta: 10),
            LengthQ(scaleId: .geomId, quanta: 20),
            LengthQ(scaleId: .geomId, quanta: 50),
        ]
        XCTAssertEqual(resolutions, expected)
    }
    
    func testAllowedResolutionsForSmallObjectMacroProfile() {
        let resolutions = GridResolutionPolicy.allowedResolutions(for: .smallObjectMacro)
        XCTAssertGreaterThan(resolutions.count, 0)
        
        // Verify all are in closed set
        for resolution in resolutions {
            XCTAssertTrue(GridResolutionPolicy.validateResolution(resolution),
                         "Resolution \(resolution) must be in closed set")
        }
        
        // Verify includes fine resolutions (0.25mm, 0.5mm)
        let fineResolutions = resolutions.filter { $0.scaleId == .systemMinimum }
        XCTAssertGreaterThan(fineResolutions.count, 0, "Must include fine resolutions for macro profile")
    }
    
    func testAllowedResolutionsForLargeSceneProfile() {
        let resolutions = GridResolutionPolicy.allowedResolutions(for: .largeScene)
        XCTAssertGreaterThan(resolutions.count, 0)
        
        // Verify all are in closed set
        for resolution in resolutions {
            XCTAssertTrue(GridResolutionPolicy.validateResolution(resolution),
                         "Resolution \(resolution) must be in closed set")
        }
        
        // Verify no fine resolutions (should be >= 5mm)
        let fineResolutions = resolutions.filter { $0.scaleId == .systemMinimum }
        XCTAssertEqual(fineResolutions.count, 0, "Large scene should not include fine resolutions")
    }
    
    func testValidateResolutionForProfile() {
        // Valid resolution for standard profile
        let valid = LengthQ(scaleId: .geomId, quanta: 5) // 5mm
        XCTAssertTrue(GridResolutionPolicy.validateResolution(valid, for: .standard))
        
        // Invalid resolution for standard profile (too fine)
        let invalid = LengthQ(scaleId: .systemMinimum, quanta: 5) // 0.25mm
        XCTAssertFalse(GridResolutionPolicy.validateResolution(invalid, for: .standard))
    }
    
    // MARK: - Digest Input Tests
    
    func testDigestInput() throws {
        let digestInput = GridResolutionPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertFalse(digestInput.allowedGridCellSizes.isEmpty)
        XCTAssertFalse(digestInput.recommendedCaptureFloors.isEmpty)
        XCTAssertFalse(digestInput.profileMappings.isEmpty)
    }
    
    func testDigestInputDeterministic() throws {
        let digest1 = try CanonicalDigest.computeDigest(
            GridResolutionPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        let digest2 = try CanonicalDigest.computeDigest(
            GridResolutionPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        XCTAssertEqual(digest1, digest2, "Digest must be deterministic")
    }
    
    func testDigestInputContainsAllProfiles() throws {
        let digestInput = GridResolutionPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        
        for profile in CaptureProfile.allCases {
            let floorFound = digestInput.recommendedCaptureFloors.contains { $0.key == profile.profileId }
            XCTAssertTrue(floorFound, "Must include floor for \(profile.name)")
            
            let mappingFound = digestInput.profileMappings.contains { $0.key == profile.profileId }
            XCTAssertTrue(mappingFound, "Must include mapping for \(profile.name)")
        }
    }
}
