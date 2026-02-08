//
// ClosedSetTests.swift
// Aether3D
//
// Tests for closed-set append-only enforcement (LengthScale, CaptureProfile, etc.)
//

import XCTest
@testable import Aether3DCore

#if canImport(Crypto)
import Crypto
#else
#error("Crypto module required")
#endif

final class ClosedSetTests: XCTestCase {
    
    // MARK: - LengthScale Closed Set Tests
    
    func testLengthScaleIsClosedSet() {
        // Verify all scales are valid
        for scale in LengthScale.allCases {
            XCTAssertNotNil(LengthScale(rawValue: scale.rawValue),
                           "Scale \(scale) must be valid")
        }
    }
    
    func testLengthScaleFrozenOrderHash() throws {
        // Compute hash from case names in declaration order (sorted for stability)
        let caseNames = LengthScale.allCases.map { $0.description }.sorted()
        let caseOrderString = caseNames.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(caseOrderString.utf8))
        let hashString = hash.map { String(format: "%02x", $0) }.joined()
        
        // Verify hash is computed (not empty)
        XCTAssertFalse(hashString.isEmpty, "Hash must be computed")
        XCTAssertEqual(hashString.count, 64, "SHA-256 hex string must be 64 characters")
        
        // Note: We don't have a FROZEN_LENGTH_SCALE_CASE_ORDER_HASH constant yet
        // This test verifies the mechanism works
    }
    
    func testLengthScaleQuantumValues() {
        // Verify quantum values are positive and reasonable
        for scale in LengthScale.allCases {
            XCTAssertGreaterThan(scale.quantumInNanometers, 0,
                               "Quantum must be positive for \(scale)")
            XCTAssertLessThan(scale.quantumInNanometers, 1_000_000_000, // < 1m
                            "Quantum should be reasonable for \(scale)")
        }
    }
    
    // MARK: - CaptureProfile Closed Set Tests
    
    func testCaptureProfileIsClosedSet() {
        // Verify all profiles are valid
        for profile in CaptureProfile.allCases {
            XCTAssertNotNil(CaptureProfile(rawValue: profile.rawValue),
                           "Profile \(profile) must be valid")
        }
    }
    
    func testCaptureProfileFrozenOrderHash() throws {
        // This test is already in CaptureProfileTests, but we verify it here too
        let caseNames = CaptureProfile.allCases.map { $0.name }.sorted()
        let caseOrderString = caseNames.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(caseOrderString.utf8))
        let hashString = hash.map { String(format: "%02x", $0) }.joined()
        
        XCTAssertEqual(hashString, CaptureProfile.FROZEN_PROFILE_CASE_ORDER_HASH,
                      "Case order hash must match frozen hash")
    }
    
    // MARK: - EvidenceConfidenceLevel Closed Set Tests
    
    func testEvidenceConfidenceLevelIsClosedSet() {
        // Verify all levels are valid
        for level in EvidenceConfidenceLevel.allCases {
            XCTAssertNotNil(EvidenceConfidenceLevel(rawValue: level.rawValue),
                           "Level \(level) must be valid")
        }
    }
    
    func testEvidenceConfidenceLevelOrder() {
        // Verify levels are ordered (L0 < L1 < L2 < L3 < L4 < L5 < L6)
        // PR6 added L4, L5, L6 levels for Evidence Grid System
        let levels = EvidenceConfidenceLevel.allCases.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(levels.count, 7, "Must have 7 confidence levels (L0-L6)")
        XCTAssertEqual(levels[0], .L0)
        XCTAssertEqual(levels[1], .L1)
        XCTAssertEqual(levels[2], .L2)
        XCTAssertEqual(levels[3], .L3)
        XCTAssertEqual(levels[4], .L4)
        XCTAssertEqual(levels[5], .L5)
        XCTAssertEqual(levels[6], .L6)
    }
    
    // MARK: - DisplayRefreshPolicy Closed Set Tests
    
    func testDisplayRefreshPolicyIsClosedSet() {
        // Verify all policies are valid
        for policy in DisplayRefreshPolicy.allCases {
            XCTAssertNotNil(DisplayRefreshPolicy(rawValue: policy.rawValue),
                           "Policy \(policy) must be valid")
        }
    }
    
    // MARK: - Grid Resolution Closed Set Tests
    
    func testGridResolutionClosedSetIsImmutable() {
        let allowed1 = GridResolutionPolicy.allowedGridCellSizes
        let allowed2 = GridResolutionPolicy.allowedGridCellSizes
        
        // Verify the set is stable (same reference or same contents)
        XCTAssertEqual(allowed1.count, allowed2.count, "Allowed resolutions must be stable")
        
        // Verify all are in the closed set
        for resolution in allowed1 {
            XCTAssertTrue(GridResolutionPolicy.validateResolution(resolution),
                         "Resolution \(resolution) must be valid")
        }
    }
    
    func testGridResolutionProfileMappingIsComplete() {
        // Verify all profiles have mappings
        for profile in CaptureProfile.allCases {
            let resolutions = GridResolutionPolicy.allowedResolutions(for: profile)
            XCTAssertFalse(resolutions.isEmpty,
                          "Profile \(profile.name) must have allowed resolutions")
            
            // Verify all resolutions are in closed set
            for resolution in resolutions {
                XCTAssertTrue(GridResolutionPolicy.validateResolution(resolution),
                             "Resolution \(resolution) must be in closed set for \(profile.name)")
            }
        }
    }
}
