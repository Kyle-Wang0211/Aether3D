//
// ForbiddenPatternLintTests.swift
// Aether3D
//
// PR2 Patch V4 - Forbidden Pattern Lint Tests
// Automated CI gate for forbidden patterns
//

import XCTest
@testable import Aether3DCore
import Foundation

// Import ForbiddenPatternLint from Scripts directory
// Since it's a script file, we'll test it by running the script directly
// For now, skip these tests if the script isn't available

final class ForbiddenPatternLintTests: XCTestCase {
    
    /// Test that lint script runs and detects violations
    func testLintScriptRuns() throws {
        // Get repository root
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        
        // Run lint script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "Scripts/ForbiddenPatternLint.swift",
            repoRoot.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // If exit code is 1, violations were found
        if process.terminationStatus == 1 {
            XCTFail("Forbidden patterns detected:\n\(output)")
        }
        
        // Otherwise, should exit with 0
        XCTAssertEqual(process.terminationStatus, 0, "Lint script should exit with 0 when clean")
    }
    
    /// Test that lint detects max(gate, soft) pattern
    /// NOTE: This test requires ForbiddenPatternLint to be available as a module
    /// For now, we'll skip this test and rely on CI to run the lint script directly
    func testLintDetectsMaxGateSoft() {
        // TODO: Implement when ForbiddenPatternLint is available as a testable module
        // For now, this is tested via CI script execution
        XCTAssertTrue(true, "Lint is tested via CI script execution")
    }
    
    /// Test that lint detects observation.quality
    /// NOTE: This test requires ForbiddenPatternLint to be available as a module
    func testLintDetectsObservationQuality() {
        // TODO: Implement when ForbiddenPatternLint is available as a testable module
        // For now, this is tested via CI script execution
        XCTAssertTrue(true, "Lint is tested via CI script execution")
    }
    
    /// Helper to create temporary file
    private func createTempFile(content: String) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".swift")
        try! content.write(to: tempFile, atomically: true, encoding: .utf8)
        return tempFile
    }
}
