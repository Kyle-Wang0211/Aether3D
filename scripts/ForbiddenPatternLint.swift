#!/usr/bin/env swift
//
// ForbiddenPatternLint.swift
// Aether3D
//
// PR2 Patch V4 - Forbidden Pattern Lint
// Scans repository for forbidden patterns that violate evidence system constraints
//

import Foundation

/// Forbidden pattern violation
public struct LintViolation: CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int
    public let pattern: String
    public let message: String
    public let snippet: String
    
    public var description: String {
        return "\(file):\(line):\(column): \(message)\n  Pattern: \(pattern)\n  Snippet: \(snippet.prefix(80))"
    }
}

/// Forbidden pattern definition
public struct ForbiddenPattern {
    public let regex: String
    public let message: String
    public let description: String
    
    public init(regex: String, message: String, description: String) {
        self.regex = regex
        self.message = message
        self.description = description
    }
}

/// Forbidden pattern lint checker
/// NOTE: This is a script file, but can be imported for testing
public enum ForbiddenPatternLint {
    
    /// All forbidden patterns
    public static let forbiddenPatterns: [ForbiddenPattern] = [
        // A1: max(gate, soft) patterns
        ForbiddenPattern(
            regex: #"max\s*\(\s*gate.*soft"#,
            message: "Use SplitLedger with separate gateLedger/softLedger updates",
            description: "max(gateQuality, softQuality) pollutes ledger semantics"
        ),
        ForbiddenPattern(
            regex: #"max\s*\(\s*soft.*gate"#,
            message: "Use SplitLedger with separate gateLedger/softLedger updates",
            description: "max(softQuality, gateQuality) pollutes ledger semantics"
        ),
        ForbiddenPattern(
            regex: #"ledgerQuality\s*=\s*max\s*\("#,
            message: "Use separate gateQuality/softQuality parameters",
            description: "ledgerQuality = max(...) violates SplitLedger architecture"
        ),
        
        // Old API patterns
        ForbiddenPattern(
            regex: #"observation\.quality"#,
            message: "Use explicit gateQuality/softQuality parameters",
            description: "observation.quality field removed in PR2"
        ),
        ForbiddenPattern(
            regex: #"isErroneous:\s*Bool"#,
            message: "Use verdict: ObservationVerdict instead",
            description: "isErroneous: Bool replaced with ObservationVerdict enum"
        ),
        
        // Serialization patterns (only in public APIs, not internal implementation)
        // Note: TrueDeterministicJSONEncoder uses [String: Any] internally for parsing, which is acceptable
        // We only flag it in public function signatures
        ForbiddenPattern(
            regex: #"public\s+func.*->\s*\[String:\s*Any\]"#,
            message: "Use Codable types for cross-platform serialization",
            description: "[String: Any] in public API is not cross-platform compatible"
        ),
        
        // Delta calculation patterns (only for evidence delta, not other deltas)
        ForbiddenPattern(
            regex: #"evidenceDelta.*minDelta|gateDelta.*minDelta|softDelta.*minDelta"#,
            message: "Evidence delta should be exact (newDisplay - prevDisplay), no padding",
            description: "minDelta padding violates Rule D"
        ),
        
        // Aggregation patterns (heuristic: full iteration in totalEvidence)
        ForbiddenPattern(
            regex: #"for\s+.*\s+in\s+patches\s*\{[^}]*evidence[^}]*\*[^}]*weight"#,
            message: "Use BucketedAmortizedAggregator for O(k) aggregation",
            description: "Full patch iteration each frame violates performance budget"
        ),
    ]
    
    /// Scan file for forbidden patterns
    public static func scanFile(_ fileURL: URL) -> [LintViolation] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        
        var violations: [LintViolation] = []
        let lines = content.components(separatedBy: .newlines)
        
        for (lineIndex, line) in lines.enumerated() {
            for pattern in forbiddenPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                    continue
                }
                
                let range = NSRange(location: 0, length: line.utf16.count)
                let matches = regex.matches(in: line, options: [], range: range)
                
                for match in matches {
                    let matchRange = match.range
                    let column = line.utf16.index(line.utf16.startIndex, offsetBy: matchRange.location)
                    let columnIndex = line.utf16.distance(from: line.utf16.startIndex, to: column)
                    
                    let snippet = String(line.prefix(min(100, line.count)))
                    
                    violations.append(LintViolation(
                        file: fileURL.path,
                        line: lineIndex + 1,
                        column: columnIndex + 1,
                        pattern: pattern.regex,
                        message: pattern.message,
                        snippet: snippet
                    ))
                }
            }
        }
        
        return violations
    }
    
    /// Scan directory recursively
    /// Only scans Evidence-related files to avoid false positives
    public static func scanDirectory(_ directoryURL: URL, extensions: [String] = ["swift", "md"]) -> [LintViolation] {
        var violations: [LintViolation] = []
        
        // Only scan Evidence-related paths
        let evidencePaths = [
            "Core/Evidence",
            "Tests/Evidence",
            "docs/pr/PR2",
            "Scripts/ForbiddenPatternLint.swift"
        ]
        
        for evidencePath in evidencePaths {
            let pathURL = directoryURL.appendingPathComponent(evidencePath)
            guard FileManager.default.fileExists(atPath: pathURL.path) else {
                continue
            }
            
            guard let enumerator = FileManager.default.enumerator(
                at: pathURL,
                includingPropertiesForKeys: [URLResourceKey.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [URLResourceKey.isRegularFileKey]),
                      resourceValues.isRegularFile == true else {
                    continue
                }
                
                let ext = fileURL.pathExtension.lowercased()
                guard extensions.contains(ext) else {
                    continue
                }
                
                // Skip test fixtures and golden files
                if fileURL.path.contains("Fixtures") || fileURL.path.contains("Golden") {
                    continue
                }
                
                violations.append(contentsOf: scanFile(fileURL))
            }
        }
        
        return violations
    }
    
    /// Main entry point
    public static func main() {
        let args = CommandLine.arguments
        let repoRoot = args.count > 1 ? URL(fileURLWithPath: args[1]) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        
        let violations = scanDirectory(repoRoot)
        
        if violations.isEmpty {
            print("✓ No forbidden patterns detected")
            exit(0)
        } else {
            print("✗ Found \(violations.count) forbidden pattern violation(s):\n")
            for violation in violations {
                print(violation)
                print()
            }
            exit(1)
        }
    }
}

// Run if executed directly
if CommandLine.arguments[0].contains("ForbiddenPatternLint") {
    ForbiddenPatternLint.main()
}
