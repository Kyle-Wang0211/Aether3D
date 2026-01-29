// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Upload Session
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class UploadSessionTests: XCTestCase {

    var session: UploadSession!

    override func setUp() {
        super.setUp()
        session = UploadSession(
            fileName: "test.mp4",
            fileSize: 50 * 1024 * 1024,  // 50MB
            chunkSize: 5 * 1024 * 1024   // 5MB chunks
        )
    }

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(session.state, .initialized)
        XCTAssertEqual(session.totalChunkCount, 10)  // 50MB / 5MB
        XCTAssertEqual(session.completedChunkCount, 0)
        XCTAssertEqual(session.progress, 0.0)
    }

    func testChunkCompletion() {
        session.markChunkCompleted(index: 0)

        XCTAssertEqual(session.completedChunkCount, 1)
        XCTAssertEqual(session.progress, 0.1, accuracy: 0.01)
    }

    func testStateTransition() {
        session.updateState(.uploading)
        XCTAssertEqual(session.state, .uploading)

        session.updateState(.completed)
        XCTAssertEqual(session.state, .completed)
        XCTAssertTrue(session.state.isTerminal)
    }

    func testChunkFailure() {
        session.markChunkFailed(index: 0, error: "Network error")

        let chunk = session.chunks[0]
        XCTAssertEqual(chunk.state, .failed)
        XCTAssertEqual(chunk.retryCount, 1)
        XCTAssertEqual(chunk.lastError, "Network error")
    }

    func testGetNextPendingChunk() {
        let pending = session.getNextPendingChunk()
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.index, 0)

        session.markChunkCompleted(index: 0)
        let nextPending = session.getNextPendingChunk()
        XCTAssertEqual(nextPending?.index, 1)
    }
}
