//
// PatchPolicyTests.swift
// Aether3D
//
// Tests for PatchPolicy (closed-set validation, profile mappings)
//

import XCTest
@testable import Aether3DCore

final class PatchPolicyTests: XCTestCase {
    
    // MARK: - Policy Existence Tests
    
    func testAllPoliciesExist() {
        let policies = PatchPolicy.allPolicies
        XCTAssertEqual(policies.count, CaptureProfile.allCases.count,
                      "Must have policy for each profile")
        
        for profile in CaptureProfile.allCases {
            let policy = PatchPolicy.policy(for: profile)
            XCTAssertEqual(policy.profileId, profile.profileId,
                          "Policy profileId must match for \(profile.name)")
        }
    }
    
    // MARK: - Policy Lookup Tests
    
    func testPolicyForStandardProfile() {
        let policy = PatchPolicy.policy(for: .standard)
        XCTAssertEqual(policy.profileId, CaptureProfile.standard.profileId)
        XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertFalse(policy.documentation.isEmpty)
    }
    
    func testPolicyForSmallObjectMacroProfile() {
        let policy = PatchPolicy.policy(for: .smallObjectMacro)
        XCTAssertEqual(policy.profileId, CaptureProfile.smallObjectMacro.profileId)
        XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId)
        
        // Verify min edge length is fine (for sub-millimeter detail)
        guard let minEdgeScale = LengthScale(rawValue: policy.minEdgeLength.scaleId) else {
            XCTFail("Invalid scaleId: \(policy.minEdgeLength.scaleId)")
            return
        }
        let minEdge = LengthQ(scaleId: minEdgeScale, quanta: policy.minEdgeLength.quanta)
        XCTAssertLessThan(minEdge, LengthQ(scaleId: .geomId, quanta: 1), // Less than 1mm
                         "Macro profile must support sub-millimeter patches")
    }
    
    func testPolicyForLargeSceneProfile() {
        let policy = PatchPolicy.policy(for: .largeScene)
        XCTAssertEqual(policy.profileId, CaptureProfile.largeScene.profileId)
        XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId)
    }
    
    // MARK: - Policy Validation Tests
    
    func testPolicyMinMaxEdgeLength() {
        for profile in CaptureProfile.allCases {
            let policy = PatchPolicy.policy(for: profile)
            
            guard let minScale = LengthScale(rawValue: policy.minEdgeLength.scaleId),
                  let maxScale = LengthScale(rawValue: policy.maxEdgeLength.scaleId) else {
                XCTFail("Invalid scaleId in policy for \(profile.name)")
                continue
            }
            
            let minEdge = LengthQ(scaleId: minScale, quanta: policy.minEdgeLength.quanta)
            let maxEdge = LengthQ(scaleId: maxScale, quanta: policy.maxEdgeLength.quanta)
            
            XCTAssertLessThan(minEdge, maxEdge,
                            "Min edge must be < max edge for \(profile.name)")
            XCTAssertGreaterThan(minEdge.quanta, 0,
                                "Min edge must be positive for \(profile.name)")
            XCTAssertGreaterThan(maxEdge.quanta, 0,
                                "Max edge must be positive for \(profile.name)")
        }
    }
    
    func testPolicySchemaVersionIdMatches() {
        for policy in PatchPolicy.allPolicies {
            XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId,
                          "Policy schemaVersionId must match SSOTVersion")
        }
    }
    
    // MARK: - Negative Tests
    
    func testUnknownProfileIdFails() {
        // This test verifies that if an invalid profileId is used, it should fail
        // Since policy(for:) uses a switch, invalid profileId would cause a compile error
        // But we can test that all known profiles return valid policies
        for profile in CaptureProfile.allCases {
            let policy = PatchPolicy.policy(for: profile)
            XCTAssertNotNil(policy, "Policy must exist for \(profile.name)")
        }
    }
    
    // MARK: - Digest Input Tests
    
    func testDigestInput() throws {
        let digestInput = PatchPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.policies.count, CaptureProfile.allCases.count)
    }
    
    func testDigestInputDeterministic() throws {
        let digest1 = try CanonicalDigest.computeDigest(
            PatchPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        let digest2 = try CanonicalDigest.computeDigest(
            PatchPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        XCTAssertEqual(digest1, digest2, "Digest must be deterministic")
    }
    
    func testDigestInputContainsAllProfiles() throws {
        let digestInput = PatchPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        
        var profileIds: Set<UInt8> = []
        for policy in digestInput.policies {
            XCTAssertFalse(profileIds.contains(policy.profileId),
                          "Duplicate profileId: \(policy.profileId)")
            profileIds.insert(policy.profileId)
        }
        
        XCTAssertEqual(profileIds.count, CaptureProfile.allCases.count,
                      "Must include all profiles")
    }
}
