// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SignedAuditLog.swift
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

/// Thread-safe signed audit log with chain integrity.
///
/// **SECURITY FIX**: Added NSLock to protect `lastSignature` and `writer` from
/// concurrent access. Previous implementation had a TOCTOU race condition:
///
///   Thread A: read lastSignature (nil)
///   Thread B: read lastSignature (nil)     ← both see same stale value
///   Thread A: write entry (prevSig=nil), update lastSignature to sig_A
///   Thread B: write entry (prevSig=nil), update lastSignature to sig_B
///   Result: Chain is BROKEN — entry B has wrong prevSignature
///
/// The lock serializes all append() calls, ensuring each entry correctly
/// chains from the previous one. The lock also protects writer.appendRawLine()
/// from interleaved writes.
final class SignedAuditLog {
    private let writer: AuditFileWriter
    private let keyStore: SigningKeyStore
    private var lastSignature: String?
    private let lock = NSLock()  // SECURITY FIX: protects lastSignature + writer

    init(fileURL: URL, keyStore: SigningKeyStore) throws {
        do {
            self.writer = try AuditFileWriter(url: fileURL, skipRecovery: false)
        } catch {
            throw SignedAuditLogError.ioFailed("AuditFileWriter init failed: \(error)")
        }

        // Patch D: FORMALLY SEALED: must store keyStore (fix v1.2.1 bug)
        self.keyStore = keyStore

        do {
            self.lastSignature = try Self.loadLastSignature(from: fileURL)
        } catch let e as SignedAuditLogError {
            throw e
        } catch {
            throw SignedAuditLogError.tailReadFailed("loadLastSignature failed: \(error)")
        }
    }

    func append(eventType: String, detailsJson: String?, detailsSchemaVersion: String) throws {
        // SECURITY FIX: Lock serializes all append() calls to prevent TOCTOU on lastSignature.
        // The entire read-compute-write sequence must be atomic.
        lock.lock()
        defer { lock.unlock() }

        do {
            try SignedAuditEntry.validateInput(
                eventType: eventType,
                detailsSchemaVersion: detailsSchemaVersion,
                detailsJson: detailsJson
            )

            let timestamp = WallClock.now()
            let signingSchemaVersion = SignedAuditEntry.currentSigningSchemaVersion

            let material = try keyStore.getOrCreateSigningKey()
            let publicKey = material.publicKeyBase64

            let canonical = try SignedAuditEntry.canonicalPayload(
                signingSchemaVersion: signingSchemaVersion,
                timestamp: timestamp,
                eventType: eventType,
                detailsSchemaVersion: detailsSchemaVersion,
                detailsJson: detailsJson,
                prevSignature: lastSignature,
                publicKeyBase64: publicKey
            )

            let payloadHash = SignedAuditEntry.hashPayload(canonical)

            let sigData = try material.sign(Data(canonical.utf8))
            let signature = sigData.base64EncodedString()

            let entry = SignedAuditEntry(
                signingSchemaVersion: signingSchemaVersion,
                timestamp: timestamp,
                eventType: eventType,
                detailsJson: detailsJson,
                detailsSchemaVersion: detailsSchemaVersion,
                publicKey: publicKey,
                signature: signature,
                prevSignature: lastSignature,
                payloadHash: payloadHash
            )

            let encoder = SignedAuditCoding.makeEncoder()
            let encoded = try encoder.encode(entry)
            guard let jsonLine = String(data: encoded, encoding: .utf8) else {
                throw SignedAuditLogError.encodingFailed("JSON data to string failed")
            }

            // writer enforces single-line safety
            do {
                try writer.appendRawLine(jsonLine)
            } catch let e as AuditFileWriterError {
                switch e {
                case .invalidInput(let msg):
                    throw SignedAuditLogError.invalidInput("appendRawLine: \(msg)")
                default:
                    throw SignedAuditLogError.ioFailed("appendRawLine failed: \(e)")
                }
            } catch {
                throw SignedAuditLogError.ioFailed("appendRawLine failed: \(error)")
            }

            lastSignature = signature

        } catch let e as SignedAuditLogError {
            throw e
        } catch let e as SigningKeyStoreError {
            throw SignedAuditLogError.ioFailed("SigningKeyStore error: \(e)")
        } catch {
            throw SignedAuditLogError.ioFailed("append failed: \(error)")
        }
    }

    // MARK: - Verification

    static func verifyOrThrow(entries: [SignedAuditEntry]) throws {
        var prevSig: String? = nil

        for (idx, e) in entries.enumerated() {
            // 0) schema support
            if e.signingSchemaVersion != SignedAuditEntry.currentSigningSchemaVersion {
                throw SignedAuditLogError.unsupportedSigningSchema(
                    entryIndex: idx,
                    version: e.signingSchemaVersion
                )
            }

            // 1) chain
            if e.prevSignature != prevSig {
                // Patch C: chainBroken reason with prefix-only (first 8 chars)
                let expectedPrefix = prevSig?.prefix(8) ?? "nil"
                let gotPrefix = e.prevSignature?.prefix(8) ?? "nil"
                throw SignedAuditLogError.chainBroken(
                    entryIndex: idx,
                    reason: "prevSignature mismatch: expected \(expectedPrefix), got \(gotPrefix)"
                )
            }

            // 2) base64 decode publicKey/signature (for canonical + signature verify)
            guard let pkData = Data(base64Encoded: e.publicKey) else {
                throw SignedAuditLogError.invalidBase64(entryIndex: idx, field: "publicKey")
            }
            guard let sigData = Data(base64Encoded: e.signature) else {
                throw SignedAuditLogError.invalidBase64(entryIndex: idx, field: "signature")
            }

            // 3) rebuild canonical
            let canonical: String
            do {
                canonical = try SignedAuditEntry.canonicalPayload(
                    signingSchemaVersion: e.signingSchemaVersion,
                    timestamp: e.timestamp,
                    eventType: e.eventType,
                    detailsSchemaVersion: e.detailsSchemaVersion,
                    detailsJson: e.detailsJson,
                    prevSignature: e.prevSignature,
                    publicKeyBase64: e.publicKey
                )
            } catch let err as SignedAuditLogError {
                throw err
            } catch {
                throw SignedAuditLogError.invalidInput("canonical rebuild failed at idx=\(idx): \(error)")
            }

            // 4) hash mismatch (payload tamper)
            // Patch C: hashMismatch without hash values (reduce information leakage)
            let computedHash = SignedAuditEntry.hashPayload(canonical)
            if computedHash != e.payloadHash {
                throw SignedAuditLogError.hashMismatch(entryIndex: idx)
            }

            // 5) verify signature
            do {
                let pub = try Curve25519.Signing.PublicKey(rawRepresentation: pkData)
                let ok = pub.isValidSignature(sigData, for: Data(canonical.utf8))
                if !ok {
                    throw SignedAuditLogError.signatureInvalid(entryIndex: idx)
                }
            } catch let err as SignedAuditLogError {
                throw err
            } catch {
                throw SignedAuditLogError.invalidPublicKeyFormat(
                    entryIndex: idx,
                    reason: error.localizedDescription
                )
            }

            prevSig = e.signature
        }
    }

    static func verify(entries: [SignedAuditEntry]) -> Bool {
        do { try verifyOrThrow(entries: entries); return true }
        catch { return false }
    }

    // MARK: - Tail reading (last signature)

    /// Load last signature by reading tail bytes.
    /// Handles:
    /// - empty file
    /// - file without trailing newline
    /// - UTF-8 safe boundaries (best effort by tail size)
    /// Behavior:
    /// - If last line cannot decode as SignedAuditEntry, return nil (do not throw).
    private static func loadLastSignature(from fileURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw SignedAuditLogError.tailReadFailed("open file failed: \(error)")
        }

        defer {
            #if swift(>=5.9)
            try? fh.close()
            #else
            fh.closeFile()
            #endif
        }

        fh.seekToEndOfFile()
        let size = fh.offsetInFile

        if size == 0 { return nil }

        let tail: UInt64 = min(8192, size)
        fh.seek(toFileOffset: size - tail)

        let data = fh.readDataToEndOfFile()
        if data.isEmpty { return nil }

        // Find last newline in tail
        let lastNL = data.lastIndex(of: 0x0A)

        let lastLineData: Data
        if let nl = lastNL {
            // Extract previous line content (exclude trailing newline)
            if nl == data.startIndex {
                return nil
            }
            let start: Data.Index
            if let prevNL = data[..<nl].lastIndex(of: 0x0A) {
                start = data.index(after: prevNL)
            } else {
                start = data.startIndex
            }
            lastLineData = data[start..<nl]
        } else {
            // No newline at all => whole tail is last line
            lastLineData = data
        }

        // If last line is empty, nil
        if lastLineData.isEmpty { return nil }

        // Decode
        let decoder = SignedAuditCoding.makeDecoder()
        guard let entry = try? decoder.decode(SignedAuditEntry.self, from: lastLineData) else {
            // Do not throw: tolerate tail garbage
            return nil
        }

        return entry.signature
    }
}

