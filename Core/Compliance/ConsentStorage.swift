// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ConsentStorage.swift
// Aether3D
//
// Encrypted SQLite-backed persistent consent storage.
// GDPR/PIPL compliance: consent records survive app restarts,
// encrypted at rest with AES-256-GCM.
//

import Foundation
import CSQLite
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// MARK: - Types

/// Persistent consent state
public enum PersistentConsentState: String, Sendable, Codable, CaseIterable {
    case granted
    case denied
    case pending
    case withdrawn
    case expired
}

/// Persistent consent record
public struct PersistentConsentRecord: Sendable, Codable {
    public let id: String
    public let operation: String
    public let state: PersistentConsentState
    public let timestamp: Date
    public let expirationDate: Date
    public let metadata: [String: String]?

    public init(
        id: String = UUID().uuidString,
        operation: String,
        state: PersistentConsentState,
        timestamp: Date = Date(),
        expirationDate: Date,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.operation = operation
        self.state = state
        self.timestamp = timestamp
        self.expirationDate = expirationDate
        self.metadata = metadata
    }
}

/// Consent storage errors
public enum ConsentStorageError: Error, Sendable {
    case databaseUnavailable
    case prepareFailed(String)
    case executeFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidData(String)

    public var localizedDescription: String {
        switch self {
        case .databaseUnavailable: return "Consent database not available"
        case .prepareFailed(let r): return "SQL prepare failed: \(r)"
        case .executeFailed(let r): return "SQL execute failed: \(r)"
        case .encryptionFailed(let r): return "Encryption failed: \(r)"
        case .decryptionFailed(let r): return "Decryption failed: \(r)"
        case .invalidData(let r): return "Invalid data: \(r)"
        }
    }
}

// MARK: - SQLite Handle

private final class ConsentSQLiteHandle: @unchecked Sendable {
    var db: OpaquePointer?
    init(db: OpaquePointer?) { self.db = db }
}

// MARK: - ConsentStorage

/// Encrypted SQLite-backed persistent consent storage
///
/// Stores consent records in an encrypted SQLite database.
/// Each record is encrypted with AES-256-GCM using per-record key derivation.
/// The `operation` column is stored in plaintext for query efficiency
/// (it is a non-sensitive category name, not PII).
public actor ConsentStorage {

    private let handle: ConsentSQLiteHandle
    private let dbPath: String
    private let encryptionKey: SymmetricKey

    // MARK: - Initialization

    /// Initialize consent storage
    ///
    /// - Parameters:
    ///   - dbPath: Path to SQLite database file
    ///   - encryptionKey: Master encryption key (256-bit) for AES-256-GCM
    public init(dbPath: String, encryptionKey: SymmetricKey) throws {
        self.dbPath = dbPath
        self.encryptionKey = encryptionKey

        var db: OpaquePointer?
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            throw ConsentStorageError.databaseUnavailable
        }

        self.handle = ConsentSQLiteHandle(db: db)
        try enableWALMode()
        try createTable()
    }

    // MARK: - Record Consent

    /// Record a consent decision
    ///
    /// - Parameters:
    ///   - operation: Operation category (e.g., "biometric_capture", "sensor_data")
    ///   - state: Consent state
    ///   - expirationDays: Days until consent expires (default: GDPR 365 days)
    ///   - metadata: Optional context metadata
    /// - Returns: The persisted consent record
    @discardableResult
    public func recordConsent(
        operation: String,
        state: PersistentConsentState,
        expirationDays: Int = ComplianceConstants.gdprDataRetentionDays,
        metadata: [String: String]? = nil
    ) async throws -> PersistentConsentRecord {
        let now = Date()
        let record = PersistentConsentRecord(
            operation: operation,
            state: state,
            timestamp: now,
            expirationDate: now.addingTimeInterval(TimeInterval(expirationDays) * 86400),
            metadata: metadata
        )

        let encryptedData = try encrypt(record)
        let timestampNs = Int64(now.timeIntervalSince1970 * 1_000_000_000)
        let expirationNs = Int64(record.expirationDate.timeIntervalSince1970 * 1_000_000_000)

        guard let db = handle.db else {
            throw ConsentStorageError.databaseUnavailable
        }

        let sql = """
            INSERT INTO consent_records (id, operation, encrypted_data, timestamp_ns, expiration_ns)
            VALUES (?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ConsentStorageError.prepareFailed("recordConsent")
        }
        defer { sqlite3_finalize(statement) }

        let idCStr = record.id.cString(using: .utf8)!
        let opCStr = operation.cString(using: .utf8)!

        sqlite3_bind_text(statement, 1, idCStr, -1, nil)
        sqlite3_bind_text(statement, 2, opCStr, -1, nil)
        encryptedData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(statement, 3, ptr.baseAddress, Int32(encryptedData.count), nil)
        }
        sqlite3_bind_int64(statement, 4, timestampNs)
        sqlite3_bind_int64(statement, 5, expirationNs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ConsentStorageError.executeFailed("recordConsent")
        }

        return record
    }

    // MARK: - Query Consent

    /// Query the most recent valid consent for an operation
    ///
    /// Returns the latest non-expired consent record for the operation,
    /// or nil if no consent exists.
    public func queryConsent(operation: String) async throws -> PersistentConsentRecord? {
        guard let db = handle.db else {
            throw ConsentStorageError.databaseUnavailable
        }

        let sql = """
            SELECT id, encrypted_data FROM consent_records
            WHERE operation = ?
            ORDER BY timestamp_ns DESC
            LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ConsentStorageError.prepareFailed("queryConsent")
        }
        defer { sqlite3_finalize(statement) }

        let opCStr = operation.cString(using: .utf8)!
        sqlite3_bind_text(statement, 1, opCStr, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let idPtr = sqlite3_column_text(statement, 0)
        let id = idPtr.map { String(cString: $0) } ?? ""

        let blobLength = sqlite3_column_bytes(statement, 1)
        guard let blobPtr = sqlite3_column_blob(statement, 1) else {
            throw ConsentStorageError.invalidData("null encrypted_data")
        }
        let encryptedData = Data(bytes: blobPtr, count: Int(blobLength))

        return try decrypt(encryptedData, id: id)
    }

    /// Query all consent records
    public func queryAllConsents() async throws -> [PersistentConsentRecord] {
        guard let db = handle.db else {
            throw ConsentStorageError.databaseUnavailable
        }

        let sql = "SELECT id, encrypted_data FROM consent_records ORDER BY timestamp_ns DESC"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ConsentStorageError.prepareFailed("queryAllConsents")
        }
        defer { sqlite3_finalize(statement) }

        var records: [PersistentConsentRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idPtr = sqlite3_column_text(statement, 0)
            let id = idPtr.map { String(cString: $0) } ?? ""

            let blobLength = sqlite3_column_bytes(statement, 1)
            guard let blobPtr = sqlite3_column_blob(statement, 1) else { continue }
            let encryptedData = Data(bytes: blobPtr, count: Int(blobLength))

            if let record = try? decrypt(encryptedData, id: id) {
                records.append(record)
            }
        }

        return records
    }

    // MARK: - Withdraw Consent

    /// Withdraw consent for an operation
    ///
    /// Inserts a new record with state `.withdrawn`.
    /// Previous records are preserved for audit trail.
    @discardableResult
    public func withdrawConsent(operation: String) async throws -> PersistentConsentRecord {
        return try await recordConsent(
            operation: operation,
            state: .withdrawn,
            metadata: ["reason": "user_withdrawal"]
        )
    }

    // MARK: - Validate Consent

    /// Check if consent is currently valid for an operation
    ///
    /// Returns true only if the most recent consent is `.granted` and not expired.
    public func isConsentValid(operation: String) async throws -> Bool {
        guard let record = try await queryConsent(operation: operation) else {
            return false
        }
        return record.state == .granted && record.expirationDate > Date()
    }

    // MARK: - Purge Expired

    /// Delete expired consent records from the database
    ///
    /// - Returns: Number of records purged
    @discardableResult
    public func purgeExpiredConsents() async throws -> Int {
        guard let db = handle.db else {
            throw ConsentStorageError.databaseUnavailable
        }

        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let sql = "DELETE FROM consent_records WHERE expiration_ns < ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ConsentStorageError.prepareFailed("purgeExpiredConsents")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, nowNs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ConsentStorageError.executeFailed("purgeExpiredConsents")
        }

        return Int(sqlite3_changes(db))
    }

    // MARK: - Close

    /// Close the database connection
    public func close() async throws {
        guard let db = handle.db else { return }
        sqlite3_close(db)
        handle.db = nil
    }

    // MARK: - Private: Database Setup

    private nonisolated func enableWALMode() throws {
        guard let db = handle.db else {
            throw ConsentStorageError.databaseUnavailable
        }
        let result = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        guard result == SQLITE_OK else {
            throw ConsentStorageError.executeFailed("WAL mode: \(result)")
        }
    }

    private nonisolated func createTable() throws {
        guard let db = handle.db else {
            throw ConsentStorageError.databaseUnavailable
        }

        let sql = """
            CREATE TABLE IF NOT EXISTS consent_records (
                id TEXT PRIMARY KEY,
                operation TEXT NOT NULL,
                encrypted_data BLOB NOT NULL,
                timestamp_ns INTEGER NOT NULL,
                expiration_ns INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_consent_operation ON consent_records(operation);
            CREATE INDEX IF NOT EXISTS idx_consent_expiration ON consent_records(expiration_ns);
        """

        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw ConsentStorageError.executeFailed("create table: \(result)")
        }
    }

    // MARK: - Private: Encryption

    /// Encrypt a consent record using AES-256-GCM
    ///
    /// Per-record key derived via HKDF-SHA256 from master key + record ID.
    private func encrypt(_ record: PersistentConsentRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys

        let plaintext: Data
        do {
            plaintext = try encoder.encode(record)
        } catch {
            throw ConsentStorageError.encryptionFailed("JSON encode: \(error)")
        }

        let recordKey = deriveRecordKey(recordId: record.id)

        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: recordKey)
            var result = Data()
            result.append(contentsOf: sealedBox.nonce)
            result.append(sealedBox.ciphertext)
            result.append(sealedBox.tag)
            return result
        } catch {
            throw ConsentStorageError.encryptionFailed("AES-GCM: \(error)")
        }
    }

    /// Decrypt a consent record from AES-256-GCM ciphertext
    private func decrypt(_ data: Data, id: String) throws -> PersistentConsentRecord {
        // Format: [nonce (12 bytes) || ciphertext || tag (16 bytes)]
        guard data.count >= 28 else {
            throw ConsentStorageError.decryptionFailed("data too short: \(data.count)")
        }

        let nonceData = data.prefix(12)
        let tagData = data.suffix(16)
        let ciphertext = data.dropFirst(12).dropLast(16)

        let recordKey = deriveRecordKey(recordId: id)

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
            let plaintext = try AES.GCM.open(sealedBox, using: recordKey)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(PersistentConsentRecord.self, from: plaintext)
        } catch {
            throw ConsentStorageError.decryptionFailed("\(error)")
        }
    }

    /// Derive per-record key from master key via HKDF-SHA256
    private func deriveRecordKey(recordId: String) -> SymmetricKey {
        let info = recordId.data(using: .utf8) ?? Data()
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: encryptionKey,
            info: info,
            outputByteCount: 32
        )
    }
}
