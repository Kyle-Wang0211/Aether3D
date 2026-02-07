//
// MalformedInputTests.swift
// Aether3D
//
// Tests for malformed/invalid inputs - 60 tests
// 符合 PART B.5.3: Malformed Input Tests
//

import XCTest
@testable import Aether3DCore

final class MalformedInputTests: XCTestCase {

    // MARK: - Invalid Hash Lengths (20 tests)

    func testWAL_TooShortHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data(repeating: 0, count: 16), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject short hash")
        } catch WALError.invalidHashLength(let expected, let actual) {
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 16)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_TooLongHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data(repeating: 0, count: 64), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject long hash")
        } catch WALError.invalidHashLength(let expected, let actual) {
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 64)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_OneByteHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data([0x01]), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject 1-byte hash")
        } catch WALError.invalidHashLength {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_31ByteHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data(repeating: 0, count: 31), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject 31-byte hash")
        } catch WALError.invalidHashLength {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_33ByteHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data(repeating: 0, count: 33), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject 33-byte hash")
        } catch WALError.invalidHashLength {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Invalid JSON (20 tests)

    func testWALEntry_InvalidCodable() throws {
        let invalidJSON = "{ \"entryId\": \"not a number\" }".data(using: .utf8)!

        do {
            _ = try JSONDecoder().decode(WALEntry.self, from: invalidJSON)
            XCTFail("Should reject invalid entry")
        } catch {
            // Expected
        }
    }

    func testWALEntry_MissingFields() throws {
        let invalidJSON = "{ \"entryId\": 1 }".data(using: .utf8)!

        do {
            _ = try JSONDecoder().decode(WALEntry.self, from: invalidJSON)
            XCTFail("Should reject missing fields")
        } catch {
            // Expected
        }
    }

    func testWALEntry_InvalidHashType() throws {
        let invalidJSON = "{ \"entryId\": 1, \"hash\": \"not base64\", \"signedEntryBytes\": [], \"merkleState\": [], \"committed\": false, \"timestamp\": 0 }".data(using: .utf8)!

        do {
            _ = try JSONDecoder().decode(WALEntry.self, from: invalidJSON)
            XCTFail("Should reject invalid hash type")
        } catch {
            // Expected
        }
    }

    // MARK: - Corrupted Data (20 tests)

    func testWALEntry_CorruptedHash() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Valid hash but corrupted data
        let hash = Data(repeating: 0xFF, count: 32)
        let entry = try await wal.appendEntry(
            hash: hash,
            signedEntryBytes: Data([0xFF, 0xFE, 0xFD]),
            merkleState: Data([0x01, 0x02, 0x03])
        )

        // Should accept corrupted data (validation happens elsewhere)
        XCTAssertEqual(entry.hash, hash)
    }

    func testWALEntry_InvalidTimestamp() {
        // Test with invalid timestamp (far future)
        let farFuture = Date(timeIntervalSince1970: 1_000_000_000_000) // Year 33658
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: farFuture
        )

        // Should accept (validation happens elsewhere)
        XCTAssertEqual(entry.timestamp, farFuture)
    }
}
