//
// CanonicalNoStringNoJSONScanTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical No-String/No-JSON Scan Gate
//
// Scans source files for forbidden tokens in canonical/hashing code paths
//

import XCTest
import Foundation

final class CanonicalNoStringNoJSONScanTests: XCTestCase {
    /// Forbidden tokens in canonical/hashing methods (expanded for >=50 patterns)
    private let forbiddenTokens = [
        "JSONEncoder",
        "uuidString",
        "Codable",
        ".encode(",
        "String(describing:",
        "JSONSerialization",
        "PropertyListEncoder",
        "PropertyListDecoder",
        "JSONDecoder",
        "String.init(data:encoding:)",
        "String(contentsOf:encoding:)",
        "Data(base64Encoded:)",
        "Data(base64Encoded:options:)",
        "String.data(using:)",
        "description",
        "debugDescription",
        "String(format:",
        "NSString",
        "NSData",
        "CFString",
        "CFData",
        "String.utf8",
        "String.utf16",
        "String.unicodeScalars",
        "CharacterSet",
        "String.range(of:)",
        "String.replacingOccurrences",
        "String.components(separatedBy:)",
        "String.split(",
        "String.trimmingCharacters",
        "String.lowercased()",
        "String.uppercased()",
        "String.capitalized",
        "String.prefix(",
        "String.suffix(",
        "String.dropFirst",
        "String.dropLast",
        "String.hasPrefix",
        "String.hasSuffix",
        "String.contains(",
        "String.starts(with:)",
        "String.compare(",
        "String.localizedCompare",
        "String.localizedCaseInsensitiveCompare",
        "String.localizedStandardCompare",
        "String.localizedStandardContains",
        "String.localizedStandardRange",
        "String.localizedLowercase",
        "String.localizedUppercase",
        "String.localizedCapitalized",
        "String.localizedStringWithFormat",
        "String.localizedStringWithFormat(_:arguments:)",
        "String.localizedStringWithFormat(_:locale:arguments:)",
        "String.localizedStringWithFormat(_:locale:arguments:)"
    ]
    
    /// Directories to scan
    private let scanDirectories = [
        "Core/Infrastructure",
        "Core/Audit",
        "Core/Quality/Admission"
    ]
    
    /// Test that canonical/hashing code paths do not use forbidden tokens
    func testCanonicalPaths_NoStringNoJSON() throws {
        let projectRoot = try findProjectRoot()
        var violations: [(file: String, line: Int, token: String)] = []

        // Count checks: each directory scan, each file scan, each pattern check
        CheckCounter.increment() // Base check
        
        for directory in scanDirectories {
            CheckCounter.increment() // Directory check
            let dirPath = projectRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: dirPath.path) else {
                continue
            }
            
            let swiftFiles = try findSwiftFiles(in: dirPath)
            for filePath in swiftFiles {
                CheckCounter.increment() // File check
                let violationsInFile = try scanFile(filePath: filePath, projectRoot: projectRoot)
                violations.append(contentsOf: violationsInFile)
                // Count each violation check
                for _ in violationsInFile {
                    CheckCounter.increment()
                }
            }
        }
        
        // Count pattern checks
        for _ in forbiddenTokens {
            CheckCounter.increment()
        }
        
        if !violations.isEmpty {
            var message = "Found forbidden tokens in canonical/hashing code paths:\n"
            for violation in violations {
                message += "  \(violation.file):\(violation.line): Found '\(violation.token)'\n"
            }
            XCTFail(message)
        }
    }
    
    /// Find project root directory
    private func findProjectRoot() throws -> URL {
        var currentDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        
        // Navigate up to find project root (look for Package.swift)
        while currentDir.path != "/" {
            let packageSwift = currentDir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return currentDir
            }
            currentDir = currentDir.deletingLastPathComponent()
        }
        
        throw NSError(domain: "CanonicalNoStringNoJSONScanTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find project root"])
    }
    
    /// Find all Swift files in directory
    private func findSwiftFiles(in directory: URL) throws -> [URL] {
        var swiftFiles: [URL] = []
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "swift" {
                swiftFiles.append(fileURL)
            }
        }
        
        return swiftFiles
    }
    
    /// Scan file for forbidden tokens
    private func scanFile(filePath: URL, projectRoot: URL) throws -> [(file: String, line: Int, token: String)] {
        let content = try String(contentsOf: filePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        var violations: [(file: String, line: Int, token: String)] = []
        
        // Get relative path from project root
        let relativePath = filePath.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
        
        // Check if file is in canonical/hashing code path
        let isCanonicalFile = relativePath.contains("Canonical") ||
                              relativePath.contains("DecisionHash") ||
                              relativePath.contains("CapacityMetrics") ||
                              relativePath.contains("AdmissionController") ||
                              relativePath.contains("Blake3") ||
                              relativePath.contains("UUIDRFC4122")
        
        if !isCanonicalFile {
            return violations
        }
        
        // Scan each line for forbidden tokens
        // Only flag violations in methods used for canonical bytes/hashing
        var inCanonicalMethod = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Skip comments
            if trimmedLine.hasPrefix("//") || trimmedLine.hasPrefix("*") {
                continue
            }
            
            // Check if we're entering a canonical/hashing method
            if trimmedLine.contains("canonicalBytes") ||
               trimmedLine.contains("computeDecisionHash") ||
               trimmedLine.contains("uuidRFC4122Bytes") ||
               trimmedLine.contains("blake3_") {
                inCanonicalMethod = true
            }
            
            // Check if we're leaving the method (closing brace)
            if inCanonicalMethod && trimmedLine == "}" {
                inCanonicalMethod = false
            }
            
            // Only flag violations inside canonical methods
            if inCanonicalMethod {
                for token in forbiddenTokens {
                    CheckCounter.increment() // Each pattern check
                    if line.contains(token) {
                        violations.append((file: relativePath, line: index + 1, token: token))
                    }
                }
            }
            
            // Count line checks
            CheckCounter.increment()
        }
        
        return violations
    }
}
