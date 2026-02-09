// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GDPRDataExporter.swift
// Aether3D
//
// GDPR Article 15 "Right of Access" — data subject access request (DSAR).
// Exports all personal data associated with a user as a structured JSON package.
//
// Also satisfies PIPL Article 45 (data portability) and
// CCPA §1798.100 (right to know).
//

import Foundation

// MARK: - Export Data Model

/// Top-level container for a GDPR data export package
public struct DataExportPackage: Sendable, Codable {
    /// Export metadata
    public let exportInfo: ExportInfo
    /// All consent records
    public let consentRecords: [ExportedConsentRecord]
    /// Anonymization history (what was processed through 方案A)
    public let anonymizationHistory: [ExportedAnonymizationRecord]
    /// Retention purge history (what was auto-deleted and why)
    public let purgeHistory: [ExportedPurgeRecord]
    /// Data categories held and their legal basis
    public let dataInventory: [DataInventoryItem]
}

/// Export metadata
public struct ExportInfo: Sendable, Codable {
    /// ISO 8601 timestamp of export generation
    public let exportedAt: Date
    /// Export format version for forward compatibility
    public let formatVersion: String
    /// Legal basis for this export
    public let legalBasis: String
    /// Applicable regulations
    public let applicableRegulations: [String]
    /// Contact for questions about this export
    public let dataControllerContact: String

    public init(
        exportedAt: Date = Date(),
        formatVersion: String = "1.0",
        legalBasis: String = "GDPR Article 15 — Right of Access",
        applicableRegulations: [String] = ["GDPR", "PIPL", "CCPA"],
        dataControllerContact: String = "[INSERT CONTACT]"
    ) {
        self.exportedAt = exportedAt
        self.formatVersion = formatVersion
        self.legalBasis = legalBasis
        self.applicableRegulations = applicableRegulations
        self.dataControllerContact = dataControllerContact
    }
}

/// Exported consent record (decrypted for the data subject)
public struct ExportedConsentRecord: Sendable, Codable {
    public let id: String
    public let operation: String
    public let state: String
    public let grantedAt: Date
    public let expiresAt: Date
    public let metadata: [String: String]?
}

/// Exported anonymization record
public struct ExportedAnonymizationRecord: Sendable, Codable {
    public let fileId: String
    public let storageId: String
    public let regionsDetected: Int
    public let regionsAnonymized: Int
    public let originalDeleted: Bool
    public let processedAt: Date
    public let consentId: String
}

/// Exported purge record
public struct ExportedPurgeRecord: Sendable, Codable {
    public let itemId: String
    public let itemType: String
    public let policy: String
    public let originalTimestamp: Date
    public let purgedAt: Date
    public let reason: String
}

/// Data inventory item — describes a category of data held
public struct DataInventoryItem: Sendable, Codable {
    public let category: String
    public let description: String
    public let legalBasis: String
    public let retentionPeriod: String
    public let processingPurpose: String
}

// MARK: - Export Errors

public enum DataExportError: Error, Sendable {
    case consentQueryFailed(String)
    case auditLogReadFailed(String)
    case encodingFailed(String)
    case writeFailed(String)

    public var localizedDescription: String {
        switch self {
        case .consentQueryFailed(let r): return "Failed to query consent records: \(r)"
        case .auditLogReadFailed(let r): return "Failed to read audit log: \(r)"
        case .encodingFailed(let r): return "Failed to encode export package: \(r)"
        case .writeFailed(let r): return "Failed to write export file: \(r)"
        }
    }
}

// MARK: - GDPR Data Exporter

/// GDPR Article 15 data exporter
///
/// Generates a structured JSON package containing all personal data
/// associated with the user. This package is the response to a
/// Data Subject Access Request (DSAR).
///
/// The export includes:
/// 1. **Consent records** — every consent decision (granted, denied, withdrawn)
/// 2. **Anonymization history** — what captures were processed and how
/// 3. **Purge history** — what data was auto-deleted and under which policy
/// 4. **Data inventory** — categories of data held and their legal basis
///
/// Usage:
/// ```swift
/// let exporter = GDPRDataExporter(
///     consentStorage: consentStorage,
///     purgeEngine: purgeEngine
/// )
///
/// let package = try await exporter.generateExport(
///     anonymizationHistory: pipeline.getHistory()
/// )
///
/// let fileURL = try await exporter.writeExport(package, to: exportDir)
/// ```
public actor GDPRDataExporter {

    private let consentStorage: ConsentStorage
    private let purgeEngine: RetentionPurgeEngine

    /// Standard data inventory for Aether3D
    private static let standardInventory: [DataInventoryItem] = [
        DataInventoryItem(
            category: "Consent Records",
            description: "Records of user consent decisions for data processing operations",
            legalBasis: "GDPR Article 6(1)(a) — Consent",
            retentionPeriod: "Until expiration or withdrawal, then purged per retention policy",
            processingPurpose: "Legal compliance — proof of consent"
        ),
        DataInventoryItem(
            category: "3D Capture Data (Anonymized)",
            description: "Anonymized 3D capture data with sensitive regions irreversibly masked",
            legalBasis: "GDPR Article 6(1)(f) — Legitimate Interest (anonymized data is not personal data)",
            retentionPeriod: "Permanent (anonymized data exempt from retention limits)",
            processingPurpose: "3D model training and asset verification"
        ),
        DataInventoryItem(
            category: "IMU Sensor Data",
            description: "Accelerometer, gyroscope, and magnetometer readings during capture",
            legalBasis: "GDPR Article 6(1)(a) — Consent",
            retentionPeriod: "PIPL: 180 days, GDPR: 365 days",
            processingPurpose: "Motion analysis for capture quality assessment"
        ),
        DataInventoryItem(
            category: "Audit Logs",
            description: "Records of data processing, deletion, and compliance operations",
            legalBasis: "GDPR Article 6(1)(c) — Legal Obligation",
            retentionPeriod: "Permanent (regulatory requirement)",
            processingPurpose: "Compliance auditability and accountability"
        )
    ]

    // MARK: - Initialization

    /// Initialize GDPR data exporter
    ///
    /// - Parameters:
    ///   - consentStorage: Consent storage for exporting consent records
    ///   - purgeEngine: Retention purge engine for exporting purge history
    public init(
        consentStorage: ConsentStorage,
        purgeEngine: RetentionPurgeEngine
    ) {
        self.consentStorage = consentStorage
        self.purgeEngine = purgeEngine
    }

    // MARK: - Generate Export

    /// Generate a complete data export package
    ///
    /// Queries all consent records, anonymization history, and purge logs,
    /// then assembles them into a single structured package.
    ///
    /// - Parameter anonymizationHistory: History from AnonymizationPipeline
    /// - Returns: Complete data export package ready for serialization
    public func generateExport(
        anonymizationHistory: [AnonymizationResult] = []
    ) async throws -> DataExportPackage {

        // 1. Export consent records
        let consentRecords: [ExportedConsentRecord]
        do {
            let rawRecords = try await consentStorage.queryAllConsents()
            consentRecords = rawRecords.map { record in
                ExportedConsentRecord(
                    id: record.id,
                    operation: record.operation,
                    state: record.state.rawValue,
                    grantedAt: record.timestamp,
                    expiresAt: record.expirationDate,
                    metadata: record.metadata
                )
            }
        } catch {
            throw DataExportError.consentQueryFailed("\(error)")
        }

        // 2. Export anonymization history
        let anonymizationRecords = anonymizationHistory.map { result in
            ExportedAnonymizationRecord(
                fileId: result.fileId,
                storageId: result.storageId,
                regionsDetected: result.regionsDetected,
                regionsAnonymized: result.regionsAnonymized,
                originalDeleted: result.originalDeleted,
                processedAt: result.timestamp,
                consentId: result.consentId
            )
        }

        // 3. Export purge history
        let purgeRecords: [ExportedPurgeRecord]
        do {
            let rawPurge = try await purgeEngine.readAuditLog()
            purgeRecords = rawPurge.map { record in
                ExportedPurgeRecord(
                    itemId: record.itemId,
                    itemType: record.itemType,
                    policy: record.policy,
                    originalTimestamp: record.originalTimestamp,
                    purgedAt: record.purgeTimestamp,
                    reason: record.reason
                )
            }
        } catch {
            throw DataExportError.auditLogReadFailed("\(error)")
        }

        return DataExportPackage(
            exportInfo: ExportInfo(),
            consentRecords: consentRecords,
            anonymizationHistory: anonymizationRecords,
            purgeHistory: purgeRecords,
            dataInventory: Self.standardInventory
        )
    }

    // MARK: - Write Export

    /// Serialize and write the export package to a JSON file
    ///
    /// The file is named `aether3d_data_export_<timestamp>.json`
    /// and formatted with pretty-printing for human readability.
    ///
    /// - Parameters:
    ///   - package: The data export package to write
    ///   - directory: Directory to write the export file into
    /// - Returns: URL of the written export file
    @discardableResult
    public func writeExport(
        _ package: DataExportPackage,
        to directory: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(package)
        } catch {
            throw DataExportError.encodingFailed("\(error)")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "aether3d_data_export_\(timestamp).json"
        let fileURL = directory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL)
        } catch {
            throw DataExportError.writeFailed("\(error)")
        }

        return fileURL
    }
}
