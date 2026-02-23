// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ComplianceTests.swift
// Aether3D
//
// Tests for ConsentStorage, RetentionPurgeEngine, and ComplianceManager.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import Aether3DCore

final class ConsentStorageTests: XCTestCase {

    var tempDirectory: URL!
    var encryptionKey: SymmetricKey!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        encryptionKey = SymmetricKey(size: .bits256)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Basic CRUD

    func testRecordConsent_CreatesRecord() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        let record = try await storage.recordConsent(
            operation: "biometric_capture",
            state: .granted
        )

        XCTAssertEqual(record.operation, "biometric_capture")
        XCTAssertEqual(record.state, .granted)
        XCTAssertFalse(record.id.isEmpty)
    }

    func testQueryConsent_ReturnsLatest() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        try await storage.recordConsent(operation: "sensor_data", state: .denied)
        try await storage.recordConsent(operation: "sensor_data", state: .granted)

        let latest = try await storage.queryConsent(operation: "sensor_data")
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.state, .granted)
    }

    func testQueryConsent_NoRecords_ReturnsNil() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        let result = try await storage.queryConsent(operation: "nonexistent")
        XCTAssertNil(result)
    }

    func testWithdrawConsent_SetsWithdrawnState() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        try await storage.recordConsent(operation: "capture", state: .granted)
        let withdrawn = try await storage.withdrawConsent(operation: "capture")

        XCTAssertEqual(withdrawn.state, .withdrawn)

        let latest = try await storage.queryConsent(operation: "capture")
        XCTAssertEqual(latest?.state, .withdrawn)
    }

    // MARK: - Validation

    func testIsConsentValid_GrantedNotExpired_ReturnsTrue() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        try await storage.recordConsent(operation: "capture", state: .granted, expirationDays: 30)
        let valid = try await storage.isConsentValid(operation: "capture")
        XCTAssertTrue(valid)
    }

    func testIsConsentValid_Denied_ReturnsFalse() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        try await storage.recordConsent(operation: "capture", state: .denied)
        let valid = try await storage.isConsentValid(operation: "capture")
        XCTAssertFalse(valid)
    }

    func testIsConsentValid_Withdrawn_ReturnsFalse() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        try await storage.recordConsent(operation: "capture", state: .granted)
        try await storage.withdrawConsent(operation: "capture")
        let valid = try await storage.isConsentValid(operation: "capture")
        XCTAssertFalse(valid)
    }

    func testIsConsentValid_NoConsent_ReturnsFalse() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("test.db").path,
            encryptionKey: encryptionKey
        )

        let valid = try await storage.isConsentValid(operation: "nonexistent")
        XCTAssertFalse(valid)
    }

    // MARK: - Persistence

    func testConsent_SurvivesReopen() async throws {
        let dbPath = tempDirectory.appendingPathComponent("persist.db").path

        // Write with first instance
        let storage1 = try ConsentStorage(dbPath: dbPath, encryptionKey: encryptionKey)
        try await storage1.recordConsent(operation: "test_op", state: .granted)
        try await storage1.close()

        // Read with new instance (same key)
        let storage2 = try ConsentStorage(dbPath: dbPath, encryptionKey: encryptionKey)
        let record = try await storage2.queryConsent(operation: "test_op")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .granted)
        XCTAssertEqual(record?.operation, "test_op")
    }

    func testDecrypt_WrongKey_ReturnsNil() async throws {
        let dbPath = tempDirectory.appendingPathComponent("wrongkey.db").path

        // Write with key 1
        let storage1 = try ConsentStorage(dbPath: dbPath, encryptionKey: encryptionKey)
        try await storage1.recordConsent(operation: "test_op", state: .granted)
        try await storage1.close()

        // Try read with different key — decryption will fail, queryConsent returns nil
        let wrongKey = SymmetricKey(size: .bits256)
        let storage2 = try ConsentStorage(dbPath: dbPath, encryptionKey: wrongKey)
        // queryAllConsents uses try? internally for individual records,
        // so wrong-key decryption failures result in skipped records
        let allRecords = try await storage2.queryAllConsents()
        XCTAssertTrue(allRecords.isEmpty)
    }

    // MARK: - Purge

    func testPurgeExpired_RemovesOldRecords() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("purge.db").path,
            encryptionKey: encryptionKey
        )

        // Record with 0-day expiration (already expired)
        try await storage.recordConsent(operation: "old_op", state: .granted, expirationDays: 0)
        // Record with 365-day expiration (still valid)
        try await storage.recordConsent(operation: "new_op", state: .granted, expirationDays: 365)

        // Small delay to ensure the 0-day record is expired
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let purged = try await storage.purgeExpiredConsents()
        XCTAssertEqual(purged, 1)

        let remaining = try await storage.queryAllConsents()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.operation, "new_op")
    }

    // MARK: - Multiple Operations

    func testMultipleOperations_IndependentConsent() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("multi.db").path,
            encryptionKey: encryptionKey
        )

        try await storage.recordConsent(operation: "capture", state: .granted)
        try await storage.recordConsent(operation: "upload", state: .denied)

        let captureValid = try await storage.isConsentValid(operation: "capture")
        let uploadValid = try await storage.isConsentValid(operation: "upload")

        XCTAssertTrue(captureValid)
        XCTAssertFalse(uploadValid)
    }

    func testRecordConsent_WithMetadata() async throws {
        let storage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("meta.db").path,
            encryptionKey: encryptionKey
        )

        let record = try await storage.recordConsent(
            operation: "capture",
            state: .granted,
            metadata: ["source": "app_settings", "version": "1.0"]
        )

        XCTAssertEqual(record.metadata?["source"], "app_settings")
        XCTAssertEqual(record.metadata?["version"], "1.0")

        // Verify metadata survives round-trip
        let queried = try await storage.queryConsent(operation: "capture")
        XCTAssertEqual(queried?.metadata?["source"], "app_settings")
    }
}

// MARK: - Retention Purge Engine Tests

final class RetentionPurgeEngineTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - WAL Purge

    func testPurgeWALEntries_RemovesExpired() async throws {
        let dbPath = tempDirectory.appendingPathComponent("wal.db").path
        let storage = try SQLiteWALStorage(dbPath: dbPath)

        // Write an entry with old timestamp (400 days ago)
        let oldDate = Date().addingTimeInterval(-400 * 86400)
        let oldEntry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xAA, count: 32),
            signedEntryBytes: Data([0x01]),
            merkleState: Data([0x02]),
            committed: true,
            timestamp: oldDate
        )
        try await storage.writeEntry(oldEntry)

        // Write a recent entry
        let recentEntry = WALEntry(
            entryId: 2,
            hash: Data(repeating: 0xBB, count: 32),
            signedEntryBytes: Data([0x03]),
            merkleState: Data([0x04]),
            committed: true,
            timestamp: Date()
        )
        try await storage.writeEntry(recentEntry)

        let engine = try RetentionPurgeEngine(
            auditLogDirectory: tempDirectory.appendingPathComponent("audit")
        )

        let (purged, audited) = try await engine.purgeExpiredWALEntries(storage: storage)

        XCTAssertEqual(purged, 1)
        XCTAssertEqual(audited.count, 1)
        XCTAssertEqual(audited.first?.itemType, "wal_entry")

        // Verify only recent entry remains
        let remaining = try await storage.readEntries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.entryId, 2)
    }

    func testPurgeWALEntries_KeepsRecent() async throws {
        let dbPath = tempDirectory.appendingPathComponent("wal.db").path
        let storage = try SQLiteWALStorage(dbPath: dbPath)

        // Write only recent entries
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xCC, count: 32),
            signedEntryBytes: Data([0x05]),
            merkleState: Data([0x06]),
            committed: true,
            timestamp: Date()
        )
        try await storage.writeEntry(entry)

        let engine = try RetentionPurgeEngine(
            auditLogDirectory: tempDirectory.appendingPathComponent("audit")
        )

        let (purged, _) = try await engine.purgeExpiredWALEntries(storage: storage)
        XCTAssertEqual(purged, 0)

        let remaining = try await storage.readEntries()
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - File Purge

    func testPurgeFiles_RemovesOldFiles() async throws {
        let fileDir = tempDirectory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)

        // Create a file and set its modification date to 200 days ago
        let oldFile = fileDir.appendingPathComponent("old_data.bin")
        try Data([0x01, 0x02]).write(to: oldFile)

        let oldDate = Date().addingTimeInterval(-200 * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: oldFile.path
        )

        // Create a recent file
        let newFile = fileDir.appendingPathComponent("new_data.bin")
        try Data([0x03, 0x04]).write(to: newFile)

        let engine = try RetentionPurgeEngine(
            auditLogDirectory: tempDirectory.appendingPathComponent("audit")
        )

        let policy = RetentionPolicy(
            name: "test_policy",
            retentionDays: 180,
            appliesTo: .sensitivePI
        )

        let (purged, audited) = try await engine.purgeExpiredFiles(
            directory: fileDir,
            policy: policy
        )

        XCTAssertEqual(purged, 1)
        XCTAssertEqual(audited.count, 1)
        XCTAssertEqual(audited.first?.policy, "test_policy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
    }

    // MARK: - Audit Log

    func testAuditLog_Persistence() async throws {
        let auditDir = tempDirectory.appendingPathComponent("audit")
        let auditLog = try PurgeAuditLog(logDirectory: auditDir)

        let record = PurgeAuditRecord(
            itemId: "test_entry_1",
            itemType: "wal_entry",
            policy: "GDPR_PersonalData",
            originalTimestamp: Date().addingTimeInterval(-400 * 86400)
        )

        try await auditLog.recordPurge(record)

        let records = try await auditLog.readAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.itemId, "test_entry_1")
        XCTAssertEqual(records.first?.policy, "GDPR_PersonalData")
    }

    // MARK: - Default Policies

    func testDefaultPolicies_MatchConstants() {
        let defaults = RetentionPolicy.defaults
        XCTAssertEqual(defaults.count, 2)

        let pipl = defaults.first { $0.appliesTo == .sensitivePI }
        XCTAssertEqual(pipl?.retentionDays, ComplianceConstants.cnSensitivePIRetentionDays)

        let gdpr = defaults.first { $0.appliesTo == .personalData }
        XCTAssertEqual(gdpr?.retentionDays, ComplianceConstants.gdprDataRetentionDays)
    }

    // MARK: - Full Purge

    func testRunFullPurge_CombinesResults() async throws {
        let dbPath = tempDirectory.appendingPathComponent("wal.db").path
        let storage = try SQLiteWALStorage(dbPath: dbPath)

        // Old WAL entry
        let oldEntry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xDD, count: 32),
            signedEntryBytes: Data([0x07]),
            merkleState: Data([0x08]),
            committed: true,
            timestamp: Date().addingTimeInterval(-400 * 86400)
        )
        try await storage.writeEntry(oldEntry)

        let engine = try RetentionPurgeEngine(
            auditLogDirectory: tempDirectory.appendingPathComponent("audit")
        )

        let result = try await engine.runFullPurge(walStorage: storage)

        XCTAssertEqual(result.walEntriesPurged, 1)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.totalPurged, 1)
    }
}

// MARK: - Compliance Manager Tests

final class ComplianceManagerTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testInit_CreatesBothSubsystems() async throws {
        let key = SymmetricKey(size: .bits256)
        let manager = try ComplianceManager(
            databaseDirectory: tempDirectory.appendingPathComponent("compliance"),
            encryptionKey: key
        )

        // Verify consent operations work
        try await manager.recordConsent(operation: "test", state: .granted)
        let valid = try await manager.isConsentValid(operation: "test")
        XCTAssertTrue(valid)
    }

    func testRecordAndQueryConsent_EndToEnd() async throws {
        let key = SymmetricKey(size: .bits256)
        let manager = try ComplianceManager(
            databaseDirectory: tempDirectory.appendingPathComponent("compliance"),
            encryptionKey: key
        )

        try await manager.recordConsent(
            operation: "3d_capture",
            state: .granted,
            metadata: ["source": "settings"]
        )

        let record = try await manager.queryConsent(operation: "3d_capture")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .granted)
        XCTAssertEqual(record?.metadata?["source"], "settings")
    }

    func testWithdrawConsent_EndToEnd() async throws {
        let key = SymmetricKey(size: .bits256)
        let manager = try ComplianceManager(
            databaseDirectory: tempDirectory.appendingPathComponent("compliance"),
            encryptionKey: key
        )

        try await manager.recordConsent(operation: "upload", state: .granted)
        try await manager.withdrawConsent(operation: "upload")

        let valid = try await manager.isConsentValid(operation: "upload")
        XCTAssertFalse(valid)
    }

    func testOnAppStartup_RunsPurge() async throws {
        let key = SymmetricKey(size: .bits256)
        let manager = try ComplianceManager(
            databaseDirectory: tempDirectory.appendingPathComponent("compliance"),
            encryptionKey: key
        )

        // Just verify it runs without error
        let result = try await manager.onAppStartup()
        XCTAssertTrue(result.errors.isEmpty)
    }
}
