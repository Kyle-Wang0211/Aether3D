// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Tests for scripts/ci/ssot_integrity_verify.sh
/// Verifies SSOT document integrity checking
final class SSOTIntegrityTests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    // MARK: - Hash Verification Tests

    #if canImport(CryptoKit)
    func testHashMatchPasses() throws {
        // Create document and matching hash
        let docPath = tempDir.appendingPathComponent("TEST.md")
        let hashPath = tempDir.appendingPathComponent("TEST.hash")

        let content = "# Test Document\n\nThis is a test."
        try content.write(to: docPath, atomically: true, encoding: .utf8)

        let hash = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try hash.write(to: hashPath, atomically: true, encoding: .utf8)

        // Verify
        XCTAssertTrue(verifyHash(document: docPath, hashFile: hashPath))
    }

    func testHashMismatchFails() throws {
        let docPath = tempDir.appendingPathComponent("TEST.md")
        let hashPath = tempDir.appendingPathComponent("TEST.hash")

        let content = "# Test Document\n\nThis is a test."
        try content.write(to: docPath, atomically: true, encoding: .utf8)

        // Write wrong hash
        try "0000000000000000000000000000000000000000000000000000000000000000"
            .write(to: hashPath, atomically: true, encoding: .utf8)

        // Verify should fail
        XCTAssertFalse(verifyHash(document: docPath, hashFile: hashPath))
    }

    func testModifiedDocumentDetected() throws {
        let docPath = tempDir.appendingPathComponent("TEST.md")
        let hashPath = tempDir.appendingPathComponent("TEST.hash")

        let originalContent = "# Original"
        try originalContent.write(to: docPath, atomically: true, encoding: .utf8)

        let hash = SHA256.hash(data: Data(originalContent.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try hash.write(to: hashPath, atomically: true, encoding: .utf8)

        // Modify document
        try "# Modified".write(to: docPath, atomically: true, encoding: .utf8)

        // Verify should fail
        XCTAssertFalse(verifyHash(document: docPath, hashFile: hashPath))
    }
    #endif
    
    // MARK: - Header Verification Tests
    
    func testConstantsFileWithSSOTHeader() throws {
        let content = """
            // SSOT: Single Source of Truth
            // This file contains constitutional constants
            
            import Foundation
            
            public enum SystemConstants {
                public static let maxFrames = 5000
            }
            """
        
        XCTAssertTrue(hasRequiredHeader(content))
    }
    
    func testConstantsFileWithConstitutionalHeader() throws {
        let content = """
            // CONSTITUTIONAL CONTRACT
            // Do not modify without RFC approval
            
            import Foundation
            """
        
        XCTAssertTrue(hasRequiredHeader(content))
    }
    
    func testConstantsFileMissingHeader() throws {
        let content = """
            import Foundation
            
            public enum SystemConstants {
                public static let maxFrames = 5000
            }
            """
        
        XCTAssertFalse(hasRequiredHeader(content))
    }
    
    // MARK: - SSOT Document Section Tests
    
    func testSSOTConstantsMDHasRequiredSections() throws {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        
        let ssotDoc = repoRoot.appendingPathComponent("docs/constitution/SSOT_CONSTANTS.md")
        
        guard FileManager.default.fileExists(atPath: ssotDoc.path) else {
            XCTFail("SSOT_CONSTANTS.md not found")
            return
        }
        
        let content = try String(contentsOf: ssotDoc, encoding: .utf8)
        
        let requiredMarkers = [
            "SSOT:VERSION:BEGIN",
            "SSOT:VERSION:END",
            "SSOT:FILES:BEGIN",
            "SSOT:FILES:END",
            "SSOT:SYSTEM_CONSTANTS:BEGIN",
            "SSOT:SYSTEM_CONSTANTS:END",
        ]
        
        for marker in requiredMarkers {
            XCTAssertTrue(content.contains(marker), "Missing required marker: \(marker)")
        }
    }
    
    // MARK: - Helpers

    #if canImport(CryptoKit)
    private func verifyHash(document: URL, hashFile: URL) -> Bool {
        guard let content = try? Data(contentsOf: document),
              let expectedHash = try? String(contentsOf: hashFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        let actualHash = SHA256.hash(data: content)
            .map { String(format: "%02x", $0) }
            .joined()

        return expectedHash == actualHash
    }
    #endif

    private func hasRequiredHeader(_ content: String) -> Bool {
        let first20Lines = content.components(separatedBy: "\n").prefix(20).joined(separator: "\n")
        return first20Lines.contains("CONSTITUTIONAL CONTRACT") ||
               first20Lines.contains("SSOT") ||
               first20Lines.contains("Single Source of Truth")
    }
}
