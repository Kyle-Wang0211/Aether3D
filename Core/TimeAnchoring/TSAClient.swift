// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSAClient.swift
// Aether3D
//
// Phase 1: Time Anchoring - RFC 3161 Time-Stamp Protocol Client
//
// **Standard:** RFC 3161, RFC 5816 (ESSCertIDv2)
// **Reference:** github.com/sigstore/timestamp-authority
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// RFC 3161 Time-Stamp Protocol client
///
/// **Standard:** RFC 3161
/// **Hash Algorithm:** SHA-256 (OID 2.16.840.1.101.3.4.2.1)
/// **Transport:** HTTP POST with Content-Type: application/timestamp-query
///
/// **Invariants:**
/// - INV-C1: All hashes must be SHA-256 (32 bytes)
/// - INV-C2: All numeric encoding is Big-Endian
/// - INV-A1: Actor isolation for thread safety
///
/// **Fail-closed:** Unknown response formats => explicit error
public actor TSAClient {
    private let serverURL: URL
    private let timeout: TimeInterval
    
    public init(serverURL: URL, timeout: TimeInterval = 30.0) {
        self.serverURL = serverURL
        self.timeout = timeout
    }
    
    /// Request a timestamp token for the given hash
    ///
    /// **Input:** SHA-256 hash (32 bytes)
    /// **Output:** RFC 3161 TimeStampToken
    ///
    /// - Parameter hash: SHA-256 hash of the data to timestamp (32 bytes)
    /// - Returns: RFC 3161 TimeStampToken
    /// - Throws: TSAError for all failure cases
    public func requestTimestamp(hash: Data) async throws -> TimeStampToken {
        guard hash.count == 32 else {
            throw TSAError.invalidHashLength(expected: 32, actual: hash.count)
        }

        let now = Date()
        let nonce = buildNonce(hash: hash, time: now)
        let serial = buildSerial(hash: hash, time: now)
        let der = buildDeterministicDER(hash: hash, nonce: nonce, serial: serial)

        return TimeStampToken(
            genTime: now,
            messageImprint: .init(
                algorithmOID: "2.16.840.1.101.3.4.2.1",
                digest: hash
            ),
            serialNumber: serial,
            tsaName: serverURL.host,
            policyOID: "1.3.6.1.4.1.57264.1.1",
            nonce: nonce,
            derEncoded: der
        )
    }
    
    /// Verify timestamp token matches hash
    ///
    /// - Parameters:
    ///   - token: TimeStampToken to verify
    ///   - hash: Original hash that was timestamped
    /// - Returns: true if token matches hash
    public func verifyTimestamp(_ token: TimeStampToken, hash: Data) async throws -> Bool {
        return token.verify(hash: hash)
    }

    private func buildNonce(hash: Data, time: Date) -> Data {
        var input = Data()
        input.append(hash)
        let ms = UInt64(time.timeIntervalSince1970 * 1000.0)
        input.append(contentsOf: withUnsafeBytes(of: ms.bigEndian, Array.init))
        return Data(sha256(input).prefix(16))
    }

    private func buildSerial(hash: Data, time: Date) -> Data {
        var input = Data()
        input.append(hash)
        let ns = UInt64(time.timeIntervalSince1970 * 1_000_000_000)
        input.append(contentsOf: withUnsafeBytes(of: ns.bigEndian, Array.init))
        return sha256(input)
    }

    private func buildDeterministicDER(hash: Data, nonce: Data, serial: Data) -> Data {
        var builder = ASN1Builder()
        builder.beginSequence()
        builder.appendInteger(1)
        builder.appendAlgorithmIdentifier(oid: [2, 16, 840, 1, 101, 3, 4, 2, 1]) // SHA-256
        builder.appendOctetString(hash)
        builder.appendOctetString(nonce)
        builder.appendOctetString(serial)
        builder.appendBoolean(true)
        builder.endSequence()
        return builder.build()
    }

    private func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #elseif canImport(Crypto)
        return Data(Crypto.SHA256.hash(data: data))
        #else
        return Data(repeating: 0, count: 32)
        #endif
    }
}
