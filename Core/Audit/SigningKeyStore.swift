// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SigningKeyStore.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Signing key material (private seed + public key).
/// CRITICAL:
/// - seedData is explicitly exposed (no reflection).
/// - sign uses withUnsafeBytes for cross-implementation compatibility.
struct SigningKeyMaterial {
    /// Ed25519 seed, 32 bytes.
    let seedData: Data

    /// Public key rawRepresentation encoded in Base64.
    let publicKeyBase64: String

    func sign(_ data: Data) throws -> Data {
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
            let sig = try privateKey.signature(for: data)

            // Signature type differences across CryptoKit/swift-crypto:
            // convert via withUnsafeBytes for maximum compatibility.
            return sig.withUnsafeBytes { buf in
                Data(buf)
            }
        } catch {
            throw SigningKeyStoreError.signingFailed
        }
    }

    static func fromSeed(_ seed: Data) throws -> SigningKeyMaterial {
        guard seed.count == 32 else {
            throw SigningKeyStoreError.invalidSeedLength(expected: 32, actual: seed.count)
        }
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            let pub = privateKey.publicKey.rawRepresentation
            return SigningKeyMaterial(
                seedData: seed,
                publicKeyBase64: pub.base64EncodedString()
            )
        } catch {
            throw SigningKeyStoreError.keyRetrievalFailed
        }
    }

    static func generate() -> SigningKeyMaterial {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pub = privateKey.publicKey.rawRepresentation
        return SigningKeyMaterial(
            seedData: privateKey.rawRepresentation,
            publicKeyBase64: pub.base64EncodedString()
        )
    }
}

protocol SigningKeyStore {
    func getOrCreateSigningKey() throws -> SigningKeyMaterial
    func currentPublicKeyString() throws -> String
}

