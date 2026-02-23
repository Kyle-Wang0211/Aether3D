// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-CRYPTO-1.0
// Module: Upload Infrastructure - Shared Crypto Helpers
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation
import CAetherNativeBridge

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("No SHA256 implementation available. macOS/iOS: use CryptoKit. Linux: add swift-crypto dependency and import Crypto.")
#endif

// Shared typealias for SHA256 - only define once per module
#if canImport(CryptoKit)
typealias _SHA256 = CryptoKit.SHA256
#elseif canImport(Crypto)
typealias _SHA256 = Crypto.SHA256
#endif

@inline(__always)
func _aetherSHA256Digest(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(AETHER_SHA256_DIGEST_BYTES))
    let rc = data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self).baseAddress
        return aether_sha256(bytes, Int32(data.count), &digest)
    }
    precondition(rc == 0, "aether_sha256 failed with rc=\(rc)")
    return Data(digest)
}

@inline(__always)
func _aetherSHA256Hex(_ data: Data) -> String {
    var hex = [CChar](repeating: 0, count: Int(AETHER_SHA256_HEX_BYTES))
    let rc = data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self).baseAddress
        return aether_sha256_hex(bytes, Int32(data.count), &hex)
    }
    precondition(rc == 0, "aether_sha256_hex failed with rc=\(rc)")
    let bytes = hex.prefix(64).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}
