// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DecisionHashPreimageTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - DecisionHash Preimage Instrumentation Tests
//
// Verifies preimage bytes construction for cross-platform determinism
//

import XCTest
@testable import Aether3DCore

final class DecisionHashPreimageTests: XCTestCase {
    /// Test DOMAIN_TAG matches SSOT locked length and hex
    func testDomainTag_MatchesSSOT() {
        XCTAssertEqual(DecisionHashV1.domainTagLength, 26, "DOMAIN_TAG length must match SSOT locked length (26 bytes)")
        XCTAssertEqual(DecisionHashV1.domainTagHex, "41455448455233445f4445434953494f4e5f484153485f563100", "DOMAIN_TAG hex must match SSOT")
    }
    
    /// Test preimage construction for a known input
    func testPreimage_Construction() throws {
        // Create a minimal canonical input (example)
        let canonicalInput = Data([0x01, 0x00, 0x01, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])
        
        let preimageHex = DecisionHashV1.debugPreimageHex(inputBytes: canonicalInput)
        let preimageLength = DecisionHashV1.debugPreimageLength(inputBytes: canonicalInput)
        
        // Verify preimage length = domainTagLength + inputLength
        XCTAssertEqual(preimageLength, 26 + canonicalInput.count, "Preimage length must be domainTagLength + inputLength")
        
        // Verify preimage starts with domain tag
        let domainTagHex = DecisionHashV1.domainTagHex
        XCTAssertTrue(preimageHex.hasPrefix(domainTagHex), "Preimage must start with domain tag")
        
        // Verify preimage hex length matches byte count
        XCTAssertEqual(preimageHex.count, preimageLength * 2, "Preimage hex length must be 2 * byte count")
    }
    
    /// Test preimage fixture generation (for cross-platform verification)
    func testPreimage_GenerateFixture() throws {
        // Create a deterministic canonical input for fixture
        let writer = CanonicalBytesWriter()
        writer.writeUInt8(1) // layoutVersion
        writer.writeUInt16BE(0x0001) // decisionSchemaVersion
        writer.writeUInt64BE(0x123456789ABCDEF0) // policyHash
        writer.writeUInt64BE(0xFEDCBA9876543210) // sessionStableId
        writer.writeUInt64BE(0x0123456789ABCDEF) // candidateStableId
        writer.writeUInt8(2) // classification (ACCEPTED)
        writer.writeUInt8(0) // rejectReasonTag (absent)
        writer.writeUInt8(0) // shedDecisionTag (absent)
        writer.writeUInt8(0) // shedReasonTag (absent)
        writer.writeUInt8(0) // degradationLevel
        writer.writeUInt8(0) // degradationReasonCodeTag (absent)
        writer.writeInt64BE(1000) // valueScore
        writer.writeUInt8(4) // flowBucketCount
        try writer.writeFixedArrayUInt16BE(array: [1, 2, 3, 4], expectedCount: 4) // perFlowCounters
        writer.writeUInt8(0) // throttleStatsTag (absent)
        
        let canonicalInput = writer.toData()
        let preimageHex = DecisionHashV1.debugPreimageHex(inputBytes: canonicalInput)
        let preimageLength = DecisionHashV1.debugPreimageLength(inputBytes: canonicalInput)
        
        // Print for fixture generation (will be committed as fixture file)
        print("Preimage length: \(preimageLength) bytes")
        print("Preimage hex: \(preimageHex)")
        
        // Verify structure
        XCTAssertEqual(preimageLength, 26 + canonicalInput.count, "Preimage length must match")
        XCTAssertTrue(preimageHex.hasPrefix(DecisionHashV1.domainTagHex), "Preimage must start with domain tag")
    }
}
