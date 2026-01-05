//
//  SignedAuditLogError.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// Errors for signed audit log operations.
enum SignedAuditLogError: Error {
    // Encode/Decode
    case encodingFailed(String)
    case decodingFailed(String)

    // IO
    case ioFailed(String)

    // Input
    case invalidInput(String)

    // Verification errors (detailed)
    case chainBroken(entryIndex: Int, reason: String)
    case hashMismatch(entryIndex: Int)  // Patch C: no hash values in error
    case signatureInvalid(entryIndex: Int)
    case invalidBase64(entryIndex: Int, field: String)
    case invalidPublicKeyFormat(entryIndex: Int, reason: String)
    case unsupportedSigningSchema(entryIndex: Int, version: String)

    // File parsing / tail reading
    case tailReadFailed(String)
}

/// SigningKeyStore errors.
enum SigningKeyStoreError: Error {
    case keyGenerationFailed
    case keyRetrievalFailed
    case signingFailed
    case invalidSeedLength(expected: Int, actual: Int)
    case invalidKeychainData(String)
    case keychainStatus(OSStatus)   // Apple-only usage allowed under #if
}

