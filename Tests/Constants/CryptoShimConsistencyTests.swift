// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CryptoShimConsistencyTests.swift
//  Aether3D
//
//  PR#1 SSOT Foundation v1.1.1 - Crypto Shim Consistency Tests
//  Ensures SHA-256 output is identical across Apple (CryptoKit) and Linux (swift-crypto Crypto)
//

import XCTest
@testable import Aether3DCore

/// Tests for cross-platform crypto shim consistency.
///
/// **Purpose:** Validates that CryptoShim produces identical SHA-256 outputs
/// on both Apple platforms (CryptoKit) and Linux (swift-crypto Crypto).
///
/// **Rule ID:** Cross-platform determinism (Linux CI compatibility)
/// **Status:** IMMUTABLE
///
/// These tests ensure:
/// - SHA-256 hash output is byte-for-byte identical across platforms
/// - Hex encoding is consistent (lowercase, no uppercase drift)
/// - Empty, short, and long inputs all produce correct outputs
/// - Known test vectors match expected digests
final class CryptoShimConsistencyTests: XCTestCase {
    
    // MARK: - Known Test Vectors (RFC 6234 / NIST FIPS 180-2)
    
    /// Empty string SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    func test_sha256_emptyString() {
        let input = ""
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let actual = CryptoShim.sha256Hex(input)
        XCTAssertEqual(actual, expected, "Empty string SHA-256 must match known digest")
        XCTAssertEqual(actual.count, 64, "SHA-256 hex must be exactly 64 characters")
    }
    
    /// "abc" SHA-256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    func test_sha256_abc() {
        let input = "abc"
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let actual = CryptoShim.sha256Hex(input)
        XCTAssertEqual(actual, expected, "'abc' SHA-256 must match known digest")
    }
    
    /// "The quick brown fox jumps over the lazy dog" SHA-256: d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592
    func test_sha256_quickBrownFox() {
        let input = "The quick brown fox jumps over the lazy dog"
        let expected = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        let actual = CryptoShim.sha256Hex(input)
        XCTAssertEqual(actual, expected, "Quick brown fox SHA-256 must match known digest")
    }
    
    /// "The quick brown fox jumps over the lazy dog." (with period) SHA-256: ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c
    func test_sha256_quickBrownFoxWithPeriod() {
        let input = "The quick brown fox jumps over the lazy dog."
        let expected = "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c"
        let actual = CryptoShim.sha256Hex(input)
        XCTAssertEqual(actual, expected, "Quick brown fox with period SHA-256 must match known digest")
    }
    
    // MARK: - Data Input Tests
    
    /// Test SHA-256 with Data input (empty)
    func test_sha256_emptyData() {
        let input = Data()
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let actual = CryptoShim.sha256Hex(input)
        XCTAssertEqual(actual, expected, "Empty Data SHA-256 must match empty string digest")
    }
    
    /// Test SHA-256 with Data input (non-empty)
    func test_sha256_dataInput() {
        let input = Data("test".utf8)
        let expected = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        let actual = CryptoShim.sha256Hex(input)
        XCTAssertEqual(actual, expected, "Data input SHA-256 must match expected digest")
    }
    
    // MARK: - Hex Format Consistency
    
    /// Ensure hex output is always lowercase
    func test_sha256_hexLowercase() {
        let input = "test"
        let result = CryptoShim.sha256Hex(input)
        let allLowercase = result.allSatisfy { $0.isLowercase || $0.isNumber }
        XCTAssertTrue(allLowercase, "SHA-256 hex output must be lowercase: \(result)")
    }
    
    /// Ensure hex output length is always 64 characters
    func test_sha256_hexLength() {
        let testCases = ["", "a", "abc", "The quick brown fox jumps over the lazy dog", "a".repeating(1000)]
        for input in testCases {
            let result = CryptoShim.sha256Hex(input)
            XCTAssertEqual(result.count, 64, "SHA-256 hex must be exactly 64 characters for input: '\(input.prefix(20))...'")
        }
    }
    
    // MARK: - Digest Bytes Consistency
    
    /// Ensure digest bytes are consistent with hex output
    func test_sha256_digestBytesConsistency() {
        let input = "test"
        let hexResult = CryptoShim.sha256Hex(input)
        let inputData = Data(input.utf8)
        let digestBytes = CryptoShim.sha256Digest(inputData)
        
        // Convert digest bytes to hex and compare
        let hexFromBytes = digestBytes.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hexFromBytes, hexResult, "Digest bytes converted to hex must match sha256Hex output")
        XCTAssertEqual(digestBytes.count, 32, "SHA-256 digest must be exactly 32 bytes")
    }
    
    // MARK: - Cross-Platform Determinism
    
    /// Test that multiple calls produce identical output (determinism)
    func test_sha256_determinism() {
        let input = "deterministic test input"
        let first = CryptoShim.sha256Hex(input)
        let second = CryptoShim.sha256Hex(input)
        let third = CryptoShim.sha256Hex(input)
        
        XCTAssertEqual(first, second, "SHA-256 must be deterministic (first == second)")
        XCTAssertEqual(second, third, "SHA-256 must be deterministic (second == third)")
        XCTAssertEqual(first, third, "SHA-256 must be deterministic (first == third)")
    }
    
    // MARK: - Edge Cases
    
    /// Test with Unicode string
    func test_sha256_unicodeString() {
        let input = "Hello, 世界 🌍"
        let result = CryptoShim.sha256Hex(input)
        XCTAssertEqual(result.count, 64, "Unicode string SHA-256 must be 64 hex characters")
        // Verify it's valid hex and correct length
        XCTAssertTrue(result.allSatisfy { $0.isHexDigit }, "Unicode string SHA-256 must be valid hex")
    }
    
    /// Test with long string (stress test)
    func test_sha256_longString() {
        let input = String(repeating: "a", count: 10000)
        let result = CryptoShim.sha256Hex(input)
        XCTAssertEqual(result.count, 64, "Long string SHA-256 must be 64 hex characters")
        XCTAssertTrue(result.allSatisfy { $0.isHexDigit }, "Long string SHA-256 must be valid hex")
    }
    
    /// Test digest bytes with Data input
    func test_sha256_digestBytesWithData() {
        let input = Data("test".utf8)
        let digestBytes = CryptoShim.sha256Digest(input)
        XCTAssertEqual(digestBytes.count, 32, "SHA-256 digest must be exactly 32 bytes")
    }
}

// MARK: - Character Extensions
// Note: isHexDigit is defined in Tests/Support/FixtureLoader.swift

private extension String {
    func repeating(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}
