// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AnonymizationPipelineTests.swift
// Aether3D
//
// Tests for AnonymizationPipeline (方案A).
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
@testable import Aether3DCore

// MARK: - Mock Implementations

/// Mock detector that always finds a face region
actor MockDetector: SensitiveRegionDetector {
    var callCount = 0
    var regionsToReturn: [SensitiveRegion] = [
        SensitiveRegion(
            type: .face,
            bounds: SensitiveRegion.RegionBounds(x: 100, y: 100, width: 50, height: 50)
        )
    ]

    func detectSensitiveRegions(in rawData: Data) async throws -> [SensitiveRegion] {
        callCount += 1
        return regionsToReturn
    }

    func getCallCount() -> Int { callCount }

    func setRegions(_ regions: [SensitiveRegion]) {
        regionsToReturn = regions
    }
}

/// Mock anonymizer that replaces data with zeros in detected regions
actor MockAnonymizer: DataAnonymizer {
    var callCount = 0

    func anonymize(rawData: Data, regions: [SensitiveRegion]) async throws -> Data {
        callCount += 1
        // Simulate anonymization: if regions detected, mark data as anonymized
        if regions.isEmpty {
            return rawData
        }
        // Replace with a deterministic "anonymized" marker
        var result = rawData
        // Append a marker to indicate anonymization happened
        result.append(contentsOf: [0xAA, 0xBB, 0xCC])
        return result
    }

    func getCallCount() -> Int { callCount }
}

/// Mock store that records what was stored
actor MockAnonymizedStore: AnonymizedDataStore {
    var storedItems: [(data: Data, metadata: AssetMetadata)] = []

    func store(data: Data, metadata: AssetMetadata) async throws -> String {
        storedItems.append((data: data, metadata: metadata))
        return "stored_\(storedItems.count)"
    }

    func getStoredItems() -> [(data: Data, metadata: AssetMetadata)] { storedItems }
}

/// Mock deleter that tracks deletions
actor MockDeleter: SecureDataDeleter {
    var deletedPaths: [URL] = []

    func secureDelete(at path: URL) async throws -> Bool {
        deletedPaths.append(path)
        // Actually delete if file exists
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        return true
    }

    func getDeletedPaths() -> [URL] { deletedPaths }
}

// MARK: - Tests

final class AnonymizationPipelineTests: XCTestCase {

    var tempDirectory: URL!
    var encryptionKey: SymmetricKey!
    var consentStorage: ConsentStorage!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        encryptionKey = SymmetricKey(size: .bits256)
        consentStorage = try ConsentStorage(
            dbPath: tempDirectory.appendingPathComponent("consent.db").path,
            encryptionKey: encryptionKey
        )
    }

    override func tearDown() async throws {
        try? await consentStorage.close()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Full Pipeline

    func testProcess_FullPipeline_Success() async throws {
        // Grant consent first
        try await consentStorage.recordConsent(operation: "capture", state: .granted)

        // Create a raw data file
        let rawFile = tempDirectory.appendingPathComponent("raw_frame.bin")
        let rawData = Data(repeating: 0xFF, count: 1024)
        try rawData.write(to: rawFile)

        let detector = MockDetector()
        let anonymizer = MockAnonymizer()
        let store = MockAnonymizedStore()
        let deleter = MockDeleter()

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: detector,
            anonymizer: anonymizer,
            store: store,
            deleter: deleter,
            consentOperation: "capture"
        )

        let result = try await pipeline.process(
            fileId: "frame_001",
            rawData: rawData,
            originalPath: rawFile
        )

        // Verify all steps ran
        XCTAssertEqual(result.fileId, "frame_001")
        XCTAssertEqual(result.regionsDetected, 1)  // face detected
        XCTAssertEqual(result.regionsAnonymized, 1)
        XCTAssertTrue(result.originalDeleted)
        XCTAssertEqual(result.storageId, "stored_1")
        XCTAssertFalse(result.consentId.isEmpty)

        // Verify detector was called
        let detectCalls = await detector.getCallCount()
        XCTAssertEqual(detectCalls, 1)

        // Verify anonymizer was called
        let anonCalls = await anonymizer.getCallCount()
        XCTAssertEqual(anonCalls, 1)

        // Verify anonymized data was stored
        let stored = await store.getStoredItems()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.metadata.originalFileId, "frame_001")
        XCTAssertEqual(stored.first?.metadata.regionsAnonymized, 1)
        XCTAssertEqual(stored.first?.metadata.regionTypes, ["face"])

        // Verify original was deleted
        let deleted = await deleter.getDeletedPaths()
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first, rawFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawFile.path))
    }

    // MARK: - Consent Check

    func testProcess_NoConsent_ThrowsError() async throws {
        // Do NOT grant consent

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: MockDetector(),
            anonymizer: MockAnonymizer(),
            store: MockAnonymizedStore(),
            deleter: MockDeleter(),
            consentOperation: "capture"
        )

        do {
            _ = try await pipeline.process(
                fileId: "frame_001",
                rawData: Data([0x01]),
                originalPath: tempDirectory.appendingPathComponent("nonexistent.bin")
            )
            XCTFail("Should throw consentNotGranted")
        } catch AnonymizationPipelineError.consentNotGranted(let op) {
            XCTAssertEqual(op, "capture")
        }
    }

    func testProcess_WithdrawnConsent_ThrowsError() async throws {
        // Grant then withdraw
        try await consentStorage.recordConsent(operation: "capture", state: .granted)
        try await consentStorage.withdrawConsent(operation: "capture")

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: MockDetector(),
            anonymizer: MockAnonymizer(),
            store: MockAnonymizedStore(),
            deleter: MockDeleter(),
            consentOperation: "capture"
        )

        do {
            _ = try await pipeline.process(
                fileId: "frame_001",
                rawData: Data([0x01]),
                originalPath: tempDirectory.appendingPathComponent("nonexistent.bin")
            )
            XCTFail("Should throw consentNotGranted")
        } catch AnonymizationPipelineError.consentNotGranted {
            // Expected
        }
    }

    // MARK: - No Sensitive Content

    func testProcess_NoSensitiveRegions_StillStoresAndDeletes() async throws {
        try await consentStorage.recordConsent(operation: "capture", state: .granted)

        let rawFile = tempDirectory.appendingPathComponent("clean_frame.bin")
        let rawData = Data(repeating: 0x00, count: 512)
        try rawData.write(to: rawFile)

        let detector = MockDetector()
        await detector.setRegions([]) // no regions detected

        let store = MockAnonymizedStore()
        let deleter = MockDeleter()

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: detector,
            anonymizer: MockAnonymizer(),
            store: store,
            deleter: deleter,
            consentOperation: "capture"
        )

        let result = try await pipeline.process(
            fileId: "clean_001",
            rawData: rawData,
            originalPath: rawFile
        )

        // No regions detected, but data is still stored and original deleted
        XCTAssertEqual(result.regionsDetected, 0)
        XCTAssertFalse(result.hadSensitiveContent)

        let stored = await store.getStoredItems()
        XCTAssertEqual(stored.count, 1)

        let deleted = await deleter.getDeletedPaths()
        XCTAssertEqual(deleted.count, 1)
    }

    // MARK: - Batch Processing

    func testProcessBatch_MultipleItems() async throws {
        try await consentStorage.recordConsent(operation: "capture", state: .granted)

        let store = MockAnonymizedStore()

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: MockDetector(),
            anonymizer: MockAnonymizer(),
            store: store,
            deleter: MockDeleter(),
            consentOperation: "capture"
        )

        var items: [(fileId: String, rawData: Data, originalPath: URL)] = []
        for i in 0..<3 {
            let path = tempDirectory.appendingPathComponent("frame_\(i).bin")
            try Data(repeating: UInt8(i), count: 256).write(to: path)
            items.append((fileId: "frame_\(i)", rawData: Data(repeating: UInt8(i), count: 256), originalPath: path))
        }

        let results = try await pipeline.processBatch(items: items)

        XCTAssertEqual(results.count, 3)
        for case .success(let r) in results {
            XCTAssertTrue(r.originalDeleted)
            XCTAssertEqual(r.regionsDetected, 1) // mock detector returns 1 face
        }

        let stored = await store.getStoredItems()
        XCTAssertEqual(stored.count, 3)
    }

    func testProcessBatch_NoConsent_FailsAll() async throws {
        // No consent granted

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: MockDetector(),
            anonymizer: MockAnonymizer(),
            store: MockAnonymizedStore(),
            deleter: MockDeleter(),
            consentOperation: "capture"
        )

        do {
            _ = try await pipeline.processBatch(items: [
                (fileId: "f1", rawData: Data([0x01]), originalPath: tempDirectory.appendingPathComponent("f1.bin"))
            ])
            XCTFail("Should throw")
        } catch AnonymizationPipelineError.consentNotGranted {
            // Expected — batch consent check fails before processing any items
        }
    }

    // MARK: - History

    func testHistory_TracksProcessedItems() async throws {
        try await consentStorage.recordConsent(operation: "capture", state: .granted)

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: MockDetector(),
            anonymizer: MockAnonymizer(),
            store: MockAnonymizedStore(),
            deleter: MockDeleter(),
            consentOperation: "capture"
        )

        let path = tempDirectory.appendingPathComponent("hist.bin")
        try Data([0x01]).write(to: path)

        _ = try await pipeline.process(
            fileId: "hist_001",
            rawData: Data([0x01]),
            originalPath: path
        )

        let history = await pipeline.getHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.fileId, "hist_001")

        let count = await pipeline.processedCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Metadata Audit Trail

    func testStoredMetadata_ContainsConsentId() async throws {
        try await consentStorage.recordConsent(operation: "capture", state: .granted)

        let store = MockAnonymizedStore()

        let pipeline = AnonymizationPipeline(
            consentStorage: consentStorage,
            detector: MockDetector(),
            anonymizer: MockAnonymizer(),
            store: store,
            deleter: MockDeleter(),
            consentOperation: "capture"
        )

        let path = tempDirectory.appendingPathComponent("audit.bin")
        try Data([0x01]).write(to: path)

        let result = try await pipeline.process(
            fileId: "audit_001",
            rawData: Data([0x01]),
            originalPath: path
        )

        // Verify consent ID is recorded in both result and stored metadata
        XCTAssertFalse(result.consentId.isEmpty)
        XCTAssertNotEqual(result.consentId, "unknown")

        let stored = await store.getStoredItems()
        XCTAssertEqual(stored.first?.metadata.consentId, result.consentId)
    }
}
