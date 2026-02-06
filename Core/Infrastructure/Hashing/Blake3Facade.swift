//
// Blake3Facade.swift
// Aether3D
//
// PR1 v2.4 Addendum - Cryptographic Hashing Facade
//
// Provides deterministic hashing for: policyHash, sessionStableId, candidateStableId, decisionHash
//
// Note: Uses SHA-256 from swift-crypto for cross-platform stability.
// blake3-swift was removed due to swift-frontend crashes in CI environments.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Cryptographic hashing facade (single implementation)
///
/// **P0 Contract:**
/// - Single library only (no mixed libraries)
/// - Used for: policyHash, sessionStableId, candidateStableId, decisionHash
/// - Produces exactly 32 bytes
/// - 64-bit variant is first 8 bytes in BE order
///
/// **Implementation Note:**
/// Uses SHA-256 for cross-platform stability. blake3-swift was removed
/// due to swift-frontend compiler crashes in CI environments (both macOS and Linux).
public enum Blake3Facade {
    /// Hash function producing 32 bytes
    ///
    /// **Algorithm:**
    /// - Compute SHA-256 digest (cross-platform via swift-crypto)
    /// - Return exactly 32 bytes
    ///
    /// **Fail-closed:** Throws if implementation mismatch detected
    public static func blake3_256(data: Data) throws -> [UInt8] {
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: data)
        return Array(digest)
        #elseif canImport(Crypto)
        let digest = Crypto.SHA256.hash(data: data)
        return Array(digest)
        #else
        throw FailClosedError.internalContractViolation(
            code: FailClosedErrorCode.cryptoImplementationMismatch.rawValue,
            context: "No crypto implementation available"
        )
        #endif
    }

    /// Hash function producing 8 bytes (UInt64)
    ///
    /// **Algorithm:**
    /// - Compute 32-byte hash
    /// - Return first 8 bytes in Big-Endian order
    ///
    /// **Rule:** 64-bit hash is defined as the first 8 bytes of 256-bit hash in BE order
    public static func blake3_64(data: Data) throws -> UInt64 {
        let hash256 = try blake3_256(data: data)
        // Extract first 8 bytes and convert to UInt64 BE
        let bytes8 = Array(hash256.prefix(8))
        var result: UInt64 = 0
        for (index, byte) in bytes8.enumerated() {
            result |= UInt64(byte) << (56 - index * 8)
        }
        return result
    }

    /// Verify golden vector (runtime self-test)
    ///
    /// **Test Vector:**
    /// - Input: "abc" (ASCII bytes: 0x61 0x62 0x63)
    /// - Expected SHA-256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    ///
    /// **Fail-closed:** Throws if mismatch detected
    ///
    /// **Usage:** Call at startup or first use to verify hash implementation correctness
    public static func verifyGoldenVector() throws {
        let testInput = Data("abc".utf8)
        let actual = try blake3_256(data: testInput)

        // Expected SHA-256("abc") - standard test vector
        // Reference: NIST FIPS 180-4
        let expectedHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        var expected: [UInt8] = []
        var index = expectedHex.startIndex
        while index < expectedHex.endIndex {
            let nextIndex = expectedHex.index(index, offsetBy: 2)
            guard let byte = UInt8(expectedHex[index..<nextIndex], radix: 16) else {
                throw FailClosedError.internalContractViolation(
                    code: FailClosedErrorCode.cryptoImplementationMismatch.rawValue,
                    context: "Invalid expected digest format"
                )
            }
            expected.append(byte)
            index = nextIndex
        }

        guard actual == expected else {
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.cryptoImplementationMismatch.rawValue,
                context: "Hash golden vector mismatch"
            )
        }
    }
}
