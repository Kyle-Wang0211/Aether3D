// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Crypto
import Foundation
import Security

struct DanishGoldenSSHIdentity: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey
    let authorizedKeyLine: String
}

enum DanishGoldenSSHProvisioningError: Error {
    case invalidKeyData
    case keychainError(OSStatus)
}

enum DanishGoldenSSHProvisioning {
    private static let service = "com.aether3d.pipeline.danish-golden-ssh"
    private static let account = "ed25519-user-key"
    private static let authorizedKeyComment = "aether3d-ios-debug@danish-golden"

    static func loadIdentity() throws -> DanishGoldenSSHIdentity {
        let privateKey = try loadOrCreatePrivateKey()
        return DanishGoldenSSHIdentity(
            privateKey: privateKey,
            authorizedKeyLine: authorizedKeyLine(for: privateKey, comment: authorizedKeyComment)
        )
    }

    static func authorizedKeyLine() throws -> String {
        try loadIdentity().authorizedKeyLine
    }

    private static func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        #if DEBUG
        let developmentKey = try makeDevelopmentOrFreshPrivateKey()
        let currentData = try loadPrivateKeyData()
        if currentData != developmentKey.rawRepresentation {
            try savePrivateKeyData(developmentKey.rawRepresentation)
        }
        return developmentKey
        #else
        if let keyData = try loadPrivateKeyData() {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
                try deletePrivateKeyData()
                throw DanishGoldenSSHProvisioningError.invalidKeyData
            }
            return key
        }

        let privateKey = try makeDevelopmentOrFreshPrivateKey()
        try savePrivateKeyData(privateKey.rawRepresentation)
        return privateKey
        #endif
    }

    private static func makeDevelopmentOrFreshPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        #if DEBUG
        return try Curve25519.Signing.PrivateKey(rawRepresentation: Data([
            125, 202, 43, 47, 50, 84, 248, 38,
            132, 192, 165, 255, 151, 237, 161, 226,
            255, 220, 125, 105, 108, 80, 59, 195,
            240, 22, 191, 59, 54, 175, 155, 83,
        ]))
        #else
        return Curve25519.Signing.PrivateKey()
        #endif
    }

    private static func authorizedKeyLine(
        for privateKey: Curve25519.Signing.PrivateKey,
        comment: String
    ) -> String {
        var keyBlob = Data()
        appendSSHString("ssh-ed25519", to: &keyBlob)
        appendSSHBytes(privateKey.publicKey.rawRepresentation, to: &keyBlob)
        return "ssh-ed25519 \(keyBlob.base64EncodedString()) \(comment)"
    }

    private static func appendSSHString(_ string: String, to data: inout Data) {
        appendSSHBytes(Data(string.utf8), to: &data)
    }

    private static func appendSSHBytes(_ bytes: Data, to data: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private static func loadPrivateKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw DanishGoldenSSHProvisioningError.invalidKeyData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw DanishGoldenSSHProvisioningError.keychainError(status)
        }
    }

    private static func savePrivateKeyData(_ data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DanishGoldenSSHProvisioningError.keychainError(status)
        }
    }

    private static func deletePrivateKeyData() throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(deleteQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DanishGoldenSSHProvisioningError.keychainError(status)
        }
    }
}
