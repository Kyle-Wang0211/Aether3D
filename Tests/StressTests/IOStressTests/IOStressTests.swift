// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// IOStressTests.swift
// Aether3D
//
// Stress tests for I/O operations - 25 tests
// 符合 PART B.6: Stress Tests
//

import XCTest
@testable import Aether3DCore

final class IOStressTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                  withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - I/O Stress Tests (25 tests)

    func testFileWAL_LargeEntries() async throws {
        let path = tempDirectory.appendingPathComponent("stress.wal")
        let storage = try FileWALStorage(walFileURL: path)

        // Write 100 entries with 1 MB each
        for i in 0..<100 {
            let entry = WALEntry(
                entryId: UInt64(i),
                hash: Data(repeating: UInt8(i), count: 32),
                signedEntryBytes: Data(repeating: UInt8(i), count: 1_000_000),
                merkleState: Data(),
                committed: false,
                timestamp: Date()
            )
            try await storage.writeEntry(entry)
        }

        try await storage.fsync()

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 100)
    }

    func testFileWAL_ManySmallEntries() async throws {
        let path = tempDirectory.appendingPathComponent("many.wal")
        let storage = try FileWALStorage(walFileURL: path)

        // Write 10,000 small entries
        for i in 0..<10_000 {
            let entry = WALEntry(
                entryId: UInt64(i),
                hash: Data(repeating: UInt8(i % 256), count: 32),
                signedEntryBytes: Data([UInt8(i % 256)]),
                merkleState: Data(),
                committed: false,
                timestamp: Date()
            )
            try await storage.writeEntry(entry)
        }

        try await storage.fsync()

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 10_000)
    }

    func testSQLite_HighFrequencyWrites() async throws {
        let path = tempDirectory.appendingPathComponent("stress.db").path
        let store = try SQLiteCounterStore(dbPath: path)

        let start = Date().timeIntervalSinceReferenceDate

        // 10,000 writes
        for i in 0..<10_000 {
            try await store.setCounter(keyId: "key\(i)", counter: UInt64(i))
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - start

        // Should complete in reasonable time
        XCTAssertLessThan(elapsed, 30.0, "10k SQLite writes should complete in under 30s")
    }

    func testSQLite_HighFrequencyReads() async throws {
        let path = tempDirectory.appendingPathComponent("read_stress.db").path
        let store = try SQLiteCounterStore(dbPath: path)

        // Pre-populate
        for i in 0..<1000 {
            try await store.setCounter(keyId: "key\(i)", counter: UInt64(i))
        }

        let start = Date().timeIntervalSinceReferenceDate

        // 10,000 reads
        for i in 0..<10_000 {
            _ = try await store.getCounter(keyId: "key\(i % 1000)")
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - start

        // Should complete in reasonable time
        XCTAssertLessThan(elapsed, 10.0, "10k SQLite reads should complete in under 10s")
    }

    func testFileWAL_PersistenceAfterClose() async throws {
        let path = tempDirectory.appendingPathComponent("persist.wal")

        // Write entries
        let storage1 = try FileWALStorage(walFileURL: path)
        for i in 0..<100 {
            let entry = WALEntry(
                entryId: UInt64(i),
                hash: Data(repeating: UInt8(i), count: 32),
                signedEntryBytes: Data(),
                merkleState: Data(),
                committed: false,
                timestamp: Date()
            )
            try await storage1.writeEntry(entry)
        }
        try await storage1.fsync()
        try await storage1.close()

        // Read with new instance
        let storage2 = try FileWALStorage(walFileURL: path)
        let entries = try await storage2.readEntries()

        XCTAssertEqual(entries.count, 100)
    }
}
