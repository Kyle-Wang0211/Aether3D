//
// DecisionHash.swift
// Aether3D
//
// PR1 v2.4 Addendum EXT+ - DecisionHash Contract
//
// First-class, byte-stable, policy-bound, replay-deterministic decision hash
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
/// **P0 Contract:**
/// - Exactly 32 bytes (full BLAKE3 digest, no truncation)
/// - Byte-stable under replay
/// - Policy-bound (includes policyHash in input)
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
    
    /// Hex string representation (for JSON/debug only, NOT canonical bytes)
    public var hexString: String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Initialize from hex string (for JSON decoding)
    public init(hexString: String) throws {
        guard hexString.count == 64 else {
            throw DecisionHashError.invalidHexStringLength(expected: 64, actual: hexString.count)
        }
        var bytes: [UInt8] = []
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
    /// 2. Compute BLAKE3-256: `digest = BLAKE3-256(domainTagBytes || canonicalInput)`
    /// 3. Return DecisionHash(bytes: digest[0..<32])
    /// 
    /// **Fail-closed:** Uses Blake3Facade (single implementation)
    public static func compute(from canonicalInput: Data) throws -> DecisionHash {
        // Concatenate domain tag and canonical input (byte-exact)
        var input = Data(domainTagBytes)
        input.append(canonicalInput)
        
        // Compute BLAKE3-256 hash using single facade
        let hashBytes = try Blake3Facade.blake3_256(data: input)
        return try DecisionHash(bytes: hashBytes)
    }
    
    /// Debug helper: return preimage hex (domainTagBytes || canonicalInput)
    /// 
    /// **P0 Contract:**
    /// - Returns hex string of the exact bytes fed to BLAKE3
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
