// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BLAKE3DirectAPITests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Direct BLAKE3 API Verification
//
// Verifies BLAKE3 library API usage is correct
//

import XCTest
@testable import Aether3DCore
#if canImport(BLAKE3)
import BLAKE3
#endif

final class BLAKE3DirectAPITests: XCTestCase {
    /// Test direct BLAKE3.hash() API usage
    /// 
    /// Verifies we're using the correct API and getting correct output
    #if canImport(BLAKE3)
    func testBlake3_DirectAPI_Abc() throws {
        let testInput = Data("abc".utf8)
        
        // Direct BLAKE3 library call
        let directHash = BLAKE3.hash(contentsOf: testInput, outputByteCount: 32)
        
        // Our facade call
        let facadeHash = try Blake3Facade.blake3_256(data: testInput)
        
        // They should match
        XCTAssertEqual(directHash, facadeHash, "Direct API and facade must produce same output")
        
        // Print for reference
        let directHex = directHash.map { String(format: "%02x", $0) }.joined()
        print("Direct BLAKE3.hash('abc'): \(directHex)")
        print("Facade BLAKE3-256('abc'): \(facadeHash.map { String(format: "%02x", $0) }.joined())")
        
        // Verify it's 32 bytes
        XCTAssertEqual(directHash.count, 32, "BLAKE3.hash must produce exactly 32 bytes")
    }
    
    /// Test BLAKE3.hash() with empty input
    func testBlake3_DirectAPI_Empty() throws {
        let testInput = Data()
        let directHash = BLAKE3.hash(contentsOf: testInput, outputByteCount: 32)
        
        // Expected from official test vectors
        let expectedHex = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        var expected: [UInt8] = []
        var index = expectedHex.startIndex
        while index < expectedHex.endIndex {
            let nextIndex = expectedHex.index(index, offsetBy: 2)
            guard let byte = UInt8(expectedHex[index..<nextIndex], radix: 16) else {
                XCTFail("Invalid expected digest format")
                return
            }
            expected.append(byte)
            index = nextIndex
        }
        
        XCTAssertEqual(directHash, expected, "Direct BLAKE3.hash(empty) must match official test vector")
    }
    
    /// Test that we're NOT using keyed mode
    func testBlake3_NotKeyedMode() throws {
        let testInput = Data("test".utf8)
        
        // Regular hash (what we use)
        let regularHash = BLAKE3.hash(contentsOf: testInput, outputByteCount: 32)
        
        // Keyed hash (what we should NOT use)
        let key = "whats the Elvish word for friend".utf8
        let keyedHash = BLAKE3.hash(contentsOf: testInput, withKey: key, outputByteCount: 32)
        
        // They should be DIFFERENT
        XCTAssertNotEqual(regularHash, keyedHash, "Regular hash and keyed hash must differ")
        
        // Our facade should match regular hash
        let facadeHash = try Blake3Facade.blake3_256(data: testInput)
        XCTAssertEqual(regularHash, facadeHash, "Facade must use regular hash, not keyed")
    }
    #endif
}
