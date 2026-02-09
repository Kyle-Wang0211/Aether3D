// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  KeychainSigningKeyStore.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

import Foundation
import Security

final class KeychainSigningKeyStore: SigningKeyStore {
    private let service = "com.aether3d.audit.signing"
    private let account = "default"

    private var cached: SigningKeyMaterial?

    init() {}

    func getOrCreateSigningKey() throws -> SigningKeyMaterial {
        if let c = cached { return c }

        if let seed = try? loadSeedFromKeychain() {
            let m = try SigningKeyMaterial.fromSeed(seed)
            cached = m
            return m
        }

        let m = SigningKeyMaterial.generate()
        try saveSeedToKeychain(m.seedData)
        cached = m
        return m
    }

    func currentPublicKeyString() throws -> String {
        try getOrCreateSigningKey().publicKeyBase64
    }

    // MARK: - CFDictionaryCreate Helpers (ZERO Any)

    /// Create an UnsafeRawPointer for a CF object without using Any.
    /// NOTE: This assumes the object outlives the dictionary usage (true for these constants & strings).
    private func ptr(_ obj: CFTypeRef) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
    }

    /// Create a CFDictionary from key/value CF objects.
    /// - Important: keys/values are stored as pointers; objects must outlive call usage.
    private func makeCFDictionary(keys: [CFTypeRef], values: [CFTypeRef]) throws -> CFDictionary {
        precondition(keys.count == values.count)

        var keyPtrs: [UnsafeRawPointer?] = keys.map { ptr($0) }
        var valPtrs: [UnsafeRawPointer?] = values.map { ptr($0) }

        // CFDictionaryCreate takes raw pointer arrays.
        // Note: kCFTypeDictionaryKeyCallBacks and kCFTypeDictionaryValueCallBacks are constants,
        // but CFDictionaryCreate expects mutable pointers. We use withUnsafeMutablePointer to work around this.
        var keyCallbacks = kCFTypeDictionaryKeyCallBacks
        var valueCallbacks = kCFTypeDictionaryValueCallBacks
        
        guard let dict = CFDictionaryCreate(
            kCFAllocatorDefault,
            &keyPtrs,
            &valPtrs,
            keys.count,
            &keyCallbacks,
            &valueCallbacks
        ) else {
            throw SigningKeyStoreError.invalidKeychainData("CFDictionaryCreate returned nil")
        }

        return dict
    }

    private func loadSeedFromKeychain() throws -> Data {
        let serviceCF = service as CFString
        let accountCF = account as CFString

        let keys: [CFTypeRef] = [
            kSecClass,
            kSecAttrService,
            kSecAttrAccount,
            kSecReturnData
        ]

        let values: [CFTypeRef] = [
            kSecClassGenericPassword,
            serviceCF,
            accountCF,
            kCFBooleanTrue
        ]

        let query = try makeCFDictionary(keys: keys, values: values)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)

        guard status == errSecSuccess else {
            throw SigningKeyStoreError.keychainStatus(status)
        }

        // result should be CFData (bridges to Data)
        guard let cfData = result else {
            throw SigningKeyStoreError.invalidKeychainData("SecItemCopyMatching returned nil result")
        }

        // Bridge CFData -> Data without Any:
        // CFData is toll-free bridged to NSData; use CFDataGetBytePtr.
        guard CFGetTypeID(cfData) == CFDataGetTypeID() else {
            throw SigningKeyStoreError.invalidKeychainData("Keychain result is not CFData")
        }

        let dataRef = unsafeBitCast(cfData, to: CFData.self)
        let length = CFDataGetLength(dataRef)
        guard length == 32 else {
            throw SigningKeyStoreError.invalidSeedLength(expected: 32, actual: length)
        }

        guard let bytes = CFDataGetBytePtr(dataRef) else {
            throw SigningKeyStoreError.invalidKeychainData("CFDataGetBytePtr returned nil")
        }

        return Data(bytes: bytes, count: length)
    }

    private func saveSeedToKeychain(_ seed: Data) throws {
        guard seed.count == 32 else {
            throw SigningKeyStoreError.invalidSeedLength(expected: 32, actual: seed.count)
        }

        let serviceCF = service as CFString
        let accountCF = account as CFString

        // 1) Delete existing (idempotent)
        do {
            let delKeys: [CFTypeRef] = [kSecClass, kSecAttrService, kSecAttrAccount]
            let delVals: [CFTypeRef] = [kSecClassGenericPassword, serviceCF, accountCF]
            let delQuery = try makeCFDictionary(keys: delKeys, values: delVals)
            SecItemDelete(delQuery) // ignore status
        } catch {
            // If dictionary creation fails, continue (idempotent delete)
        }

        // 2) Add new
        // Convert Data -> CFData
        let seedCFData = seed as CFData

        let addKeys: [CFTypeRef] = [
            kSecClass,
            kSecAttrService,
            kSecAttrAccount,
            kSecValueData,
            kSecAttrAccessible
        ]
        let addVals: [CFTypeRef] = [
            kSecClassGenericPassword,
            serviceCF,
            accountCF,
            seedCFData,
            kSecAttrAccessibleAfterFirstUnlock
        ]

        let addQuery = try makeCFDictionary(keys: addKeys, values: addVals)

        let status = SecItemAdd(addQuery, nil)
        guard status == errSecSuccess else {
            throw SigningKeyStoreError.keychainStatus(status)
        }
    }
}

#endif

