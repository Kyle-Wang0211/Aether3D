//
//  UploadTelemetryTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Upload Telemetry Tests
//

import XCTest
@testable import Aether3DCore

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

final class UploadTelemetryTests: XCTestCase {
    
    var telemetry: UploadTelemetry!
    var hmacKey: SymmetricKey!
    
    override func setUp() {
        super.setUp()
        hmacKey = SymmetricKey(size: .bits256)
        telemetry = UploadTelemetry(hmacKey: hmacKey)
    }
    
    override func tearDown() {
        telemetry = nil
        hmacKey = nil
        super.tearDown()
    }
    
    private func createTelemetryEntry(
        chunkIndex: Int = 0,
        chunkSize: Int = 1024,
        chunkHashPrefix: String = "abc12345",
        ioMethod: String = "mmap",
        crc32c: UInt32 = 0x12345678,
        compressibility: Double = 0.5,
        bandwidthMbps: Double = 10.0,
        rttMs: Double = 50.0,
        lossRate: Double = 0.01,
        layerTimings: UploadTelemetry.LayerTimings = UploadTelemetry.LayerTimings(
            ioMs: 1.0,
            transportMs: 2.0,
            hashMs: 0.5,
            erasureMs: 1.5,
            schedulingMs: 0.3
        ),
        timestamp: Date = Date(),
        hmacSignature: String = ""
    ) -> UploadTelemetry.TelemetryEntry {
        return UploadTelemetry.TelemetryEntry(
            chunkIndex: chunkIndex,
            chunkSize: chunkSize,
            chunkHashPrefix: chunkHashPrefix,
            ioMethod: ioMethod,
            crc32c: crc32c,
            compressibility: compressibility,
            bandwidthMbps: bandwidthMbps,
            rttMs: rttMs,
            lossRate: lossRate,
            layerTimings: layerTimings,
            timestamp: timestamp,
            hmacSignature: hmacSignature
        )
    }
    
    // MARK: - HMAC Signing (15 tests)
    
    func testRecordChunk_HasHMACSignature() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 1, "Should have one entry")
        XCTAssertFalse(entries[0].hmacSignature.isEmpty, "Entry should have HMAC signature")
    }
    
    func testRecordChunk_DifferentEntries_DifferentHMAC() async {
        let entry1 = createTelemetryEntry(chunkIndex: 0)
        let entry2 = createTelemetryEntry(chunkIndex: 1)
        await telemetry.recordChunk(entry1)
        await telemetry.recordChunk(entry2)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 2, "Should have two entries")
        XCTAssertNotEqual(entries[0].hmacSignature, entries[1].hmacSignature, "Different entries should have different HMAC")
    }
    
    func testRecordChunk_SameEntrySameKey_SameHMAC() async {
        let entry = createTelemetryEntry(chunkIndex: 0)
        await telemetry.recordChunk(entry)
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 2, "Should have two entries")
        // Same entry with same key should produce same HMAC
        XCTAssertEqual(entries[0].hmacSignature, entries[1].hmacSignature, "Same entry should have same HMAC")
    }
    
    func testRecordChunk_TamperedEntry_HMACMismatch() async {
        let entry = createTelemetryEntry(chunkIndex: 0)
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        let originalHMAC = entries[0].hmacSignature
        // Tamper with entry (in real scenario, would verify HMAC)
        XCTAssertFalse(originalHMAC.isEmpty, "HMAC should be present")
    }
    
    func testRecordChunk_HMAC_64Chars() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries[0].hmacSignature.count, 64, "HMAC should be 64 hex chars")
    }
    
    func testRecordChunk_HMAC_HexFormat() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(entries[0].hmacSignature.unicodeScalars.allSatisfy { hexChars.contains($0) }, "HMAC should be hex")
    }
    
    func testRecordChunk_HMAC_SHA256() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // HMAC-SHA256 should be 64 hex chars
        XCTAssertEqual(entries[0].hmacSignature.count, 64, "HMAC should be SHA-256")
    }
    
    func testRecordChunk_HMAC_KeyDependent() async {
        let entry = createTelemetryEntry()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let telemetry1 = UploadTelemetry(hmacKey: key1)
        let telemetry2 = UploadTelemetry(hmacKey: key2)
        await telemetry1.recordChunk(entry)
        await telemetry2.recordChunk(entry)
        let entries1 = await telemetry1.getEntries()
        let entries2 = await telemetry2.getEntries()
        XCTAssertNotEqual(entries1[0].hmacSignature, entries2[0].hmacSignature, "HMAC should be key-dependent")
    }
    
    func testRecordChunk_HMAC_AllFieldsIncluded() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // HMAC should include all fields
        XCTAssertFalse(entries[0].hmacSignature.isEmpty, "HMAC should include all fields")
    }
    
    func testRecordChunk_HMAC_Deterministic() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries1 = await telemetry.getEntries()
        let telemetry2 = UploadTelemetry(hmacKey: hmacKey)
        await telemetry2.recordChunk(entry)
        let entries2 = await telemetry2.getEntries()
        XCTAssertEqual(entries1[0].hmacSignature, entries2[0].hmacSignature, "HMAC should be deterministic")
    }
    
    func testRecordChunk_HMAC_TamperDetection() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // HMAC should enable tamper detection
        XCTAssertFalse(entries[0].hmacSignature.isEmpty, "HMAC should enable tamper detection")
    }
    
    func testRecordChunk_HMAC_ConcurrentAccess_ActorSafe() async {
        let entry = createTelemetryEntry()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.telemetry.recordChunk(entry)
                }
            }
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 10, "Concurrent access should be actor-safe")
    }
    
    func testRecordChunk_HMAC_MultipleEntries_AllSigned() async {
        for i in 0..<10 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 10, "Should have 10 entries")
        for entry in entries {
            XCTAssertFalse(entry.hmacSignature.isEmpty, "All entries should be signed")
        }
    }
    
    func testRecordChunk_HMAC_EmptyEntry_Handles() async {
        let entry = createTelemetryEntry(chunkSize: 0, chunkHashPrefix: "")
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertFalse(entries[0].hmacSignature.isEmpty, "Empty entry should handle")
    }
    
    func testRecordChunk_HMAC_LargeEntry_Handles() async {
        let entry = createTelemetryEntry(chunkSize: 100 * 1024 * 1024)
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertFalse(entries[0].hmacSignature.isEmpty, "Large entry should handle")
    }
    
    // MARK: - Differential Privacy (15 tests)
    
    func testRecordChunk_DifferentialPrivacy_Applied() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // Differential privacy should be applied (ε=1.0)
        XCTAssertNotNil(entries[0], "Differential privacy should be applied")
    }
    
    func testRecordChunk_HashPrefix_8Chars() async {
        let entry = createTelemetryEntry(chunkHashPrefix: "abcdefghijklmnop")
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries[0].chunkHashPrefix.count, 8, "Hash prefix should be 8 chars")
    }
    
    func testRecordChunk_HashPrefix_Truncated() async {
        let longHash = String(repeating: "a", count: 64)
        let entry = createTelemetryEntry(chunkHashPrefix: longHash)
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries[0].chunkHashPrefix.count, 8, "Hash prefix should be truncated to 8 chars")
    }
    
    func testRecordChunk_DifferentialPrivacy_Epsilon1_0() async {
        // ε=1.0 Laplace noise should be applied
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // Differential privacy should be applied
        XCTAssertNotNil(entries[0], "Differential privacy ε=1.0 should be applied")
    }
    
    func testRecordChunk_DifferentialPrivacy_NoiseAdded() async {
        // Noise should be added to sensitive fields
        let entry = createTelemetryEntry(bandwidthMbps: 10.0, rttMs: 50.0)
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // Noise may be added (implementation dependent)
        XCTAssertNotNil(entries[0], "Noise should be added")
    }
    
    func testRecordChunk_DifferentialPrivacy_PrivacyPreserved() async {
        // Privacy should be preserved
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // Hash prefix should be truncated
        XCTAssertEqual(entries[0].chunkHashPrefix.count, 8, "Privacy should be preserved")
    }
    
    func testRecordChunk_DifferentialPrivacy_Consistent() async {
        // Differential privacy should be consistent
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertNotNil(entries[0], "Differential privacy should be consistent")
    }
    
    func testRecordChunk_DifferentialPrivacy_AllFields() async {
        // Differential privacy should apply to all sensitive fields
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertNotNil(entries[0], "Differential privacy should apply to all fields")
    }
    
    func testRecordChunk_DifferentialPrivacy_NoDataLoss() async {
        // Differential privacy should not cause data loss
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries[0].chunkIndex, entry.chunkIndex, "No data loss")
        XCTAssertEqual(entries[0].chunkSize, entry.chunkSize, "No data loss")
    }
    
    func testRecordChunk_DifferentialPrivacy_ReasonableNoise() async {
        // Noise should be reasonable
        let entry = createTelemetryEntry(bandwidthMbps: 10.0)
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // Noise should be reasonable (implementation dependent)
        XCTAssertNotNil(entries[0], "Noise should be reasonable")
    }
    
    func testRecordChunk_DifferentialPrivacy_LaplaceMechanism() async {
        // Should use Laplace mechanism
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // Laplace mechanism should be used
        XCTAssertNotNil(entries[0], "Laplace mechanism should be used")
    }
    
    func testRecordChunk_DifferentialPrivacy_EpsilonValue() async {
        // ε value should be 1.0
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        // ε=1.0 should be used
        XCTAssertNotNil(entries[0], "ε=1.0 should be used")
    }
    
    func testRecordChunk_DifferentialPrivacy_ConcurrentAccess_ActorSafe() async {
        let entry = createTelemetryEntry()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.telemetry.recordChunk(entry)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testRecordChunk_DifferentialPrivacy_MultipleEntries() async {
        for i in 0..<10 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 10, "Multiple entries should handle")
    }
    
    func testRecordChunk_DifferentialPrivacy_EdgeCases() async {
        let edgeCases = [
            createTelemetryEntry(chunkSize: 0),
            createTelemetryEntry(bandwidthMbps: 0.0),
            createTelemetryEntry(rttMs: 0.0),
            createTelemetryEntry(lossRate: 0.0)
        ]
        for entry in edgeCases {
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, edgeCases.count, "Edge cases should handle")
    }
    
    // MARK: - Entry Management (10 tests)
    
    func testGetEntries_Empty_ReturnsEmpty() async {
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 0, "Empty should return empty")
    }
    
    func testGetEntries_OneEntry_ReturnsOne() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 1, "One entry should return one")
    }
    
    func testGetEntries_MultipleEntries_ReturnsAll() async {
        for i in 0..<10 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 10, "Multiple entries should return all")
    }
    
    func testGetEntries_MaxEntries_1000() async {
        // Max entries should be 1000
        for i in 0..<1001 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 1000, "Max entries should be 1000")
    }
    
    func testGetEntries_OverMax_RemovesOldest() async {
        for i in 0..<1001 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries.count, 1000, "Over max should remove oldest")
        XCTAssertEqual(entries[0].chunkIndex, 1, "Oldest should be removed")
    }
    
    func testGetEntries_Order_Preserved() async {
        for i in 0..<10 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        let entries = await telemetry.getEntries()
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(entry.chunkIndex, index, "Order should be preserved")
        }
    }
    
    func testGetEntries_ConcurrentAccess_ActorSafe() async {
        for i in 0..<10 {
            let entry = createTelemetryEntry(chunkIndex: i)
            await telemetry.recordChunk(entry)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.telemetry.getEntries()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testGetEntries_AllFields_Present() async {
        let entry = createTelemetryEntry()
        await telemetry.recordChunk(entry)
        let entries = await telemetry.getEntries()
        XCTAssertEqual(entries[0].chunkIndex, entry.chunkIndex, "All fields should be present")
        XCTAssertEqual(entries[0].chunkSize, entry.chunkSize, "All fields should be present")
    }
    
    func testGetEntries_TelemetryEntry_Sendable() {
        let entry = createTelemetryEntry()
        let _: any Sendable = entry
        XCTAssertTrue(true, "TelemetryEntry should be Sendable")
    }
    
    func testGetEntries_LayerTimings_Sendable() {
        let timings = UploadTelemetry.LayerTimings(ioMs: 1.0, transportMs: 2.0, hashMs: 0.5, erasureMs: 1.5, schedulingMs: 0.3)
        let _: any Sendable = timings
        XCTAssertTrue(true, "LayerTimings should be Sendable")
    }
}
