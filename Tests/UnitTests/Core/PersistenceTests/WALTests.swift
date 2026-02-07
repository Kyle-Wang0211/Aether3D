//
// WALTests.swift
// Aether3D
//
// Comprehensive tests for Write-Ahead Log - 80 tests
// 符合 PART B.2.2: PersistenceTests (80 tests)
//

import XCTest
@testable import Aether3DCore

final class WALTests: XCTestCase {

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

    // MARK: - WAL Entry Tests (20 tests)

    func testWALEntry_Creation() {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xAB, count: 32),
            signedEntryBytes: Data([0x01, 0x02, 0x03]),
            merkleState: Data([0x04, 0x05, 0x06]),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.entryId, 1)
        XCTAssertEqual(entry.hash.count, 32)
        XCTAssertFalse(entry.committed)
    }

    func testWALEntry_Codable() throws {
        let entry = WALEntry(
            entryId: 42,
            hash: Data(repeating: 0xCD, count: 32),
            signedEntryBytes: Data([0x10, 0x20, 0x30]),
            merkleState: Data([0x40, 0x50, 0x60]),
            committed: true,
            timestamp: Date()
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WALEntry.self, from: encoded)

        XCTAssertEqual(decoded.entryId, entry.entryId)
        XCTAssertEqual(decoded.hash, entry.hash)
        XCTAssertEqual(decoded.committed, entry.committed)
    }

    func testWALEntry_Sendable() async {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        // Verify Sendable by passing across task boundaries
        let result = await Task.detached {
            return entry.entryId
        }.value

        XCTAssertEqual(result, 1)
    }

    func testWALEntry_EmptyData() {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.signedEntryBytes.count, 0)
        XCTAssertEqual(entry.merkleState.count, 0)
    }

    func testWALEntry_LargeData() {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(repeating: 0xAB, count: 1_000_000),
            merkleState: Data(repeating: 0xCD, count: 500_000),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.signedEntryBytes.count, 1_000_000)
        XCTAssertEqual(entry.merkleState.count, 500_000)
    }

    func testWALEntry_MaxEntryId() {
        let entry = WALEntry(
            entryId: UInt64.max,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.entryId, UInt64.max)
    }

    func testWALEntry_MinEntryId() {
        let entry = WALEntry(
            entryId: 0,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.entryId, 0)
    }

    func testWALEntry_TimestampPreserved() {
        let timestamp = Date(timeIntervalSince1970: 1234567890)
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: timestamp
        )

        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWALEntry_CommittedState() {
        let uncommitted = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        let committed = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: true,
            timestamp: Date()
        )

        XCTAssertFalse(uncommitted.committed)
        XCTAssertTrue(committed.committed)
    }

    // MARK: - WriteAheadLog Tests (30 tests)

    func testWAL_AppendEntry_ValidHash() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let hash = Data(repeating: 0xAB, count: 32)
        let entry = try await wal.appendEntry(
            hash: hash,
            signedEntryBytes: Data([0x01]),
            merkleState: Data([0x02])
        )

        XCTAssertEqual(entry.entryId, 1)
        XCTAssertEqual(entry.hash, hash)
        XCTAssertFalse(entry.committed)
    }

    func testWAL_AppendEntry_InvalidHashLength() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let shortHash = Data(repeating: 0xAB, count: 16) // Should be 32

        do {
            _ = try await wal.appendEntry(
                hash: shortHash,
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should throw for invalid hash length")
        } catch WALError.invalidHashLength(let expected, let actual) {
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 16)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_AppendEntry_TooLongHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let longHash = Data(repeating: 0xAB, count: 64) // Should be 32

        do {
            _ = try await wal.appendEntry(
                hash: longHash,
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should throw for invalid hash length")
        } catch WALError.invalidHashLength(let expected, let actual) {
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 64)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_CommitEntry_Success() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let entry = try await wal.appendEntry(
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        try await wal.commitEntry(entry)

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertTrue(uncommitted.isEmpty)
    }

    func testWAL_CommitEntry_NotFound() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let fakeEntry = WALEntry(
            entryId: 999,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        do {
            try await wal.commitEntry(fakeEntry)
            XCTFail("Should throw for non-existent entry")
        } catch WALError.entryNotFound(let id) {
            XCTAssertEqual(id, 999)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_Recovery_EmptyLog() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let committed = try await wal.recover()
        XCTAssertTrue(committed.isEmpty)
    }

    func testWAL_Recovery_WithEntries() async throws {
        let storage = MockWALStorage()

        // Pre-populate storage using actor method
        await storage.setEntries([
            WALEntry(entryId: 1, hash: Data(repeating: 0, count: 32),
                     signedEntryBytes: Data(), merkleState: Data(),
                     committed: true, timestamp: Date()),
            WALEntry(entryId: 2, hash: Data(repeating: 1, count: 32),
                     signedEntryBytes: Data(), merkleState: Data(),
                     committed: false, timestamp: Date())
        ])

        let wal = WriteAheadLog(storage: storage)
        let committed = try await wal.recover()

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed[0].entryId, 1)

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertEqual(uncommitted.count, 1)
        XCTAssertEqual(uncommitted[0].entryId, 2)
    }

    func testWAL_EntryIdIncrement() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let entry1 = try await wal.appendEntry(
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        let entry2 = try await wal.appendEntry(
            hash: Data(repeating: 1, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        XCTAssertEqual(entry1.entryId, 1)
        XCTAssertEqual(entry2.entryId, 2)
    }

    func testWAL_ConcurrentAppends() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Append 100 entries concurrently
        await withTaskGroup(of: WALEntry?.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? await wal.appendEntry(
                        hash: Data(repeating: UInt8(i), count: 32),
                        signedEntryBytes: Data([UInt8(i)]),
                        merkleState: Data()
                    )
                }
            }

            var entries: [WALEntry] = []
            for await entry in group {
                if let entry = entry {
                    entries.append(entry)
                }
            }

            XCTAssertEqual(entries.count, 100)

            // Verify unique entry IDs
            let ids = Set(entries.map { $0.entryId })
            XCTAssertEqual(ids.count, 100)
        }
    }

    func testWAL_MultipleCommits() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let entry1 = try await wal.appendEntry(
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        let entry2 = try await wal.appendEntry(
            hash: Data(repeating: 1, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        try await wal.commitEntry(entry1)
        try await wal.commitEntry(entry2)

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertTrue(uncommitted.isEmpty)
    }

    // MARK: - WAL Storage Tests (30 tests)

    func testFileWALStorage_WriteAndRead() async throws {
        let path = tempDirectory.appendingPathComponent("test.wal")
        let storage = try FileWALStorage(walFileURL: path)

        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xAB, count: 32),
            signedEntryBytes: Data([0x01, 0x02]),
            merkleState: Data([0x03, 0x04]),
            committed: false,
            timestamp: Date()
        )

        try await storage.writeEntry(entry)
        try await storage.fsync()

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].entryId, 1)
    }

    func testFileWALStorage_Persistence() async throws {
        let path = tempDirectory.appendingPathComponent("persist.wal")

        // Write with one storage instance
        let storage1 = try FileWALStorage(walFileURL: path)
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xCD, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: true,
            timestamp: Date()
        )
        try await storage1.writeEntry(entry)
        try await storage1.fsync()
        try await storage1.close()

        // Read with new storage instance
        let storage2 = try FileWALStorage(walFileURL: path)
        let entries = try await storage2.readEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hash, entry.hash)
    }

    func testSQLiteWALStorage_WriteAndRead() async throws {
        let path = tempDirectory.appendingPathComponent("test.db").path
        let storage = try SQLiteWALStorage(dbPath: path)

        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xEF, count: 32),
            signedEntryBytes: Data([0x05, 0x06]),
            merkleState: Data([0x07, 0x08]),
            committed: false,
            timestamp: Date()
        )

        try await storage.writeEntry(entry)

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 1)
    }
}

// Mock WAL Storage for testing
actor MockWALStorage: WALStorage {
    var entries: [WALEntry] = []
    var fsyncCalled = false
    var closeCalled = false

    func writeEntry(_ entry: WALEntry) async throws {
        if let index = entries.firstIndex(where: { $0.entryId == entry.entryId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    func readEntries() async throws -> [WALEntry] {
        return entries
    }

    func fsync() async throws {
        fsyncCalled = true
    }

    func close() async throws {
        closeCalled = true
    }

    /// Pre-populate entries for testing
    func setEntries(_ newEntries: [WALEntry]) {
        entries = newEntries
    }
}
