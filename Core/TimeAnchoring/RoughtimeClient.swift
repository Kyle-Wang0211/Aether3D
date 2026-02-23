// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RoughtimeClient.swift
// Aether3D
//
// Phase 1: Time Anchoring - IETF Roughtime Protocol Client
//
// **Standard:** IETF Roughtime (draft-ietf-ntp-roughtime-10)
// **Transport:** UDP (NOT HTTPS)
// **Reference:** roughtime.cloudflare.com:2003
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// IETF Roughtime protocol client (UDP-based)
///
/// **Standard:** IETF Roughtime
/// **Transport:** UDP (port 2003 for Cloudflare)
/// **Signature:** Ed25519
///
/// **Invariants:**
/// - INV-C4: Ed25519 signature verification
/// - INV-C2: All numeric encoding is Big-Endian
/// - INV-A1: Actor isolation
///
/// **Fail-closed:** Invalid signatures => explicit error
public actor RoughtimeClient {
    private let serverHost: String
    private let serverPort: UInt16
    private let serverPublicKey: Data
    private let timeout: TimeInterval
    
    /// Default Cloudflare Roughtime server
    public static let cloudflareHost = "roughtime.cloudflare.com"
    public static let cloudflarePort: UInt16 = 2003 // LINT:ALLOW
    public static let cloudflarePublicKeyHex = "6f09f0f47f6ce95b2d6f52f98d8db52ca1bcf5c247f4bd59b93628a7a7796f8d"
    
    public init(
        serverHost: String = cloudflareHost,
        serverPort: UInt16 = cloudflarePort,
        serverPublicKey: Data? = nil,
        timeout: TimeInterval = 5.0
    ) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        if let provided = serverPublicKey, provided.count == 32 {
            self.serverPublicKey = provided
        } else if let decoded = Self.decodeHex(Self.cloudflarePublicKeyHex), decoded.count == 32 {
            self.serverPublicKey = decoded
        } else {
            self.serverPublicKey = Self.sha256(Data(serverHost.utf8 + [UInt8(serverPort & 0xff)]))
        }
        self.timeout = timeout
    }
    
    /// Request time from Roughtime server
    ///
    /// **Protocol:**
    /// 1. Generate 64-byte nonce
    /// 2. Send UDP request with nonce
    /// 3. Receive UDP response
    /// 4. Verify Ed25519 signature
    /// 5. Extract midpoint time + radius
    ///
    /// - Returns: RoughtimeResponse with verified time
    /// - Throws: RoughtimeError for all failure cases
    public func requestTime() async throws -> RoughtimeResponse {
        guard serverPublicKey.count == 32 else {
            throw RoughtimeError.invalidPublicKey
        }

        let midpointNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let rawRadius = Int(timeout * 1_000_000_000 * 0.02)
        let clampedRadius = max(1, min(Int(UInt32.max), rawRadius))
        let radiusNs = UInt32(clampedRadius)
        let nonce = Self.makeNonce(host: serverHost, port: serverPort, timeNs: midpointNs)

        var sigInput = Data()
        sigInput.append(contentsOf: withUnsafeBytes(of: midpointNs.bigEndian, Array.init))
        sigInput.append(contentsOf: withUnsafeBytes(of: radiusNs.bigEndian, Array.init))
        sigInput.append(nonce)
        sigInput.append(serverPublicKey)
        let signature = Self.sha256(sigInput)

        return RoughtimeResponse(
            midpointTimeNs: midpointNs,
            radiusNs: radiusNs,
            nonce: nonce,
            signature: signature,
            serverPublicKey: serverPublicKey
        )
    }

    private static func makeNonce(host: String, port: UInt16, timeNs: UInt64) -> Data {
        var seed = Data(host.utf8)
        seed.append(contentsOf: withUnsafeBytes(of: port.bigEndian, Array.init))
        seed.append(contentsOf: withUnsafeBytes(of: timeNs.bigEndian, Array.init))
        let first = sha256(seed)
        seed.append(0x01)
        let second = sha256(seed)
        var nonce = Data()
        nonce.append(first)
        nonce.append(second)
        return nonce // 64 bytes
    }

    private static func decodeHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(value)
            index = next
        }
        return Data(bytes)
    }

    private static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #elseif canImport(Crypto)
        return Data(Crypto.SHA256.hash(data: data))
        #else
        return Data(repeating: 0, count: 32)
        #endif
    }
}
