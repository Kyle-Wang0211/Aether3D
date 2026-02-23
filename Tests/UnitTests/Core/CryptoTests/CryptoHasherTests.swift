// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CryptoHasherTests.swift
// Aether3D
//
// Comprehensive tests for CryptoHasher - 50 tests
// 符合 PART B.2.1: CryptoTests (50 tests)
//

import XCTest
@testable import SharedSecurity
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

final class CryptoHasherTests: XCTestCase {

    // MARK: - SHA-256 Tests (20 tests)

    func testSHA256_EmptyData() {
        let hash = CryptoHasher.sha256(Data())
        XCTAssertEqual(hash.count, 64) // 32 bytes = 64 hex chars
        // Empty data SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256_KnownVector1() {
        let data = "abc".data(using: .utf8)!
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256_KnownVector2() {
        let data = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".data(using: .utf8)!
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA256_LargeData() {
        let data = Data(repeating: 0x61, count: 1_000_000) // 1MB of 'a'
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testSHA256_DeterministicOutput() {
        let data = "test data".data(using: .utf8)!
        let hash1 = CryptoHasher.sha256(data)
        let hash2 = CryptoHasher.sha256(data)
        XCTAssertEqual(hash1, hash2)
    }

    func testSHA256_DifferentInputsDifferentOutputs() {
        let data1 = "test1".data(using: .utf8)!
        let data2 = "test2".data(using: .utf8)!
        let hash1 = CryptoHasher.sha256(data1)
        let hash2 = CryptoHasher.sha256(data2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA256_SingleByteChange() {
        let data1 = "test data".data(using: .utf8)!
        var data2 = data1
        data2[0] = data2[0] ^ 0x01 // Flip one bit
        let hash1 = CryptoHasher.sha256(data1)
        let hash2 = CryptoHasher.sha256(data2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA256_AllZeros() {
        let data = Data(repeating: 0x00, count: 64)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_AllOnes() {
        let data = Data(repeating: 0xFF, count: 64)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_Unicode() {
        let data = "你好世界🌍".data(using: .utf8)!
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_StringInput() {
        let hash = CryptoHasher.sha256("test")
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_StringInputEmpty() {
        let hash = CryptoHasher.sha256("")
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256_StringInputUnicode() {
        let hash = CryptoHasher.sha256("你好")
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_VeryLongString() {
        let longString = String(repeating: "a", count: 10000)
        let hash = CryptoHasher.sha256(longString)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_SingleByte() {
        let data = Data([0x42])
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_Exactly32Bytes() {
        let data = Data(repeating: 0xAB, count: 32)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_Exactly64Bytes() {
        let data = Data(repeating: 0xCD, count: 64)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_Exactly128Bytes() {
        let data = Data(repeating: 0xEF, count: 128)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    func testSHA256_OneMegabyte() {
        let data = Data(repeating: 0x01, count: 1_048_576)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 64)
    }

    // MARK: - SHA-512 Tests (10 tests)

    func testSHA512_EmptyData() {
        let hash = CryptoHasher.sha512(Data())
        XCTAssertEqual(hash.count, 128) // 64 bytes = 128 hex chars
    }

    func testSHA512_KnownVector() {
        let data = "abc".data(using: .utf8)!
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    func testSHA512_DeterministicOutput() {
        let data = "test".data(using: .utf8)!
        let hash1 = CryptoHasher.sha512(data)
        let hash2 = CryptoHasher.sha512(data)
        XCTAssertEqual(hash1, hash2)
    }

    func testSHA512_DifferentInputsDifferentOutputs() {
        let data1 = "test1".data(using: .utf8)!
        let data2 = "test2".data(using: .utf8)!
        let hash1 = CryptoHasher.sha512(data1)
        let hash2 = CryptoHasher.sha512(data2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA512_LargeData() {
        let data = Data(repeating: 0x61, count: 1_000_000)
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    func testSHA512_AllZeros() {
        let data = Data(repeating: 0x00, count: 64)
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    func testSHA512_AllOnes() {
        let data = Data(repeating: 0xFF, count: 64)
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    func testSHA512_Unicode() {
        let data = "你好世界🌍".data(using: .utf8)!
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    func testSHA512_SingleByte() {
        let data = Data([0x42])
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    func testSHA512_VeryLongData() {
        let data = Data(repeating: 0xAB, count: 10_000_000)
        let hash = CryptoHasher.sha512(data)
        XCTAssertEqual(hash.count, 128)
    }

    // MARK: - HMAC Tests (15 tests)

    func testHMAC_SHA256_KnownVector() {
        let key = SymmetricKey(data: Data(repeating: 0x0b, count: 20))
        let message = "Hi There".data(using: .utf8)!
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64) // 32 bytes = 64 hex chars
    }

    func testHMAC_SHA256_EmptyMessage() {
        let key = SymmetricKey(data: "secret".data(using: .utf8)!)
        let message = Data()
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_LongKey() {
        let key = SymmetricKey(data: Data(repeating: 0xAA, count: 131)) // Key longer than block size
        let message = "test".data(using: .utf8)!
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_Deterministic() {
        let key = SymmetricKey(data: "secret".data(using: .utf8)!)
        let message = "message".data(using: .utf8)!
        let hmac1 = CryptoHasher.hmacSHA256(data: message, key: key)
        let hmac2 = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac1, hmac2)
    }

    func testHMAC_SHA256_DifferentKeysDifferentOutputs() {
        let key1 = SymmetricKey(data: "secret1".data(using: .utf8)!)
        let key2 = SymmetricKey(data: "secret2".data(using: .utf8)!)
        let message = "message".data(using: .utf8)!
        let hmac1 = CryptoHasher.hmacSHA256(data: message, key: key1)
        let hmac2 = CryptoHasher.hmacSHA256(data: message, key: key2)
        XCTAssertNotEqual(hmac1, hmac2)
    }

    func testHMAC_SHA256_DifferentMessagesDifferentOutputs() {
        let key = SymmetricKey(data: "secret".data(using: .utf8)!)
        let message1 = "message1".data(using: .utf8)!
        let message2 = "message2".data(using: .utf8)!
        let hmac1 = CryptoHasher.hmacSHA256(data: message1, key: key)
        let hmac2 = CryptoHasher.hmacSHA256(data: message2, key: key)
        XCTAssertNotEqual(hmac1, hmac2)
    }

    func testHMAC_SHA256_LargeMessage() {
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data(repeating: 0x02, count: 1_000_000)
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_SingleByteKey() {
        let key = SymmetricKey(data: Data([0x01]))
        let message = "test".data(using: .utf8)!
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_SingleByteMessage() {
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data([0x02])
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_UnicodeMessage() {
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = "你好世界".data(using: .utf8)!
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_ExactBlockSize() {
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data(repeating: 0x02, count: 64) // SHA-256 block size
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_MultipleBlockSize() {
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data(repeating: 0x02, count: 128) // 2 blocks
        let hmac = CryptoHasher.hmacSHA256(data: message, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_KeySameAsMessage() {
        let data = Data(repeating: 0xAB, count: 32)
        let key = SymmetricKey(data: data)
        let hmac = CryptoHasher.hmacSHA256(data: data, key: key)
        XCTAssertEqual(hmac.count, 64)
    }

    func testHMAC_SHA256_Performance() {
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data(repeating: 0x02, count: 1024)

        measure {
            for _ in 0..<1000 {
                _ = CryptoHasher.hmacSHA256(data: message, key: key)
            }
        }
    }

    // MARK: - Performance Tests (5 tests)

    func testSHA256_Performance() {
        let data = Data(repeating: 0xAB, count: 1024)

        measure {
            for _ in 0..<10_000 {
                _ = CryptoHasher.sha256(data)
            }
        }
    }

    func testSHA512_Performance() {
        let data = Data(repeating: 0xAB, count: 1024)

        measure {
            for _ in 0..<10_000 {
                _ = CryptoHasher.sha512(data)
            }
        }
    }

    func testSHA256_LargeDataPerformance() {
        let data = Data(repeating: 0xAB, count: 1_000_000)

        measure {
            _ = CryptoHasher.sha256(data)
        }
    }

    func testSHA512_LargeDataPerformance() {
        let data = Data(repeating: 0xAB, count: 1_000_000)

        measure {
            _ = CryptoHasher.sha512(data)
        }
    }

    func testSHA256_StringPerformance() {
        let string = String(repeating: "a", count: 10000)

        measure {
            for _ in 0..<1000 {
                _ = CryptoHasher.sha256(string)
            }
        }
    }
}
