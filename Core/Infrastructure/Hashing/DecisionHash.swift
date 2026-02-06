//
// DecisionHash.swift
// Aether3D
//
// PR1 v2.4 Addendum EXT+ - DecisionHash Contract
//
// First-class, byte-stable, policy-bound, replay-deterministic decision hash
//
// CHANGED (v6.0):
// - Updated comments: algorithm is SHA-256 (not BLAKE3)
// - Updated references: Blake3Facade → CryptoHashFacade
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Decision hash bytes (fixed 32 bytes)
public typealias DecisionHashBytes = [UInt8]

/// Decision hash (32 bytes, immutable)
///
/// **Rule ID:** PR1-EXT-2.4
/// **Status:** SEALED (v6.0)
///
/// **P0 Contract:**
/// - Exactly 32 bytes (full SHA-256 digest, no truncation)
/// - Byte-stable under replay
/// - Policy-bound (includes policyHash in input)
///
/// **Algorithm:** SHA-256 (via CryptoHashFacade)
/// **Note:** Historical comments mentioned BLAKE3, but actual implementation
/// uses SHA-256 due to blake3-swift compiler crashes.
public struct DecisionHash: Equatable, Sendable, Codable {
    /// Hash bytes (exactly 32)
    public let bytes: DecisionHashBytes

    /// Initialize with 32 bytes (validates size)
    public init(bytes: DecisionHashBytes) throws {
        guard bytes.count == 32 else {
            throw DecisionHashError.invalidSize(expected: 32, actual: bytes.count)
        }
        self.bytes = bytes
    }

    /// Initialize from Data (validates size)
    public init(data: Data) throws {
        guard data.count == 32 else {
            throw DecisionHashError.invalidSize(expected: 32, actual: data.count)
        }
        self.bytes = Array(data)
    }

    /// Hex string representation (lowercase, for JSON/debug only)
    ///
    /// **Format:** 64 lowercase hex characters
    /// **Example:** "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    public var hexString: String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Initialize from hex string (for JSON decoding)
    ///
    /// **Accepts:** 64 character hex string (case-insensitive)
    public init(hexString: String) throws {
        guard hexString.count == 64 else {
            throw DecisionHashError.invalidHexStringLength(expected: 64, actual: hexString.count)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                throw DecisionHashError.invalidHexString
            }
            bytes.append(byte)
            index = nextIndex
        }
        try self.init(bytes: bytes)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case hexString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try container.decode(String.self, forKey: .hexString)
        try self.init(hexString: hex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hexString, forKey: .hexString)
    }
}

/// DecisionHash computation (v1)
///
/// **Rule ID:** PR1-EXT-2.4
/// **Status:** SEALED (v6.0)
///
/// **Algorithm:** SHA-256 with domain separation
/// **Domain Tag:** "AETHER3D_DECISION_HASH_V1\0" (26 bytes)
public enum DecisionHashV1 {
    /// Domain separation tag bytes: ASCII("AETHER3D_DECISION_HASH_V1") + single 0x00 terminator
    ///
    /// **P0 Contract:**
    /// - Exact byte sequence: no padding, no trimming, no fixed-length buffer
    /// - Length = len(ASCII("AETHER3D_DECISION_HASH_V1")) + 1 = 25 + 1 = 26 bytes
    /// - Last byte MUST be 0x00
    public static let domainTagBytes: [UInt8] = {
        var tag = Array("AETHER3D_DECISION_HASH_V1".utf8)
        tag.append(0x00)
        // Precondition: verify exact length and terminator
        precondition(tag.count == 26, "DOMAIN_TAG must be exactly 26 bytes")
        precondition(tag.last == 0x00, "DOMAIN_TAG must end with 0x00")
        return tag
    }()

    /// Domain tag length (locked: 26 bytes)
    public static let domainTagLength: Int = 26

    /// Domain tag hex string (for debugging/verification)
    public static var domainTagHex: String {
        return domainTagBytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute decision hash from canonical input bytes
    ///
    /// **Algorithm:**
    /// 1. Concatenate: `domainTagBytes || canonicalInput`
    /// 2. Compute SHA-256: `digest = SHA-256(domainTagBytes || canonicalInput)`
    /// 3. Return DecisionHash(bytes: digest[0..<32])
    ///
    /// **Fail-closed:** Uses CryptoHashFacade (single implementation)
    ///
    /// **CHANGED (v6.0):** Updated to use CryptoHashFacade.sha256()
    /// instead of deprecated Blake3Facade.blake3_256()
    public static func compute(from canonicalInput: Data) throws -> DecisionHash {
        // Concatenate domain tag and canonical input (byte-exact)
        var input = Data(domainTagBytes)
        input.append(canonicalInput)

        // Compute SHA-256 hash using single facade
        let hashBytes = try CryptoHashFacade.sha256(data: input)
        return try DecisionHash(bytes: hashBytes)
    }

    /// Debug helper: return preimage hex (domainTagBytes || canonicalInput)
    ///
    /// **P0 Contract:**
    /// - Returns hex string of the exact bytes fed to SHA-256
    /// - Used for cross-platform verification and debugging
    /// - Test-only visibility (internal for tests)
    internal static func debugPreimageHex(inputBytes: Data) -> String {
        var preimage = Data(domainTagBytes)
        preimage.append(inputBytes)
        return preimage.map { String(format: "%02x", $0) }.joined()
    }

    /// Debug helper: return preimage length
    internal static func debugPreimageLength(inputBytes: Data) -> Int {
        return domainTagLength + inputBytes.count
    }
}

/// DecisionHash errors
public enum DecisionHashError: Error {
    case invalidSize(expected: Int, actual: Int)
    case invalidHexStringLength(expected: Int, actual: Int)
    case invalidHexString
}
