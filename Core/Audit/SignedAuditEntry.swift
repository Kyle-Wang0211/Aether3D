// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SignedAuditEntry.swift
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

/// Signed audit entry with cryptographic chain.
/// CRITICAL:
/// - Independent signing schema version (not AuditSchema).
/// - Canonical payload is FIXED format; changes require version bump.
/// - All variable fields are length-prefixed.
/// - Binds signer identity by including publicKeyHash in canonical.
struct SignedAuditEntry: Codable, Sendable {
    let signingSchemaVersion: String
    let timestamp: Date
    let eventType: String
    let detailsJson: String?
    let detailsSchemaVersion: String

    /// Base64 encoded public key raw bytes.
    let publicKey: String

    /// Base64 encoded signature bytes.
    let signature: String

    /// Base64 signature string of previous entry (chain).
    let prevSignature: String?

    /// SHA256 hex of canonical payload.
    let payloadHash: String

    static let currentSigningSchemaVersion = "1.2.2-sealed-1" // bump due to canonical change (publicKey binding)
}

extension SignedAuditEntry {

    /// Validate input to protect:
    /// - NDJSON single-line integrity
    /// - canonical payload ambiguity
    /// - Patch B: Stricter validation (pipe rejection, JSON validation, charset enforcement)
    static func validateInput(
        eventType: String,
        detailsSchemaVersion: String,
        detailsJson: String?
    ) throws {
        // 1) NDJSON safety: no raw newlines
        if eventType.contains("\n") || eventType.contains("\r") {
            throw SignedAuditLogError.invalidInput("eventType contains newline characters")
        }

        // Patch B: Reject pipe in eventType (canonical delimiter)
        if eventType.contains("|") {
            throw SignedAuditLogError.invalidInput("eventType contains '|' which breaks canonical format")
        }

        // 2) canonical delimiter safety:
        // detailsSchemaVersion must not contain delimiters used by canonical format
        if detailsSchemaVersion.contains("\n") || detailsSchemaVersion.contains("\r") {
            throw SignedAuditLogError.invalidInput("detailsSchemaVersion contains newline characters")
        }
        if detailsSchemaVersion.contains("|") {
            throw SignedAuditLogError.invalidInput("detailsSchemaVersion contains '|' which breaks canonical format")
        }

        // Patch B: Enforce detailsSchemaVersion restricted charset [A-Za-z0-9._-]
        for scalar in detailsSchemaVersion.unicodeScalars {
            let char = Character(scalar)
            let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
            if !allowed.contains(char) {
                throw SignedAuditLogError.invalidInput("detailsSchemaVersion contains invalid character: '\(char)' (only [A-Za-z0-9._-] allowed)")
            }
        }

        // 3) detailsJson must be single-line JSON (escaped \\n OK)
        if let d = detailsJson {
            if d.contains("\n") || d.contains("\r") {
                throw SignedAuditLogError.invalidInput("detailsJson contains raw newline (use escaped \\n)")
            }

            // Patch B: Validate detailsJson is valid JSON
            guard let data = d.data(using: .utf8) else {
                throw SignedAuditLogError.invalidInput("detailsJson is not valid UTF-8")
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                // Check it's NSArray or NSDictionary (without using [String: Any])
                if !(json is NSArray) && !(json is NSDictionary) {
                    throw SignedAuditLogError.invalidInput("detailsJson must be JSON object or array")
                }
            } catch {
                throw SignedAuditLogError.invalidInput("detailsJson is not valid JSON: \(error.localizedDescription)")
            }
        }
    }

    /// Canonical payload for signing & hashing.
    ///
    /// Format (v = 1.2.2-sealed-1):
    /// v=<ver>|
    /// ts=<ISO8601>|
    /// type_len=<N>|type=<eventType>|
    /// dsv_len=<M>|dsv=<detailsSchemaVersion>|
    /// details_len=<K>|details=<detailsJsonOrEmpty>|
    /// prev_len=<L>|prev=<prevSignatureOrEmpty>|
    /// pkhash_len=<P>|pkhash=<sha256hex(publicKeyRawBytes)>
    ///
    /// CRITICAL:
    /// - ALL variable fields have length prefixes.
    /// - pkhash binds signer identity to payload without including huge key string.
    static func canonicalPayload(
        signingSchemaVersion: String,
        timestamp: Date,
        eventType: String,
        detailsSchemaVersion: String,
        detailsJson: String?,
        prevSignature: String?,
        publicKeyBase64: String
    ) throws -> String {
        let iso = ISO8601DateFormatter.auditFormat.string(from: timestamp)

        let typeLen = eventType.utf8.count
        let dsvLen = detailsSchemaVersion.utf8.count

        let details = detailsJson ?? ""
        let detailsLen = details.utf8.count

        let prev = prevSignature ?? ""
        let prevLen = prev.utf8.count

        // publicKey hash binding
        guard let pkData = Data(base64Encoded: publicKeyBase64) else {
            throw SignedAuditLogError.invalidInput("publicKey is not valid base64")
        }
        let pkHashHex = sha256Hex(pkData)
        let pkHashLen = pkHashHex.utf8.count

        return
            "v=\(signingSchemaVersion)" +
            "|ts=\(iso)" +
            "|type_len=\(typeLen)|type=\(eventType)" +
            "|dsv_len=\(dsvLen)|dsv=\(detailsSchemaVersion)" +
            "|details_len=\(detailsLen)|details=\(details)" +
            "|prev_len=\(prevLen)|prev=\(prev)" +
            "|pkhash_len=\(pkHashLen)|pkhash=\(pkHashHex)"
    }

    /// SHA256 hex for canonical payload string.
    static func hashPayload(_ canonicalPayload: String) -> String {
        sha256Hex(Data(canonicalPayload.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

