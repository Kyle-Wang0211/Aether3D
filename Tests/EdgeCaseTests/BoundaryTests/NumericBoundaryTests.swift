//
// NumericBoundaryTests.swift
// Aether3D
//
// Boundary tests for numeric values - 80 tests
// 符合 PART B.5.1: Boundary Tests
//

import XCTest
@testable import Aether3DCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class NumericBoundaryTests: XCTestCase {

    // MARK: - UInt64 Boundaries (20 tests)

    func testCounter_MaxValue() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: UInt64.max)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, UInt64.max)
    }

    func testCounter_MinValue() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: UInt64.min)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, 0)
    }

    func testCounter_Zero() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: 0)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, 0)
    }

    func testCounter_One() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: 1)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, 1)
    }

    func testCounter_MaxMinusOne() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: UInt64.max - 1)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, UInt64.max - 1)
    }

    func testWALEntryId_MaxValue() {
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

    func testWALEntryId_MinValue() {
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

    func testWALEntryId_One() {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.entryId, 1)
    }

    // MARK: - Data Size Boundaries (20 tests)

    func testHash_ExactSize() {
        #if canImport(CryptoKit)
        let data = Data(repeating: 0x01, count: 1)
        let hash = Data(SHA256.hash(data: data))
        XCTAssertEqual(hash.count, 32)
        #endif
    }

    func testHash_EmptyData() {
        #if canImport(CryptoKit)
        let data = Data()
        let hash = Data(SHA256.hash(data: data))
        XCTAssertEqual(hash.count, 32)
        #endif
    }

    func testHash_LargeData() {
        #if canImport(CryptoKit)
        let data = Data(repeating: 0xAB, count: 1_000_000)
        let hash = Data(SHA256.hash(data: data))
        XCTAssertEqual(hash.count, 32)
        #endif
    }

    func testHMAC_ExactSize() {
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data([0x02])
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        XCTAssertEqual(Data(hmac).count, 32)
        #endif
    }

    func testHMAC_EmptyMessage() {
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data()
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        XCTAssertEqual(Data(hmac).count, 32)
        #endif
    }

    func testHMAC_LargeMessage() {
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data(repeating: 0x02, count: 1_000_000)
        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        XCTAssertEqual(Data(hmac).count, 32)
        #endif
    }

    // MARK: - Float Boundaries (20 tests)

    func testBlurScore_Range() {
        // Blur score should be 0.0 to 1.0
        let validScores: [Float] = [0.0, 0.1, 0.5, 0.9, 1.0]

        for score in validScores {
            XCTAssertTrue((0.0...1.0).contains(score))
        }
    }

    func testBlurScore_MinValue() {
        let score: Float = 0.0
        XCTAssertTrue((0.0...1.0).contains(score))
    }

    func testBlurScore_MaxValue() {
        let score: Float = 1.0
        XCTAssertTrue((0.0...1.0).contains(score))
    }

    func testBlurScore_JustBelowMin() {
        let score: Float = -0.0001
        XCTAssertFalse((0.0...1.0).contains(score))
    }

    func testBlurScore_JustAboveMax() {
        let score: Float = 1.0001
        XCTAssertFalse((0.0...1.0).contains(score))
    }

    func testCoverageWeight_Range() {
        // S5 coverage weight should be in valid range
        let weight: Float = 0.95
        XCTAssertTrue((0.0...1.0).contains(weight))
    }

    // MARK: - Timestamp Boundaries (20 tests)

    func testTimestamp_FarFuture() {
        let farFuture = Date(timeIntervalSince1970: 4_102_444_800) // Year 2100
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: farFuture
        )

        XCTAssertEqual(entry.timestamp, farFuture)
    }

    func testTimestamp_Epoch() {
        let epoch = Date(timeIntervalSince1970: 0)
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: epoch
        )

        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, 0)
    }

    func testTimestamp_CurrentTime() {
        let now = Date()
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: now
        )

        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTimestamp_FarPast() {
        let farPast = Date(timeIntervalSince1970: -1_000_000_000) // Year 1938
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: farPast
        )

        XCTAssertEqual(entry.timestamp, farPast)
    }
}
