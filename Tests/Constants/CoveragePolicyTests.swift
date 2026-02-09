// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoveragePolicyTests.swift
// Aether3D
//
// Tests for CoveragePolicy (closed-set validation, profile mappings)
//

import XCTest
@testable import Aether3DCore

final class CoveragePolicyTests: XCTestCase {
    
    // MARK: - Policy Existence Tests
    
    func testAllPoliciesExist() {
        let policies = CoveragePolicy.allPolicies
        XCTAssertEqual(policies.count, CaptureProfile.allCases.count,
                      "Must have policy for each profile")
        
        for profile in CaptureProfile.allCases {
            let policy = CoveragePolicy.policy(for: profile)
            XCTAssertEqual(policy.profileId, profile.profileId,
                          "Policy profileId must match for \(profile.name)")
        }
    }
    
    // MARK: - Policy Validation Tests
    
    func testPolicyMinViewsPerCell() {
        for profile in CaptureProfile.allCases {
            let policy = CoveragePolicy.policy(for: profile)
            XCTAssertGreaterThan(policy.minViewsPerCell, 0,
                                "minViewsPerCell must be positive for \(profile.name)")
        }
    }
    
    func testPolicyMinParallaxBins() {
        for profile in CaptureProfile.allCases {
            let policy = CoveragePolicy.policy(for: profile)
            XCTAssertGreaterThanOrEqual(policy.minParallaxBins, 2,
                                        "minParallaxBins must be >= 2 for \(profile.name)")
        }
    }
    
    func testPolicyMaxHoleDiameter() {
        for profile in CaptureProfile.allCases {
            let policy = CoveragePolicy.policy(for: profile)
            guard let scale = LengthScale(rawValue: policy.maxHoleDiameterAllowed.scaleId) else {
                XCTFail("Invalid scaleId in policy for \(profile.name)")
                continue
            }
            let maxHole = LengthQ(scaleId: scale, quanta: policy.maxHoleDiameterAllowed.quanta)
            XCTAssertGreaterThan(maxHole.quanta, 0,
                                "maxHoleDiameterAllowed must be positive for \(profile.name)")
        }
    }
    
    func testPolicyEvidenceConfidenceLevels() {
        for profile in CaptureProfile.allCases {
            let policy = CoveragePolicy.policy(for: profile)
            XCTAssertFalse(policy.evidenceConfidenceLevels.isEmpty,
                          "Must have at least one confidence level for \(profile.name)")
            
            // Verify all levels are valid
            for levelRaw in policy.evidenceConfidenceLevels {
                XCTAssertNotNil(EvidenceConfidenceLevel(rawValue: levelRaw),
                               "Invalid confidence level: \(levelRaw)")
            }
        }
    }
    
    func testPolicySchemaVersionIdMatches() {
        for policy in CoveragePolicy.allPolicies {
            XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId,
                          "Policy schemaVersionId must match SSOTVersion")
        }
    }
    
    // MARK: - Profile-Specific Tests
    
    func testSmallObjectMacroRequiresMoreViews() {
        let macroPolicy = CoveragePolicy.policy(for: .smallObjectMacro)
        let standardPolicy = CoveragePolicy.policy(for: .standard)
        
        XCTAssertGreaterThanOrEqual(macroPolicy.minViewsPerCell, standardPolicy.minViewsPerCell,
                                   "Macro profile should require >= views than standard")
    }
    
    func testSmallObjectMacroAllowsSmallerHoles() {
        let macroPolicy = CoveragePolicy.policy(for: .smallObjectMacro)
        let standardPolicy = CoveragePolicy.policy(for: .standard)
        
        guard let macroScale = LengthScale(rawValue: macroPolicy.maxHoleDiameterAllowed.scaleId),
              let standardScale = LengthScale(rawValue: standardPolicy.maxHoleDiameterAllowed.scaleId) else {
            XCTFail("Invalid scaleId in policies")
            return
        }
        
        let macroHole = LengthQ(scaleId: macroScale, quanta: macroPolicy.maxHoleDiameterAllowed.quanta)
        let standardHole = LengthQ(scaleId: standardScale, quanta: standardPolicy.maxHoleDiameterAllowed.quanta)
        
        XCTAssertLessThan(macroHole, standardHole,
                         "Macro profile should allow smaller holes")
    }
    
    // MARK: - Digest Input Tests
    
    func testDigestInput() throws {
        let digestInput = CoveragePolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.policies.count, CaptureProfile.allCases.count)
    }
    
    func testDigestInputDeterministic() throws {
        let digest1 = try CanonicalDigest.computeDigest(
            CoveragePolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        let digest2 = try CanonicalDigest.computeDigest(
            CoveragePolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        XCTAssertEqual(digest1, digest2, "Digest must be deterministic")
    }
}
