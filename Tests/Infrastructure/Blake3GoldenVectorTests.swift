// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// Blake3GoldenVectorTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Hash Function Golden Vector Tests
//
// Verifies hash implementation matches known test vectors
//
// Note: Now uses SHA-256 (blake3-swift removed due to CI compiler crashes)
//

import XCTest
@testable import Aether3DCore

final class Blake3GoldenVectorTests: XCTestCase {
    /// Test hash("abc") matches known golden vector
    ///
    /// **Test Vector:**
    /// - Input: "abc" (ASCII bytes: 0x61 0x62 0x63)
    /// - Expected SHA-256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    ///
    /// **Fail-closed:** Test fails if mismatch (crypto implementation mismatch)
    func testBlake3_256_Abc_GoldenVector() throws {
        let testInput = Data("abc".utf8)
        let actual = try Blake3Facade.blake3_256(data: testInput)

        // Expected SHA-256("abc") - standard NIST test vector
        // Reference: NIST FIPS 180-4
        let expectedHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
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

        XCTAssertEqual(actual.count, 32, "Hash must produce exactly 32 bytes")
        XCTAssertEqual(actual, expected, "hash('abc') must match golden vector")
    }

    /// Test 64-bit hash("abc") matches expected 8 bytes
    ///
    /// **Rule:** 64-bit hash is first 8 bytes of 256-bit hash in BE order
    func testBlake3_64_Abc_MatchesFirst8Bytes() throws {
        let testInput = Data("abc".utf8)
        let hash256 = try Blake3Facade.blake3_256(data: testInput)
        let hash64 = try Blake3Facade.blake3_64(data: testInput)

        // Extract first 8 bytes and convert to UInt64 BE
        let bytes8 = Array(hash256.prefix(8))
        var expected64: UInt64 = 0
        for (index, byte) in bytes8.enumerated() {
            expected64 |= UInt64(byte) << (56 - index * 8)
        }

        XCTAssertEqual(hash64, expected64, "64-bit hash must be first 8 bytes of 256-bit hash in BE order")
    }

    /// Test runtime self-test (verifyGoldenVector)
    ///
    /// Note: verifyGoldenVector is a static method that can be called at startup
    func testBlake3_RuntimeSelfTest() throws {
        // Verify golden vector manually (same as runtime self-test)
        let testInput = Data("abc".utf8)
        let actual = try Blake3Facade.blake3_256(data: testInput)

        // Expected SHA-256("abc") - NIST standard test vector
        let expectedHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
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

        XCTAssertEqual(actual, expected, "Runtime self-test: hash('abc') must match golden vector")
    }

    /// Test verifyGoldenVector() doesn't throw
    func testBlake3_VerifyGoldenVector_NoThrow() throws {
        XCTAssertNoThrow(try Blake3Facade.verifyGoldenVector())
    }
}
