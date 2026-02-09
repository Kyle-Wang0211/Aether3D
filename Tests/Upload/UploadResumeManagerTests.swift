// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Resume Manager
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class UploadResumeManagerTests: XCTestCase {

    var resumeManager: UploadResumeManager!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "UploadResumeManagerTests")!
        resumeManager = UploadResumeManager(userDefaults: testDefaults, keyPrefix: "test.upload.session.")
    }

    override func tearDown() {
        // Clean up test defaults
        testDefaults.removePersistentDomain(forName: "UploadResumeManagerTests")
        resumeManager = nil
        testDefaults = nil
        super.tearDown()
    }

    func testSaveAndLoadSession() {
        let session = UploadSession(fileName: "test.mp4", fileSize: 1024 * 1024, chunkSize: 512 * 1024)
        session.markChunkCompleted(index: 0)

        resumeManager.saveSession(session)

        // Wait for async save
        let expectation = XCTestExpectation(description: "Save complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let loaded = self.resumeManager.loadSession(sessionId: session.sessionId)
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded?.sessionId, session.sessionId)
            XCTAssertEqual(loaded?.fileName, "test.mp4")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testDeleteSession() {
        let session = UploadSession(fileName: "test.mp4", fileSize: 1024, chunkSize: 512)
        resumeManager.saveSession(session)

        let expectation = XCTestExpectation(description: "Delete complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.resumeManager.deleteSession(sessionId: session.sessionId)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let loaded = self.resumeManager.loadSession(sessionId: session.sessionId)
                XCTAssertNil(loaded)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 3.0)
    }
}
