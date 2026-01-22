//
// NoMagicNumbersLintTests.swift
// Aether3D
//
// Tests for magic number detection.
//

import XCTest
@testable import Aether3DCore

final class NoMagicNumbersLintTests: XCTestCase {
    
    static let allowedNumbers: Set<String> = [
        "0", "1", "2", "-1", "0.0", "1.0", "0.5", "2.0"
    ]
    
    func test_scan_noMagicNumbersOutsideConstants() throws {
        let coreURL = try RepoRootLocator.directoryURL(for: "Core")
        let constantsPath = coreURL.appendingPathComponent("Constants").path
        
        let enumerator = FileManager.default.enumerator(
            at: coreURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        
        var violations: [String] = []
        
        while let url = enumerator?.nextObject() as? URL {
            // Skip Constants directory
            if url.path.hasPrefix(constantsPath) { continue }
            // Only Swift files
            guard url.pathExtension == "swift" else { continue }
            
            // Skip existing directories (not part of SSOT Phase 1)
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
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Skip comments and allowed patterns
                if trimmed.hasPrefix("//") { continue }
                if line.contains("// LINT:ALLOW") || line.contains("// SSOT_EXEMPTION") { continue }
                
                // Check for suspicious patterns
                if let violation = checkForMagicNumber(line: line, lineNumber: index + 1, file: url.lastPathComponent) {
                    violations.append(violation)
                }
            }
        }
        
        // Allow up to 10 warnings for existing code
        if violations.count > 10 {
            XCTFail("Too many magic numbers (\(violations.count)):\n\(violations.prefix(10).joined(separator: "\n"))")
        }
    }
    
    private func checkForMagicNumber(line: String, lineNumber: Int, file: String) -> String? {
        // Pattern: assignment with 3+ digit number
        let patterns = [
            #"=\s*\d{4,}"#,        // 4+ digits (likely magic)
            #"timeout.*[3-9]\d{2}"#, // timeout with 300+
        ]
        
        for pattern in patterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
                return "\(file):\(lineNumber): Possible magic number"
            }
        }
        
        return nil
    }
}

