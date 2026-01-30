//
// PrintStatementScanTests.swift
// Aether3D
//
// Tests for print statement detection.
//

import XCTest
@testable import Aether3DCore

final class PrintStatementScanTests: XCTestCase {
    
    func test_scan_noPrintInCore() throws {
        let coreURL = try RepoRootLocator.directoryURL(for: "Core")
        
        let enumerator = FileManager.default.enumerator(
            at: coreURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        
        var violations: [String] = []
        
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            
            // Skip existing directories (not part of SSOT Phase 1)
            // Evidence uses cross-platform print() for Linux compatibility
            if url.path.contains("/Pipeline/") ||
               url.path.contains("/Audit/") ||
               url.path.contains("/Artifacts/") ||
               url.path.contains("/Router/") ||
               url.path.contains("/BuildMeta/") ||
               url.path.contains("/Invariants/") ||
               url.path.contains("/Models/") ||
               url.path.contains("/Rendering/") ||
               url.path.contains("/Utils/") ||
               url.path.contains("/Quality/") ||
               url.path.contains("/Infrastructure/") ||
               url.path.contains("/Evidence/") {
                continue
            }
            
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if line.contains("// LINT:ALLOW") || line.contains("// SSOT_EXEMPTION") { continue }
                
                if line.contains("print(") || line.contains("debugPrint(") {
                    violations.append("\(url.lastPathComponent):\(index + 1): Found print statement")
                }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Print statements in Core:\n\(violations.joined(separator: "\n"))")
    }
}

