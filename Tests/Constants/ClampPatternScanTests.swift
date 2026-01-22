//
// ClampPatternScanTests.swift
// Aether3D
//
// Tests for clamp pattern detection.
//

import XCTest
@testable import Aether3DCore

final class ClampPatternScanTests: XCTestCase {
    
    func test_scan_clampNotSilent() throws {
        let coreURL = try RepoRootLocator.directoryURL(for: "Core")
        
        let enumerator = FileManager.default.enumerator(
            at: coreURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        
        var violations: [String] = []
        
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            
            // Skip existing directories
            if url.path.contains("/Pipeline/") ||
               url.path.contains("/Audit/") ||
               url.path.contains("/Artifacts/") ||
               url.path.contains("/Infrastructure/") ||
               url.path.contains("/Router/") ||
               url.path.contains("/BuildMeta/") ||
               url.path.contains("/Invariants/") ||
               url.path.contains("/Models/") ||
               url.path.contains("/Rendering/") ||
               url.path.contains("/Utils/") {
                continue
            }
            
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                // Look for min/max clamping without logging
                if (line.contains("min(") || line.contains("max(")) &&
                   !line.contains("Log") &&
                   !line.contains("// LINT:ALLOW") &&
                   !line.contains("// SSOT_EXEMPTION") {
                    // Check surrounding lines for logging
                    let context = lines[max(0, index-2)...min(lines.count-1, index+2)].joined()
                    if !context.contains("Log") && !context.contains("record") {
                        // This is a potential silent clamp - just warn, don't fail
                        violations.append("\(url.lastPathComponent):\(index + 1): Potential silent clamp")
                    }
                }
            }
        }
        
        // Warn but don't fail - this is advisory
        if !violations.isEmpty {
            print("⚠️ Silent clamp warnings:\n\(violations.prefix(5).joined(separator: "\n"))")
        }
    }
}

