//
// CryptoHashFacade.swift
// Aether3D
//
// PR1 v2.4 Addendum EXT+ - Cryptographic Hashing Facade
//
// RENAMED FROM: Blake3Facade.swift (misleading name)
// ACTUAL ALGORITHM: SHA-256 (not BLAKE3)
//
// Provides deterministic hashing for: policyHash, sessionStableId, candidateStableId, decisionHash
//
// History:
// - blake3-swift was removed due to swift-frontend crashes in CI environments
// - SHA-256 via CryptoKit/swift-crypto provides cross-platform stability
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Cryptographic hashing facade using SHA-256
///
/// **Rule ID:** G2, PR1-EXT-2.4
/// **Status:** SEALED
///
/// **P0 Contract:**
/// - Single library only (no mixed libraries)
/// - Algorithm: SHA-256 (NIST FIPS 180-4)
/// - Used for: policyHash, sessionStableId, candidateStableId, decisionHash
/// - Produces exactly 32 bytes
/// - 64-bit variant is first 8 bytes in BE order
///
/// **Implementation Note:**
/// Uses SHA-256 for cross-platform stability. blake3-swift was removed
/// due to swift-frontend compiler crashes in CI environments (both macOS and Linux).
///
/// **IMPORTANT:** This file replaces Blake3Facade.swift. The old name was misleading
/// because the actual algorithm is SHA-256, not BLAKE3.
public enum CryptoHashFacade {

    // MARK: - Constants

    /// SHA-256 output size in bytes
    public static let sha256OutputSize: Int = 32

    /// SHA-256 truncated to 64-bit output size
    public static let sha256_64OutputSize: Int = 8

    /// Algorithm identifier (matches CrossPlatformConstants.HASH_ALGO_ID)
    public static let algorithmId: String = "SHA256"

    /// Golden vector for self-test: SHA-256("abc")
    /// Reference: NIST FIPS 180-4, Appendix B.1
    public static let goldenVectorInput: String = "abc"
    public static let goldenVectorExpectedHex: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    // MARK: - Hash Functions

    /// Compute SHA-256 hash producing 32 bytes
    ///
    /// **Algorithm:** SHA-256 (NIST FIPS 180-4)
    /// **Output:** Exactly 32 bytes
    ///
    /// **Fail-closed:** Throws if no crypto implementation available
    ///
    /// - Parameter data: Input data to hash
    /// - Returns: 32-byte SHA-256 digest as [UInt8]
    /// - Throws: FailClosedError if crypto unavailable
    public static func sha256(data: Data) throws -> [UInt8] {
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

    /// Compute SHA-256 hash truncated to 64-bit UInt64
    ///
    /// **Algorithm:**
    /// 1. Compute full 32-byte SHA-256 hash
    /// 2. Extract first 8 bytes
    /// 3. Interpret as Big-Endian UInt64
    ///
    /// **Rule:** 64-bit hash is defined as the first 8 bytes of 256-bit hash in BE order
    ///
    /// - Parameter data: Input data to hash
    /// - Returns: First 8 bytes of SHA-256 as UInt64 (BE interpretation)
    /// - Throws: FailClosedError if crypto unavailable
    public static func sha256_64(data: Data) throws -> UInt64 {
        let hash256 = try sha256(data: data)
        // Extract first 8 bytes and convert to UInt64 BE
        let bytes8 = Array(hash256.prefix(8))
        var result: UInt64 = 0
        for (index, byte) in bytes8.enumerated() {
            result |= UInt64(byte) << (56 - index * 8)
        }
        return result
    }

    // MARK: - Backward Compatibility (Deprecated)

    /// Backward compatibility alias for sha256()
    ///
    /// **DEPRECATED:** Use `sha256(data:)` instead. This method exists only for
    /// backward compatibility during migration from Blake3Facade.
    @available(*, deprecated, renamed: "sha256(data:)", message: "Use sha256(data:) - this was misleadingly named")
    public static func blake3_256(data: Data) throws -> [UInt8] {
        return try sha256(data: data)
    }

    /// Backward compatibility alias for sha256_64()
    ///
    /// **DEPRECATED:** Use `sha256_64(data:)` instead. This method exists only for
    /// backward compatibility during migration from Blake3Facade.
    @available(*, deprecated, renamed: "sha256_64(data:)", message: "Use sha256_64(data:) - this was misleadingly named")
    public static func blake3_64(data: Data) throws -> UInt64 {
        return try sha256_64(data: data)
    }

    // MARK: - Self-Test

    /// Verify golden vector (runtime self-test)
    ///
    /// **Test Vector:**
    /// - Input: "abc" (ASCII bytes: 0x61 0x62 0x63)
    /// - Expected SHA-256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    /// - Reference: NIST FIPS 180-4, Appendix B.1
    ///
    /// **Fail-closed:** Throws if mismatch detected
    ///
    /// **Usage:** Call at startup or first use to verify hash implementation correctness
    ///
    /// - Throws: FailClosedError if golden vector verification fails
    public static func verifyGoldenVector() throws {
        let testInput = Data(goldenVectorInput.utf8)
        let actual = try sha256(data: testInput)

        // Parse expected hex to bytes
        let expected = try hexStringToBytes(goldenVectorExpectedHex)

        guard actual == expected else {
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.cryptoImplementationMismatch.rawValue,
                context: "SHA-256 golden vector mismatch"
            )
        }
    }

    // MARK: - Utilities

    /// Convert hex string to byte array
    ///
    /// - Parameter hex: Hex string (lowercase, even length)
    /// - Returns: Byte array
    /// - Throws: FailClosedError if hex string is invalid
    public static func hexStringToBytes(_ hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else {
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.cryptoImplementationMismatch.rawValue,
                context: "Hex string must have even length"
            )
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw FailClosedError.internalContractViolation(
                    code: FailClosedErrorCode.cryptoImplementationMismatch.rawValue,
                    context: "Invalid hex character in string"
                )
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
    }

    /// Convert byte array to lowercase hex string
    ///
    /// - Parameter bytes: Byte array
    /// - Returns: Lowercase hex string
    public static func bytesToHexString(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Backward Compatibility Typealias

/// Backward compatibility typealias
///
/// **DEPRECATED:** Use `CryptoHashFacade` directly. This typealias exists only for
/// backward compatibility during migration.
@available(*, deprecated, renamed: "CryptoHashFacade", message: "Blake3Facade was misleadingly named - use CryptoHashFacade")
public typealias Blake3Facade = CryptoHashFacade
