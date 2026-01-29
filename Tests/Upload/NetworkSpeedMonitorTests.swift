// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Network Speed Monitor
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class NetworkSpeedMonitorTests: XCTestCase {

    var monitor: NetworkSpeedMonitor!

    override func setUp() {
        super.setUp()
        monitor = NetworkSpeedMonitor()
    }

    override func tearDown() {
        monitor = nil
        super.tearDown()
    }

    // =========================================================================
    // MARK: - Classification Tests
    // =========================================================================

    func testSlowNetworkClassification() {
        // 2 Mbps = ~250 KB/s = 250,000 bytes/sec
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .slow)
        XCTAssertLessThan(monitor.getSpeedMbps(), UploadConstants.NETWORK_SPEED_SLOW_MBPS)
    }

    func testNormalNetworkClassification() {
        // 20 Mbps = ~2.5 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 2_500_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .normal)
    }

    func testFastNetworkClassification() {
        // 80 Mbps = ~10 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .fast)
    }

    func testUltrafastNetworkClassification() {
        // 200 Mbps = ~25 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 25_000_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .ultrafast)
    }

    // =========================================================================
    // MARK: - Reliability Tests
    // =========================================================================

    func testUnknownWithInsufficientSamples() {
        monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)

        XCTAssertFalse(monitor.hasReliableEstimate())
        XCTAssertEqual(monitor.getSpeedClass(), .unknown)
    }

    func testReliableWithSufficientSamples() {
        for _ in 0..<UploadConstants.NETWORK_SPEED_MIN_SAMPLES {
            monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)
        }

        XCTAssertTrue(monitor.hasReliableEstimate())
        XCTAssertNotEqual(monitor.getSpeedClass(), .unknown)
    }

    // =========================================================================
    // MARK: - Edge Case Tests
    // =========================================================================

    func testZeroBytesIgnored() {
        monitor.recordSample(bytesTransferred: 0, durationSeconds: 1.0)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    func testNegativeBytesIgnored() {
        monitor.recordSample(bytesTransferred: -100, durationSeconds: 1.0)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    func testZeroDurationIgnored() {
        monitor.recordSample(bytesTransferred: 1000, durationSeconds: 0)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    // =========================================================================
    // MARK: - Reset Tests
    // =========================================================================

    func testReset() {
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)
        }

        XCTAssertTrue(monitor.hasReliableEstimate())

        monitor.reset()

        XCTAssertFalse(monitor.hasReliableEstimate())
        XCTAssertEqual(monitor.getSpeedClass(), .unknown)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    // =========================================================================
    // MARK: - Thread Safety Tests
    // =========================================================================

    func testConcurrentAccess() {
        let expectation = XCTestExpectation(description: "Concurrent access")
        let iterations = 100
        let dispatchGroup = DispatchGroup()

        for i in 0..<iterations {
            dispatchGroup.enter()
            DispatchQueue.global().async {
                self.monitor.recordSample(
                    bytesTransferred: Int64(i * 1000),
                    durationSeconds: 0.1
                )
                _ = self.monitor.getSpeedClass()
                _ = self.monitor.getSpeedMbps()
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            // Should not crash, data should be consistent
            XCTAssertGreaterThanOrEqual(self.monitor.getSampleCount(), 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // =========================================================================
    // MARK: - Recommendation Tests
    // =========================================================================

    func testSlowNetworkRecommendations() {
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(
            monitor.getRecommendedChunkSize(),
            UploadConstants.CHUNK_SIZE_MIN_BYTES
        )
        XCTAssertEqual(monitor.getRecommendedParallelCount(), 2)
    }

    func testFastNetworkRecommendations() {
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertGreaterThan(
            monitor.getRecommendedChunkSize(),
            UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        )
        XCTAssertEqual(
            monitor.getRecommendedParallelCount(),
            UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS
        )
    }
}
