// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RetentionPurgeEngine.swift
// Aether3D
//
// Data retention enforcement engine.
// Enforces ComplianceConstants retention periods (PIPL 180d, GDPR 365d)
// by purging expired data from SQLite WAL storage and filesystem.
//

import Foundation

// MARK: - Types

/// Data category for retention policy
public enum DataCategory: String, Sendable, Codable {
    /// Sensitive personal information (PIPL: 180 days)
    case sensitivePI
    /// General personal data (GDPR: 365 days)
    case personalData
    /// Audit logs — not purged (compliance requirement to retain)
    case auditLog
}

/// Retention policy
public struct RetentionPolicy: Sendable {
    public let name: String
    public let retentionDays: Int
    public let appliesTo: DataCategory

    public init(name: String, retentionDays: Int, appliesTo: DataCategory) {
        self.name = name
        self.retentionDays = retentionDays
        self.appliesTo = appliesTo
    }

    /// Default policies from ComplianceConstants
    public static let defaults: [RetentionPolicy] = [
        RetentionPolicy(
            name: "PIPL_SensitivePI",
            retentionDays: ComplianceConstants.cnSensitivePIRetentionDays,
            appliesTo: .sensitivePI
        ),
        RetentionPolicy(
            name: "GDPR_PersonalData",
            retentionDays: ComplianceConstants.gdprDataRetentionDays,
            appliesTo: .personalData
        )
    ]
}

/// Audit record for each purge action
public struct PurgeAuditRecord: Sendable, Codable {
    public let itemId: String
    public let itemType: String
    public let policy: String
    public let originalTimestamp: Date
    public let purgeTimestamp: Date
    public let reason: String

    public init(
        itemId: String,
        itemType: String,
        policy: String,
        originalTimestamp: Date,
        purgeTimestamp: Date = Date(),
        reason: String = "retention_expired"
    ) {
        self.itemId = itemId
        self.itemType = itemType
        self.policy = policy
        self.originalTimestamp = originalTimestamp
        self.purgeTimestamp = purgeTimestamp
        self.reason = reason
    }
}

/// Result of a purge operation
public struct PurgeResult: Sendable {
    public let walEntriesPurged: Int
    public let filesPurged: Int
    public let consentsPurged: Int
    public let errors: [String]
    public let auditRecords: [PurgeAuditRecord]
    public let timestamp: Date

    public init(
        walEntriesPurged: Int = 0,
        filesPurged: Int = 0,
        consentsPurged: Int = 0,
        errors: [String] = [],
        auditRecords: [PurgeAuditRecord] = [],
        timestamp: Date = Date()
    ) {
        self.walEntriesPurged = walEntriesPurged
        self.filesPurged = filesPurged
        self.consentsPurged = consentsPurged
        self.errors = errors
        self.auditRecords = auditRecords
        self.timestamp = timestamp
    }

    /// Total items purged
    public var totalPurged: Int {
        walEntriesPurged + filesPurged + consentsPurged
    }
}

/// Retention purge errors
public enum RetentionPurgeError: Error, Sendable {
    case walStorageUnavailable
    case fileSystemError(String)
    case auditLogFailed(String)

    public var localizedDescription: String {
        switch self {
        case .walStorageUnavailable: return "WAL storage not available for purge"
        case .fileSystemError(let r): return "File system error: \(r)"
        case .auditLogFailed(let r): return "Audit log failed: \(r)"
        }
    }
}

// MARK: - Purge Audit Log

/// Append-only audit log for purge operations
///
/// Records every deletion with the reason and policy that triggered it.
/// Stored as newline-delimited JSON for simplicity and auditability.
public actor PurgeAuditLog {
    private let logFileURL: URL

    public init(logDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        self.logFileURL = logDirectory.appendingPathComponent("purge_audit.jsonl")
    }

    /// Append a purge record to the audit log
    public func recordPurge(_ record: PurgeAuditRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys

        var data = try encoder.encode(record)
        data.append(0x0A) // newline

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logFileURL)
        }
    }

    /// Read all purge records
    public func readAll() throws -> [PurgeAuditRecord] {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: logFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let lines = data.split(separator: 0x0A)
        return lines.compactMap { line in
            try? decoder.decode(PurgeAuditRecord.self, from: Data(line))
        }
    }
}

// MARK: - Retention Purge Engine

/// Data retention enforcement engine
///
/// Enforces retention policies by purging expired data from:
/// - SQLite WAL storage (via `purgeEntriesBefore`)
/// - Filesystem files (via modification date check)
/// - Consent records (via `ConsentStorage.purgeExpiredConsents`)
///
/// Every deletion is recorded in the purge audit log.
public actor RetentionPurgeEngine {

    private let policies: [RetentionPolicy]
    private let auditLog: PurgeAuditLog

    // MARK: - Initialization

    /// Initialize retention purge engine
    ///
    /// - Parameters:
    ///   - policies: Retention policies to enforce (defaults to PIPL + GDPR)
    ///   - auditLogDirectory: Directory for purge audit log
    public init(
        policies: [RetentionPolicy]? = nil,
        auditLogDirectory: URL
    ) throws {
        self.policies = policies ?? RetentionPolicy.defaults
        self.auditLog = try PurgeAuditLog(logDirectory: auditLogDirectory)
    }

    // MARK: - WAL Entry Purge

    /// Purge expired WAL entries
    ///
    /// Uses the shortest applicable retention period to determine cutoff.
    /// - Parameter storage: SQLite WAL storage to purge
    /// - Returns: Number of entries purged and audit records
    public func purgeExpiredWALEntries(
        storage: SQLiteWALStorage
    ) async throws -> (purged: Int, audited: [PurgeAuditRecord]) {
        let shortestPolicy = policies
            .filter { $0.appliesTo != .auditLog }
            .min(by: { $0.retentionDays < $1.retentionDays })

        guard let policy = shortestPolicy else { return (0, []) }

        let cutoff = cutoffDate(for: policy)

        // Read entries before deletion for audit
        let expiredEntries = try await storage.readEntriesBefore(cutoff)

        // Purge
        let purgedCount = try await storage.purgeEntriesBefore(cutoff)

        // Audit each deletion
        var auditRecords: [PurgeAuditRecord] = []
        for entry in expiredEntries {
            let record = PurgeAuditRecord(
                itemId: String(entry.entryId),
                itemType: "wal_entry",
                policy: policy.name,
                originalTimestamp: entry.timestamp
            )
            try await auditLog.recordPurge(record)
            auditRecords.append(record)
        }

        return (purgedCount, auditRecords)
    }

    // MARK: - File System Purge

    /// Purge expired files from a directory
    ///
    /// Files older than the retention period (by modification date) are deleted.
    /// - Parameters:
    ///   - directory: Directory to scan
    ///   - policy: Retention policy to apply
    /// - Returns: Number of files purged and audit records
    public func purgeExpiredFiles(
        directory: URL,
        policy: RetentionPolicy
    ) async throws -> (purged: Int, audited: [PurgeAuditRecord]) {
        let cutoff = cutoffDate(for: policy)
        let fm = FileManager.default

        guard fm.fileExists(atPath: directory.path) else {
            return (0, [])
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        )

        var purgedCount = 0
        var auditRecords: [PurgeAuditRecord] = []
        var errors: [String] = []

        for fileURL in contents {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            guard let modDate = resourceValues.contentModificationDate else { continue }

            if modDate < cutoff {
                do {
                    try fm.removeItem(at: fileURL)

                    let record = PurgeAuditRecord(
                        itemId: fileURL.lastPathComponent,
                        itemType: "file",
                        policy: policy.name,
                        originalTimestamp: modDate
                    )
                    try await auditLog.recordPurge(record)
                    auditRecords.append(record)
                    purgedCount += 1
                } catch {
                    errors.append("Failed to delete \(fileURL.lastPathComponent): \(error)")
                }
            }
        }

        return (purgedCount, auditRecords)
    }

    // MARK: - Full Purge

    /// Run a full retention purge across all storage types
    ///
    /// - Parameters:
    ///   - walStorage: Optional SQLite WAL storage to purge
    ///   - consentStorage: Optional consent storage to purge expired consents
    ///   - fileDirectories: Directories to scan for expired files
    /// - Returns: Combined purge result
    public func runFullPurge(
        walStorage: SQLiteWALStorage? = nil,
        consentStorage: ConsentStorage? = nil,
        fileDirectories: [URL] = []
    ) async throws -> PurgeResult {
        var totalWAL = 0
        var totalFiles = 0
        var totalConsents = 0
        var allAudit: [PurgeAuditRecord] = []
        var allErrors: [String] = []

        // Purge WAL entries
        if let wal = walStorage {
            do {
                let (purged, audited) = try await purgeExpiredWALEntries(storage: wal)
                totalWAL = purged
                allAudit.append(contentsOf: audited)
            } catch {
                allErrors.append("WAL purge: \(error)")
            }
        }

        // Purge consent records
        if let consent = consentStorage {
            do {
                totalConsents = try await consent.purgeExpiredConsents()
            } catch {
                allErrors.append("Consent purge: \(error)")
            }
        }

        // Purge files per policy
        for policy in policies where policy.appliesTo != .auditLog {
            for directory in fileDirectories {
                do {
                    let (purged, audited) = try await purgeExpiredFiles(
                        directory: directory,
                        policy: policy
                    )
                    totalFiles += purged
                    allAudit.append(contentsOf: audited)
                } catch {
                    allErrors.append("File purge (\(directory.path)): \(error)")
                }
            }
        }

        return PurgeResult(
            walEntriesPurged: totalWAL,
            filesPurged: totalFiles,
            consentsPurged: totalConsents,
            errors: allErrors,
            auditRecords: allAudit
        )
    }

    // MARK: - Audit Log Access

    /// Read all purge audit records
    public func readAuditLog() async throws -> [PurgeAuditRecord] {
        return try await auditLog.readAll()
    }

    // MARK: - Private

    private func cutoffDate(for policy: RetentionPolicy) -> Date {
        return Date().addingTimeInterval(-TimeInterval(policy.retentionDays) * 86400)
    }
}
