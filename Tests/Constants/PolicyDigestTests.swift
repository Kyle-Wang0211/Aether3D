// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PolicyDigestTests.swift
// Aether3D
//
// Tests for policy digests (golden file matching, determinism)
//

import XCTest
@testable import Aether3DCore

final class PolicyDigestTests: XCTestCase {
    
    // MARK: - Determinism Tests
    
    func testCanonicalDigestDeterminism() throws {
        struct TestStruct: Codable {
            let a: Int64
            let b: String
            let c: Bool
        }
        
        let input = TestStruct(a: 42, b: "test", c: true)
        
        // Compute digest multiple times
        let digest1 = try CanonicalDigest.computeDigest(input)
        let digest2 = try CanonicalDigest.computeDigest(input)
        let digest3 = try CanonicalDigest.computeDigest(input)
        
        XCTAssertEqual(digest1, digest2, "Digest must be deterministic (run 1 vs 2)")
        XCTAssertEqual(digest2, digest3, "Digest must be deterministic (run 2 vs 3)")
        
        // Also verify byte-level equality
        let bytes1 = try CanonicalDigest.encode(input)
        let bytes2 = try CanonicalDigest.encode(input)
        XCTAssertEqual(bytes1, bytes2, "Canonical encoding must be byte-for-byte identical")
    }
    
    func testKeyOrderingDoesNotAffectDigest() throws {
        struct TestStruct1: Codable {
            let z: Int64
            let a: Int64
            let m: Int64
        }
        
        struct TestStruct2: Codable {
            let a: Int64
            let m: Int64
            let z: Int64
        }
        
        let input1 = TestStruct1(z: 3, a: 1, m: 2)
        let input2 = TestStruct2(a: 1, m: 2, z: 3)
        
        let digest1 = try CanonicalDigest.computeDigest(input1)
        let digest2 = try CanonicalDigest.computeDigest(input2)
        
        // Keys should be sorted lexicographically, so order shouldn't matter
        XCTAssertEqual(digest1, digest2, "Key ordering should not affect digest (keys are sorted)")
    }
    
    // MARK: - Policy Digest Tests
    
    func testCaptureProfileDigest() throws {
        let schemaVersionId = SSOTVersion.schemaVersionId
        for profile in CaptureProfile.allCases {
            let digestInput = profile.digestInput(schemaVersionId: schemaVersionId)
            let digest = try CanonicalDigest.computeDigest(digestInput)
            XCTAssertFalse(digest.isEmpty)
            XCTAssertEqual(digest.count, 64)  // SHA-256 hex string
        }
    }
    
    func testGridResolutionPolicyDigest() throws {
        let digestInput = GridResolutionPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        XCTAssertFalse(digest.isEmpty)
    }
    
    func testPatchPolicyDigest() throws {
        let digestInput = PatchPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        XCTAssertFalse(digest.isEmpty)
    }
    
    func testCoveragePolicyDigest() throws {
        let digestInput = CoveragePolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        XCTAssertFalse(digest.isEmpty)
    }
    
    func testEvidenceBudgetPolicyDigest() throws {
        let digestInput = EvidenceBudgetPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        XCTAssertFalse(digest.isEmpty)
    }
    
    func testDisplayPolicyDigest() throws {
        let digestInput = DisplayPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        XCTAssertFalse(digest.isEmpty)
    }
    
    // MARK: - Golden Digest Tests (if golden file exists)
    
    func testGoldenDigestsMatch() throws {
        // This test will be implemented once golden file is generated
        // For now, just verify we can compute digests
        let schemaVersionId = SSOTVersion.schemaVersionId
        
        let profileDigest = try CanonicalDigest.computeDigest(
            CaptureProfile.standard.digestInput(schemaVersionId: schemaVersionId)
        )
        XCTAssertFalse(profileDigest.isEmpty)
        
        // TODO: Load golden file and compare
        // This requires H3 implementation (repo root detection)
    }
}
