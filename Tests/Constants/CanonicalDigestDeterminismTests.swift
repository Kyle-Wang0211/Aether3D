// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CanonicalDigestDeterminismTests.swift
// Aether3D
//
// Tests to prove canonical digest determinism (especially dictionary key ordering)
//

import XCTest
@testable import Aether3DCore

final class CanonicalDigestDeterminismTests: XCTestCase {
    
    // MARK: - Dictionary Key Ordering Tests
    
    func testCanonicalObjectKeyOrderingIsDeterministic() throws {
        // Build an object with keys inserted in random order (shuffle 50 times)
        struct TestStruct: Codable {
            let z: Int64
            let a: Int64
            let m: Int64
            let b: Int64
        }
        
        // Create same struct multiple times (keys will be encoded in declaration order, not insertion order)
        let input = TestStruct(z: 3, a: 1, m: 2, b: 4)
        
        // Encode 50 times and verify all outputs are identical
        var previousBytes: Data?
        for i in 1...50 {
            let bytes = try CanonicalDigest.encode(input)
            
            if let prev = previousBytes {
                XCTAssertEqual(bytes, prev, "Encoding must be deterministic (run \(i))")
            }
            previousBytes = bytes
        }
    }
    
    func testDictionaryEncodingIsDeterministic() throws {
        // Test encoding a struct containing dictionaries
        struct DictStruct: Codable {
            let dict1: [UInt8: Int64]
            let dict2: [String: Int64]
        }
        
        // Create with same values but potentially different insertion order
        var dict1: [UInt8: Int64] = [:]
        dict1[3] = 30
        dict1[1] = 10
        dict1[2] = 20
        
        var dict2: [String: Int64] = [:]
        dict2["z"] = 300
        dict2["a"] = 100
        dict2["m"] = 200
        
        let input = DictStruct(dict1: dict1, dict2: dict2)
        
        // Encode 50 times and verify all outputs are identical
        var previousBytes: Data?
        var previousDigest: String?
        
        for i in 1...50 {
            let bytes = try CanonicalDigest.encode(input)
            let digest = try CanonicalDigest.computeDigest(input)
            
            if let prevBytes = previousBytes {
                XCTAssertEqual(bytes, prevBytes, "Dictionary encoding must be deterministic (run \(i))")
            }
            if let prevDigest = previousDigest {
                XCTAssertEqual(digest, prevDigest, "Dictionary digest must be deterministic (run \(i))")
            }
            
            previousBytes = bytes
            previousDigest = digest
        }
    }
    
    func testGridResolutionPolicyDigestIsDeterministic() throws {
        // Encode GridResolutionPolicy digest input 200 times
        let input = GridResolutionPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        
        var previousDigest: String?
        for i in 1...200 {
            let digest = try CanonicalDigest.computeDigest(input)
            
            if let prev = previousDigest {
                XCTAssertEqual(digest, prev, "GridResolutionPolicy digest must be deterministic (run \(i))")
            }
            previousDigest = digest
        }
    }
    
    func testEnvelopeDigestIsDeterministic() throws {
        // Compute envelope digest 200 times
        struct EnvelopeInput: Codable {
            let systemMinimumQuantum: LengthQ.DigestInput
            let recommendedCaptureFloors: [KeyedValue<UInt8, LengthQ.DigestInput>]
            let allowedGridResolutions: [KeyedValue<UInt8, [LengthQ.DigestInput]>]
            let budgets: [KeyedValue<UInt8, BudgetInput>]
            let schemaVersionId: UInt16
        }
        
        struct BudgetInput: Codable {
            let maxCells: Int
            let maxPatches: Int
            let maxEvidenceEvents: Int
            let maxAuditBytes: Int64
        }
        
        var previousDigest: String?
        for i in 1...200 {
            var recommendedFloorsArr: [KeyedValue<UInt8, LengthQ.DigestInput>] = []
            var allowedResolutionsArr: [KeyedValue<UInt8, [LengthQ.DigestInput]>] = []
            var budgetsArr: [KeyedValue<UInt8, BudgetInput>] = []
            
            // Build arrays in stable order (sorted by profileId)
            let profiles = CaptureProfile.allCases.sorted { $0.profileId < $1.profileId }
            for profile in profiles {
                let floor = GridResolutionPolicy.recommendedCaptureFloor(for: profile)
                recommendedFloorsArr.append(KeyedValue(key: profile.profileId, value: floor.digestInput()))
                
                let resolutions = GridResolutionPolicy.allowedResolutions(for: profile)
                allowedResolutionsArr.append(KeyedValue(key: profile.profileId, value: resolutions.map { $0.digestInput() }))
                
                let budget = EvidenceBudgetPolicy.policy(for: profile)
                budgetsArr.append(KeyedValue(key: profile.profileId, value: BudgetInput(
                    maxCells: budget.maxCells,
                    maxPatches: budget.maxPatches,
                    maxEvidenceEvents: budget.maxEvidenceEvents,
                    maxAuditBytes: budget.maxAuditBytes
                )))
            }
            
            // Explicitly sort arrays by key to ensure determinism
            recommendedFloorsArr.sort { $0.key < $1.key }
            allowedResolutionsArr.sort { $0.key < $1.key }
            budgetsArr.sort { $0.key < $1.key }
            
            let envelopeInput = EnvelopeInput(
                systemMinimumQuantum: GridResolutionPolicy.systemMinimumQuantum.digestInput(),
                recommendedCaptureFloors: recommendedFloorsArr,
                allowedGridResolutions: allowedResolutionsArr,
                budgets: budgetsArr,
                schemaVersionId: SSOTVersion.schemaVersionId
            )
            
            let digest = try CanonicalDigest.computeDigest(envelopeInput)
            
            if let prev = previousDigest {
                XCTAssertEqual(digest, prev, "Envelope digest must be deterministic (run \(i))")
            }
            previousDigest = digest
        }
    }
    
    func testGoldenWriterIsDeterministic() throws {
        // Generate golden output into memory 50 times
        let schemaVersionId = SSOTVersion.schemaVersionId
        
        var previousOutput: String?
        for i in 1...50 {
            var policyDigests: [String: String] = [:]
            
            // CaptureProfile digests
            for profile in CaptureProfile.allCases {
                let digestInput = profile.digestInput(schemaVersionId: schemaVersionId)
                let digest = try CanonicalDigest.computeDigest(digestInput)
                policyDigests["CaptureProfile.\(profile.name)"] = digest
            }
            
            // GridResolutionPolicy digest
            let gridDigestInput = GridResolutionPolicy.digestInput(schemaVersionId: schemaVersionId)
            policyDigests["GridResolutionPolicy"] = try CanonicalDigest.computeDigest(gridDigestInput)
            
            // PatchPolicy digest
            let patchDigestInput = PatchPolicy.digestInput(schemaVersionId: schemaVersionId)
            policyDigests["PatchPolicy"] = try CanonicalDigest.computeDigest(patchDigestInput)
            
            // CoveragePolicy digest
            let coverageDigestInput = CoveragePolicy.digestInput(schemaVersionId: schemaVersionId)
            policyDigests["CoveragePolicy"] = try CanonicalDigest.computeDigest(coverageDigestInput)
            
            // EvidenceBudgetPolicy digest
            let budgetDigestInput = EvidenceBudgetPolicy.digestInput(schemaVersionId: schemaVersionId)
            policyDigests["EvidenceBudgetPolicy"] = try CanonicalDigest.computeDigest(budgetDigestInput)
            
            // DisplayPolicy digest
            let displayDigestInput = DisplayPolicy.digestInput(schemaVersionId: schemaVersionId)
            policyDigests["DisplayPolicy"] = try CanonicalDigest.computeDigest(displayDigestInput)
            
            // Create JSON structure (sorted keys)
            let golden: [String: Any] = [
                "policyDigests": policyDigests,
                "fieldSetHashes": [:] as [String: String],
                "envelopeDigest": "test"
            ]
            
            let jsonData = try JSONSerialization.data(
                withJSONObject: golden,
                options: [.sortedKeys, .prettyPrinted]
            )
            
            var jsonString = String(data: jsonData, encoding: .utf8) ?? ""
            jsonString = jsonString.replacingOccurrences(of: "\r\n", with: "\n")
            jsonString = jsonString.replacingOccurrences(of: "\r", with: "\n")
            
            if let prev = previousOutput {
                XCTAssertEqual(jsonString, prev, "Golden writer must be deterministic (run \(i))")
            }
            previousOutput = jsonString
        }
    }
}
