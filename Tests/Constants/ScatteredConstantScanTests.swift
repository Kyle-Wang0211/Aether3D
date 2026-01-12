//
// ScatteredConstantScanTests.swift
// Aether3D
//
// Tests for scattered constants outside Core/Constants/.
// PATCH E: New test to detect static let/let declarations that should be in SSOT.
//

import XCTest
@testable import Aether3DCore

final class ScatteredConstantScanTests: XCTestCase {
    func testNoScatteredConstantsInCore() {
        let coreDir = RepoRootLocator.resolvePath("Core")
        XCTAssertNotNil(coreDir, "Could not locate Core directory")
        
        guard let dir = coreDir else { return }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            XCTFail("Could not enumerate Core directory")
            return
        }
        
        var violations: [String] = []
        
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            
            // Skip Constants directory (constants are allowed there)
            if file.path.contains("/Constants/") {
                continue
            }
            
            // Skip Pipeline directory (existing code, not part of SSOT Phase 1)
            if file.path.contains("/Pipeline/") {
                continue
            }
            
            // Skip Infrastructure directory (SSOTEncoder, TimeProvider are infrastructure, not constants)
            if file.path.contains("/Infrastructure/") {
                continue
            }
            
            // Skip Router directory (existing code)
            if file.path.contains("/Router/") {
                continue
            }
            
            // Skip Audit directory (existing code, not part of SSOT Phase 1)
            if file.path.contains("/Audit/") {
                continue
            }
            
            // Skip Artifacts directory (existing code, not part of SSOT Phase 1)
            if file.path.contains("/Artifacts/") {
                continue
            }
            
            // Skip other existing directories (Phase 1 only checks new SSOT code)
            if file.path.contains("/BuildMeta/") ||
               file.path.contains("/Invariants/") ||
               file.path.contains("/Models/") ||
               file.path.contains("/Rendering/") ||
               file.path.contains("/Utils/") {
                continue
            }
            
            guard let content = try? String(contentsOf: file) else { continue }
            
            let lines = content.components(separatedBy: .newlines)
            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Check for static let or let declarations that look like constants
                if (trimmed.hasPrefix("static let ") || trimmed.hasPrefix("let ")) &&
                   !trimmed.contains("// SSOT_EXEMPTION") &&
                   !trimmed.contains("// SCATTERED_OK") {
                    
                    // Check if it's a simple constant (not a computed property or function)
                    if !trimmed.contains("=") || trimmed.contains("{") {
                        continue
                    }
                    
                    // Extract constant name
                    let components = trimmed.components(separatedBy: "=")
                    if let firstPart = components.first {
                        let namePart = firstPart.trimmingCharacters(in: .whitespaces)
                        if namePart.contains("let ") {
                            let msg = TestFailureFormatter.formatProhibitionViolation(
                                pattern: "scattered constant",
                                file: file.lastPathComponent,
                                line: lineIndex + 1,
                                reason: "Constants should be defined in Core/Constants/, not scattered in other directories"
                            )
                            violations.append(msg)
                        }
                    }
                }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Scattered constant violations found:\n" + violations.joined(separator: "\n"))
    }
}

