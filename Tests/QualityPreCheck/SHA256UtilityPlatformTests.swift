// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SHA256UtilityPlatformTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Cross-platform SHA256Utility Tests
//  Validates SHA256Utility works identically on all platforms (CryptoKit/Crypto)
//

import XCTest
@testable import Aether3DCore

final class SHA256UtilityPlatformTests: XCTestCase {
    
    /// Test SHA256 of empty string (known vector)
    /// Expected: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    func testSHA256EmptyString() throws {
        let emptyData = Data()
        let hash = SHA256Utility.sha256(emptyData)
        
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(hash, expected, "SHA256 of empty data must match known vector")
        XCTAssertEqual(hash.count, 64, "SHA256 hash must be exactly 64 hex characters")
    }
    
    /// Test SHA256 of "abc" string (known vector)
    /// Expected: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    func testSHA256KnownVectorABC() throws {
        let testString = "abc"
        let hash = SHA256Utility.sha256(testString)
        
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(hash, expected, "SHA256 of 'abc' must match known vector")
        XCTAssertEqual(hash.count, 64, "SHA256 hash must be exactly 64 hex characters")
    }
    
    /// Test SHA256 of "abc" as Data (known vector)
    /// Expected: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    func testSHA256KnownVectorABCData() throws {
        let testData = Data("abc".utf8)
        let hash = SHA256Utility.sha256(testData)
        
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(hash, expected, "SHA256 of 'abc' Data must match known vector")
        XCTAssertEqual(hash.count, 64, "SHA256 hash must be exactly 64 hex characters")
    }
    
    /// Test determinism: same input produces same output
    func testSHA256Determinism() throws {
        let testData = Data("test payload".utf8)
        
        let hash1 = SHA256Utility.sha256(testData)
        let hash2 = SHA256Utility.sha256(testData)
        let hash3 = SHA256Utility.sha256(testData)
        
        // All hashes must be identical
        XCTAssertEqual(hash1, hash2, "SHA256 must be deterministic (first vs second call)")
        XCTAssertEqual(hash2, hash3, "SHA256 must be deterministic (second vs third call)")
        XCTAssertEqual(hash1.count, 64, "SHA256 hash must be exactly 64 hex characters")
    }
    
    /// Test SHA256 concatenation utility
    func testSHA256Concatenation() throws {
        let chunk1 = Data("hello".utf8)
        let chunk2 = Data("world".utf8)
        
        // Concatenate manually
        var manual = Data()
        manual.append(chunk1)
        manual.append(chunk2)
        let hashManual = SHA256Utility.sha256(manual)
        
        // Use concatenation utility
        let hashConcatenated = SHA256Utility.sha256(concatenating: chunk1, chunk2)
        
        XCTAssertEqual(hashManual, hashConcatenated, "Concatenation utility must match manual concatenation")
        XCTAssertEqual(hashConcatenated.count, 64, "SHA256 hash must be exactly 64 hex characters")
    }
    
    /// Test SHA256 with multiple chunks
    func testSHA256MultipleChunks() throws {
        let chunk1 = Data("a".utf8)
        let chunk2 = Data("b".utf8)
        let chunk3 = Data("c".utf8)
        
        let hash = SHA256Utility.sha256(concatenating: chunk1, chunk2, chunk3)
        
        // Should match hash of "abc"
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(hash, expected, "Multiple chunks must hash to same value as concatenated string")
        XCTAssertEqual(hash.count, 64, "SHA256 hash must be exactly 64 hex characters")
    }
}

