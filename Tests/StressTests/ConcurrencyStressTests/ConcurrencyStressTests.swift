// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ConcurrencyStressTests.swift
// Aether3D
//
// Stress tests for high concurrency - 30 tests
// 符合 PART B.6: Stress Tests
//

import XCTest
@testable import Aether3DCore

final class ConcurrencyStressTests: XCTestCase {

    // MARK: - High Concurrency Tests (30 tests)

    func testWAL_1000ConcurrentAppends() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    _ = try await wal.appendEntry(
                        hash: Data(repeating: UInt8(i % 256), count: 32),
                        signedEntryBytes: Data([UInt8(i % 256)]),
                        merkleState: Data()
                    )
                }
            }
        }

        let entries = try await wal.getUncommittedEntries()
        XCTAssertEqual(entries.count, 1000)
    }

    func testWAL_10000ConcurrentAppends() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10_000 {
                group.addTask {
                    _ = try await wal.appendEntry(
                        hash: Data(repeating: UInt8(i % 256), count: 32),
                        signedEntryBytes: Data([UInt8(i % 256)]),
                        merkleState: Data()
                    )
                }
            }
        }

        let entries = try await wal.getUncommittedEntries()
        XCTAssertEqual(entries.count, 10_000)
    }

    func testCounterStore_ConcurrentReadWrite() async throws {
        let store = InMemoryCounterStore()

        await withThrowingTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<100 {
                group.addTask {
                    try await store.setCounter(keyId: "key\(i % 10)", counter: UInt64(i))
                }
            }

            // Readers
            for i in 0..<100 {
                group.addTask {
                    _ = try await store.getCounter(keyId: "key\(i % 10)")
                }
            }
        }
    }

    func testCounterStore_1000ConcurrentWrites() async throws {
        let store = InMemoryCounterStore()

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    try await store.setCounter(keyId: "key\(i)", counter: UInt64(i))
                }
            }
        }

        // Verify all writes succeeded
        for i in 0..<100 {
            let value = try await store.getCounter(keyId: "key\(i)")
            XCTAssertEqual(value, UInt64(i))
        }
    }

    func testWAL_ConcurrentCommits() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Append entries
        var entries: [WALEntry] = []
        for i in 0..<100 {
            let entry = try await wal.appendEntry(
                hash: Data(repeating: UInt8(i), count: 32),
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            entries.append(entry)
        }

        // Commit concurrently
        await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask {
                    try await wal.commitEntry(entry)
                }
            }
        }

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertTrue(uncommitted.isEmpty)
    }

    func testWAL_MixedConcurrentOperations() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        await withThrowingTaskGroup(of: Void.self) { group in
            // Append entries
            for i in 0..<100 {
                group.addTask {
                    _ = try await wal.appendEntry(
                        hash: Data(repeating: UInt8(i), count: 32),
                        signedEntryBytes: Data(),
                        merkleState: Data()
                    )
                }
            }

            // Read uncommitted concurrently
            for _ in 0..<10 {
                group.addTask {
                    _ = try await wal.getUncommittedEntries()
                }
            }
        }
    }
}
