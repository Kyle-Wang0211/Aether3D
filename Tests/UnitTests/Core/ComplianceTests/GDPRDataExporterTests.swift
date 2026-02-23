// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GDPRDataExporterTests.swift
// Aether3D
//
// Tests for GDPRDataExporter (GDPR Article 15 data export).
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import Aether3DCore

final class GDPRDataExporterTests: XCTestCase {

    var tempDir: URL!
    var consentStorage: ConsentStorage!
    var purgeEngine: RetentionPurgeEngine!
    var exporter: GDPRDataExporter!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gdpr_export_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let key = SymmetricKey(size: .bits256)
        consentStorage = try ConsentStorage(
            dbPath: tempDir.appendingPathComponent("consent.db").path,
            encryptionKey: key
        )
        purgeEngine = try RetentionPurgeEngine(
            auditLogDirectory: tempDir.appendingPathComponent("audit")
        )
        exporter = GDPRDataExporter(
            consentStorage: consentStorage,
            purgeEngine: purgeEngine
        )
    }

    override func tearDown() async throws {
        try? await consentStorage.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Export Generation

    func testGenerateExport_EmptyData() async throws {
        let package = try await exporter.generateExport()

        XCTAssertEqual(package.consentRecords.count, 0)
        XCTAssertEqual(package.anonymizationHistory.count, 0)
        XCTAssertEqual(package.purgeHistory.count, 0)
        XCTAssertTrue(package.dataInventory.count > 0, "Should have standard inventory")
        XCTAssertEqual(package.exportInfo.formatVersion, "1.0")
    }

    func testGenerateExport_WithConsentRecords() async throws {
        // Record some consent decisions
        try await consentStorage.recordConsent(operation: "3d_capture", state: .granted)
        try await consentStorage.recordConsent(operation: "imu_collection", state: .granted)
        try await consentStorage.recordConsent(operation: "3d_capture", state: .withdrawn)

        let package = try await exporter.generateExport()

        XCTAssertEqual(package.consentRecords.count, 3)
        // Most recent first (descending order)
        XCTAssertEqual(package.consentRecords[0].state, "withdrawn")
        XCTAssertEqual(package.consentRecords[0].operation, "3d_capture")
    }

    func testGenerateExport_WithAnonymizationHistory() async throws {
        let history = [
            AnonymizationResult(
                fileId: "capture_001",
                storageId: "store_001",
                regionsDetected: 3,
                regionsAnonymized: 3,
                originalDeleted: true,
                timestamp: Date(),
                consentId: "consent_abc"
            ),
            AnonymizationResult(
                fileId: "capture_002",
                storageId: "store_002",
                regionsDetected: 0,
                regionsAnonymized: 0,
                originalDeleted: true,
                timestamp: Date(),
                consentId: "consent_abc"
            )
        ]

        let package = try await exporter.generateExport(anonymizationHistory: history)

        XCTAssertEqual(package.anonymizationHistory.count, 2)
        XCTAssertEqual(package.anonymizationHistory[0].fileId, "capture_001")
        XCTAssertEqual(package.anonymizationHistory[0].regionsDetected, 3)
        XCTAssertTrue(package.anonymizationHistory[0].originalDeleted)
    }

    // MARK: - Export Writing

    func testWriteExport_CreatesFile() async throws {
        try await consentStorage.recordConsent(operation: "test", state: .granted)
        let package = try await exporter.generateExport()

        let exportDir = tempDir.appendingPathComponent("exports")
        let fileURL = try await exporter.writeExport(package, to: exportDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Verify it's valid JSON
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DataExportPackage.self, from: data)

        XCTAssertEqual(decoded.consentRecords.count, 1)
    }

    func testWriteExport_FilenameContainsTimestamp() async throws {
        let package = try await exporter.generateExport()
        let exportDir = tempDir.appendingPathComponent("exports")
        let fileURL = try await exporter.writeExport(package, to: exportDir)

        XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("aether3d_data_export_"))
        XCTAssertTrue(fileURL.lastPathComponent.hasSuffix(".json"))
    }

    // MARK: - Data Inventory

    func testDataInventory_ContainsRequiredCategories() async throws {
        let package = try await exporter.generateExport()

        let categories = package.dataInventory.map(\.category)
        XCTAssertTrue(categories.contains("Consent Records"))
        XCTAssertTrue(categories.contains("3D Capture Data (Anonymized)"))
        XCTAssertTrue(categories.contains("IMU Sensor Data"))
        XCTAssertTrue(categories.contains("Audit Logs"))
    }

    func testDataInventory_HasLegalBasis() async throws {
        let package = try await exporter.generateExport()

        for item in package.dataInventory {
            XCTAssertFalse(item.legalBasis.isEmpty, "\(item.category) missing legal basis")
            XCTAssertFalse(item.retentionPeriod.isEmpty, "\(item.category) missing retention period")
            XCTAssertFalse(item.processingPurpose.isEmpty, "\(item.category) missing purpose")
        }
    }

    // MARK: - Export Info

    func testExportInfo_Defaults() async throws {
        let package = try await exporter.generateExport()

        XCTAssertEqual(package.exportInfo.formatVersion, "1.0")
        XCTAssertTrue(package.exportInfo.applicableRegulations.contains("GDPR"))
        XCTAssertTrue(package.exportInfo.applicableRegulations.contains("PIPL"))
        XCTAssertTrue(package.exportInfo.applicableRegulations.contains("CCPA"))
    }
}
