//
// DeterministicEncodingContractTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Deterministic Encoding Contract Tests (A2)
//
// This test file validates deterministic encoding contract compliance.
//

import XCTest
@testable import Aether3DCore

/// Tests for deterministic encoding contract (A2).
///
/// **Rule ID:** A2, CROSS_PLATFORM_HASH_001A
/// **Status:** IMMUTABLE
final class DeterministicEncodingContractTests: XCTestCase {
    
    func test_stringEncoding_lengthPrefixed_consistency() throws {
        let input = "hello"
        let encoded = try DeterministicEncoding.encodeString(input)
        
        // Should be: uint32_be(5) + UTF-8("hello")
        XCTAssertEqual(encoded.count, 4 + 5) // 4 bytes length + 5 bytes UTF-8
        
        // Verify length prefix is Big-Endian
        let lengthBytes = encoded.prefix(4)
        let length = UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
        XCTAssertEqual(length, 5)
    }
    
    func test_stringEncoding_emptyString_handling() throws {
        let encoded = DeterministicEncoding.encodeEmptyString()
        
        // Should be: uint32_be(0)
        XCTAssertEqual(encoded.count, 4)
        let length = UInt32(bigEndian: encoded.withUnsafeBytes { $0.load(as: UInt32.self) })
        XCTAssertEqual(length, 0)
    }
    
    func test_stringEncoding_embeddedNul_forbidden() {
        // Embedded NUL bytes are forbidden
        let inputWithNul = "hello\u{0000}world"
        XCTAssertThrowsError(try DeterministicEncoding.encodeString(inputWithNul)) { error in
            if case DeterministicEncoding.EncodingError.embeddedNulByte = error {
                // Expected
            } else {
                XCTFail("Expected embeddedNulByte error")
            }
        }
    }
    
    func test_stringEncoding_nfc_normalization() throws {
        // NFC normalization should be applied
        let nfd = "cafe\u{0301}" // NFD form
        let nfc = "café" // NFC form
        
        let encodedNFD = try DeterministicEncoding.encodeString(nfd)
        let encodedNFC = try DeterministicEncoding.encodeString(nfc)
        
        // Should produce same bytes after normalization
        XCTAssertEqual(encodedNFD, encodedNFC)
    }
    
    func test_integerBigEndian_encoding_consistency() {
        let value: Int64 = 1234567890
        let encoded = DeterministicEncoding.encodeInt64BE(value)
        
        // Verify Big-Endian encoding
        let decoded = Int64(bigEndian: encoded.withUnsafeBytes { $0.load(as: Int64.self) })
        XCTAssertEqual(decoded, value)
    }
    
    func test_domainSeparationPrefix_encoding_consistency() throws {
        let prefix = DeterministicEncoding.DOMAIN_PREFIX_PATCH_ID
        let encoded = try DeterministicEncoding.encodeDomainPrefix(prefix)
        
        // Should use same encoding rules as strings
        XCTAssertGreaterThan(encoded.count, 4) // At least length prefix
    }
}
