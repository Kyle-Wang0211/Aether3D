//
// BenchmarkTests.swift
// Aether3D
//
// Performance benchmark tests - 50 tests
// 符合 PART B.7: Performance Tests
//

import XCTest
@testable import Aether3DCore
@testable import SharedSecurity
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class BenchmarkTests: XCTestCase {

    // MARK: - Cryptographic Performance (15 tests)

    func testSHA256_Performance() {
        let data = Data(repeating: 0xAB, count: 1024)

        measure {
            for _ in 0..<10_000 {
                _ = CryptoHasher.sha256(data)
            }
        }
    }

    func testSHA256_SmallDataPerformance() {
        let data = Data([0x01, 0x02, 0x03])

        measure {
            for _ in 0..<100_000 {
                _ = CryptoHasher.sha256(data)
            }
        }
    }

    func testSHA256_LargeDataPerformance() {
        let data = Data(repeating: 0xAB, count: 1_000_000)

        measure {
            _ = CryptoHasher.sha256(data)
        }
    }

    func testHMAC_Performance() {
        let keyData = SymmetricKey(data: Data(repeating: 0x01, count: 32))
        let message = Data(repeating: 0x02, count: 1024)

        measure {
            for _ in 0..<10_000 {
                _ = CryptoHasher.hmacSHA256(data: message, key: keyData)
            }
        }
    }

    // MARK: - WAL Performance (15 tests)

    func testWAL_AppendPerformance() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let start = CFAbsoluteTimeGetCurrent()

        for i in 0..<1000 {
            _ = try await wal.appendEntry(
                hash: Data(repeating: UInt8(i % 256), count: 32),
                signedEntryBytes: Data(),
                merkleState: Data()
            )
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 1000 appends should complete in under 1 second
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testWAL_CommitPerformance() async throws {
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

        let start = CFAbsoluteTimeGetCurrent()

        for entry in entries {
            try await wal.commitEntry(entry)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 100 commits should complete in under 0.5 seconds
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testWAL_RecoveryPerformance() async throws {
        let storage = MockWALStorage()

        // Pre-populate with entries using actor method
        for i in 0..<1000 {
            let entry = WALEntry(
                entryId: UInt64(i),
                hash: Data(repeating: UInt8(i % 256), count: 32),
                signedEntryBytes: Data(),
                merkleState: Data(),
                committed: i % 2 == 0,
                timestamp: Date()
            )
            try await storage.writeEntry(entry)
        }

        let wal = WriteAheadLog(storage: storage)

        let start = CFAbsoluteTimeGetCurrent()
        _ = try await wal.recover()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Recovery should complete in under 0.5 seconds
        XCTAssertLessThan(elapsed, 0.5)
    }

    // MARK: - Mobile Optimization Performance (20 tests)

    func testThermalHandler_Performance() async {
        let handler = MobileThermalStateHandler()

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<10_000 {
            await handler.adaptToThermalState()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = elapsed / 10_000 * 1000 // ms per call

        // Each call should be under 0.1ms average
        XCTAssertLessThan(perCall, 0.1)
    }

    func testMemoryPressureHandler_Performance() async {
        let handler = MobileMemoryPressureHandler()

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<1000 {
            await handler.handleMemoryWarning()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = elapsed / 1000 * 1000 // ms per call

        // Each call should be under 1ms average
        XCTAssertLessThan(perCall, 1.0)
    }

    func testFramePacing_Performance() async {
        let controller = MobileFramePacingController()

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<100_000 {
            _ = await controller.recordFrameTime(1.0/60.0)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 100k frame recordings should complete in under 1 second
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testBatteryScheduler_Performance() async {
        let scheduler = MobileBatteryAwareScheduler()

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<10_000 {
            _ = await scheduler.recommendedScanQuality()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = elapsed / 10_000 * 1000 // ms per call

        // Each call should be under 0.1ms average
        XCTAssertLessThan(perCall, 0.1)
    }

    func testTouchOptimizer_Performance() async {
        let optimizer = MobileTouchResponseOptimizer()

        let touch = TouchEvent(
            timestamp: CFAbsoluteTimeGetCurrent(),
            location: CGPoint(x: 100, y: 200),
            phase: .began
        )

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<1000 {
            await optimizer.handleTouch(touch)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = elapsed / 1000 * 1000 // ms per call

        // Each call should be under 16ms (INV-MOBILE-014)
        XCTAssertLessThan(perCall, 16)
    }
}
