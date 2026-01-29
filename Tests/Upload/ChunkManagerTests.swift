// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Chunk Manager
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class ChunkManagerTests: XCTestCase {

    var session: UploadSession!
    var speedMonitor: NetworkSpeedMonitor!
    var chunkSizer: AdaptiveChunkSizer!
    var manager: ChunkManager!

    override func setUp() {
        super.setUp()
        session = UploadSession(fileName: "test.mp4", fileSize: 50 * 1024 * 1024, chunkSize: 5 * 1024 * 1024)
        speedMonitor = NetworkSpeedMonitor()
        chunkSizer = AdaptiveChunkSizer(speedMonitor: speedMonitor)
        manager = ChunkManager(session: session, speedMonitor: speedMonitor, chunkSizer: chunkSizer)
    }

    override func tearDown() {
        manager = nil
        chunkSizer = nil
        speedMonitor = nil
        session = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(manager.activeUploadCount, 0)
        XCTAssertTrue(manager.shouldContinue)
    }

    func testChunkLifecycle() {
        manager.markChunkStarted(index: 0)
        XCTAssertEqual(manager.activeUploadCount, 1)

        manager.markChunkCompleted(index: 0, bytesTransferred: 5 * 1024 * 1024, duration: 1.0)
        XCTAssertEqual(manager.activeUploadCount, 0)
        XCTAssertEqual(session.completedChunkCount, 1)
    }

    func testCancel() {
        manager.markChunkStarted(index: 0)
        manager.cancel()

        XCTAssertFalse(manager.shouldContinue)
        XCTAssertEqual(session.state, .cancelled)
    }

    func testRetryDelay() {
        let delay0 = manager.calculateRetryDelay(attempt: 0)
        _ = manager.calculateRetryDelay(attempt: 1)  // Test intermediate delay
        let delay2 = manager.calculateRetryDelay(attempt: 2)

        XCTAssertGreaterThanOrEqual(delay0, UploadConstants.RETRY_BASE_DELAY_SECONDS * 0.5)
        XCTAssertLessThanOrEqual(delay2, UploadConstants.RETRY_MAX_DELAY_SECONDS * 1.5)
        // Delays should generally increase (though jitter may cause variation)
        XCTAssertLessThan(delay0, delay2 * 2)
    }
}
