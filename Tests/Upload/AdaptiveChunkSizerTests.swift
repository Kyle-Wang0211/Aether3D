// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Adaptive Chunk Sizer
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class AdaptiveChunkSizerTests: XCTestCase {

    var speedMonitor: NetworkSpeedMonitor!
    var sizer: AdaptiveChunkSizer!

    override func setUp() {
        super.setUp()
        speedMonitor = NetworkSpeedMonitor()
        sizer = AdaptiveChunkSizer(speedMonitor: speedMonitor)
    }

    override func tearDown() {
        sizer = nil
        speedMonitor = nil
        super.tearDown()
    }

    func testFixedStrategy() {
        let config = AdaptiveChunkConfig(strategy: .fixed)
        let fixedSizer = AdaptiveChunkSizer(config: config, speedMonitor: speedMonitor)

        XCTAssertEqual(fixedSizer.calculateChunkSize(), UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    func testAdaptiveStrategySlowNetwork() {
        // Simulate slow network
        for _ in 0..<5 {
            speedMonitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(sizer.calculateChunkSize(), UploadConstants.CHUNK_SIZE_MIN_BYTES)
    }

    func testAdaptiveStrategyFastNetwork() {
        // Simulate fast network
        for _ in 0..<5 {
            speedMonitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertGreaterThan(sizer.calculateChunkSize(), UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    func testSmallFileSizing() {
        let smallFileSize: Int64 = 3 * 1024 * 1024  // 3MB
        let chunkSize = sizer.calculateChunkSize(forFileSize: smallFileSize)

        XCTAssertLessThanOrEqual(chunkSize, Int(smallFileSize))
    }
}
