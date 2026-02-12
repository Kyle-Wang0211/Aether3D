// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-CRYPTO-1.0
// Module: Upload Infrastructure - Shared Crypto Helpers
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

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
