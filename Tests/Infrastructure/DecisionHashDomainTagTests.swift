//
// DecisionHashDomainTagTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - DecisionHash Domain Tag Golden Tests
//
// Verifies DOMAIN_TAG is exact and matches SSOT spec
//

import XCTest
@testable import Aether3DCore

final class DecisionHashDomainTagTests: XCTestCase {
    /// Test DOMAIN_TAG length matches SSOT spec (26 bytes)
    func testDomainTag_LengthMatchesSSOT() {
        let expectedLength = 26
        XCTAssertEqual(DecisionHashV1.domainTagLength, expectedLength, "DOMAIN_TAG length must be exactly 26 bytes per SSOT")
        XCTAssertEqual(DecisionHashV1.domainTagBytes.count, expectedLength, "DOMAIN_TAG bytes count must match locked length")
    }
    
    /// Test DOMAIN_TAG hex matches expected spec
    /// 
    /// **Expected:** ASCII("AETHER3D_DECISION_HASH_V1") || 0x00
    /// **Hex:** 41 45 54 48 45 52 33 44 5F 44 45 43 49 53 49 4F 4E 5F 48 41 53 48 5F 56 31 00
    func testDomainTag_HexMatchesSpec() {
        let expectedHex = "41455448455233445f4445434953494f4e5f484153485f563100"
        let actualHex = DecisionHashV1.domainTagHex
        XCTAssertEqual(actualHex, expectedHex, "DOMAIN_TAG hex must match SSOT spec")
    }
    
    /// Test DOMAIN_TAG ends with 0x00 terminator
    func testDomainTag_EndsWithNullTerminator() {
        let bytes = DecisionHashV1.domainTagBytes
        XCTAssertEqual(bytes.last, 0x00, "DOMAIN_TAG must end with 0x00 terminator")
        XCTAssertEqual(bytes.count, 26, "DOMAIN_TAG must be exactly 26 bytes")
    }
    
    /// Test DOMAIN_TAG starts with expected ASCII prefix
    func testDomainTag_StartsWithExpectedPrefix() {
        let bytes = DecisionHashV1.domainTagBytes
        let expectedPrefix = Array("AETHER3D_DECISION_HASH_V1".utf8)
        let actualPrefix = Array(bytes.prefix(expectedPrefix.count))
        XCTAssertEqual(actualPrefix, expectedPrefix, "DOMAIN_TAG must start with ASCII('AETHER3D_DECISION_HASH_V1')")
    }
}
