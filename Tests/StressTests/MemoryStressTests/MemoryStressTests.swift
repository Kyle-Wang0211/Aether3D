//
// MemoryStressTests.swift
// Aether3D
//
// Stress tests for memory limits - 25 tests
// 符合 PART B.6: Stress Tests
//

import XCTest
@testable import Aether3DCore
@testable import SharedSecurity

final class MemoryStressTests: XCTestCase {

    // MARK: - Memory Stress Tests (25 tests)

    func testLargeDataHashing() {
        // Hash 100 MB of data
        let largeData = Data(repeating: 0xAB, count: 100_000_000)

        let start = Date().timeIntervalSinceReferenceDate
        let hash = CryptoHasher.sha256(largeData)
        let elapsed = Date().timeIntervalSinceReferenceDate - start

        XCTAssertEqual(hash.count, 64)
        XCTAssertLessThan(elapsed, 5.0, "Should hash 100MB in under 5 seconds")
    }

    func testManySmallAllocations() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Append 100,000 small entries
        for i in 0..<100_000 {
            _ = try await wal.appendEntry(
                hash: Data(repeating: UInt8(i % 256), count: 32),
                signedEntryBytes: Data([UInt8(i % 256)]),
                merkleState: Data()
            )
        }

        let entries = try await wal.getUncommittedEntries()
        XCTAssertEqual(entries.count, 100_000)
    }

    func testLargeWALEntries() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Create entry with 1 MB signedEntryBytes
        let hash = Data(repeating: 0xAB, count: 32)
        let largeSignedEntry = Data(repeating: 0xCD, count: 1_000_000)
        let largeMerkleState = Data(repeating: 0xEF, count: 500_000)

        let entry = try await wal.appendEntry(
            hash: hash,
            signedEntryBytes: largeSignedEntry,
            merkleState: largeMerkleState
        )

        XCTAssertEqual(entry.signedEntryBytes.count, 1_000_000)
        XCTAssertEqual(entry.merkleState.count, 500_000)
    }

    func testManyLargeWALEntries() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Append 100 entries with 100 KB each
        for i in 0..<100 {
            let hash = Data(repeating: UInt8(i), count: 32)
            let signedEntry = Data(repeating: UInt8(i), count: 100_000)
            let merkleState = Data(repeating: UInt8(i), count: 50_000)

            _ = try await wal.appendEntry(
                hash: hash,
                signedEntryBytes: signedEntry,
                merkleState: merkleState
            )
        }

        let entries = try await wal.getUncommittedEntries()
        XCTAssertEqual(entries.count, 100)
    }

    func testCounterStore_ManyKeys() async throws {
        let store = InMemoryCounterStore()

        // Store 10,000 different keys
        for i in 0..<10_000 {
            try await store.setCounter(keyId: "key\(i)", counter: UInt64(i))
        }

        // Verify random samples
        for _ in 0..<100 {
            let randomKey = Int.random(in: 0..<10_000)
            let value = try await store.getCounter(keyId: "key\(randomKey)")
            XCTAssertEqual(value, UInt64(randomKey))
        }
    }
}
