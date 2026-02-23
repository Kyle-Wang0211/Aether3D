#!/usr/bin/env swift
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
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
    /// Optional path filter: only apply this pattern to files matching this path substring
    public let pathFilter: String?

    public init(regex: String, message: String, description: String, pathFilter: String? = nil) {
        self.regex = regex
        self.message = message
        self.description = description
        self.pathFilter = pathFilter
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
        
        // PR3: Import isolation patterns - applies to all Evidence/
        ForbiddenPattern(
            regex: #"^import\s+simd"#,
            message: "Core/Evidence/ must NOT import simd (use EvidenceVector3)",
            description: "PR3: Zero simd policy - use EvidenceVector3 abstraction"
        ),

        // PR3: Import patterns - only applies to PR3 directory
        ForbiddenPattern(
            regex: #"import\s+Darwin|import\s+Glibc"#,
            message: "Core/Evidence/PR3/ must NOT import Darwin/Glibc directly (use PRMath facade)",
            description: "PR3: All math operations must go through PRMath facade",
            pathFilter: "Core/Evidence/PR3"
        ),
        ForbiddenPattern(
            regex: #"import\s+PRMathDouble|import\s+PRMathFast|import\s+LUTSigmoid"#,
            message: "Core/Evidence/PR3/ must NOT import PRMath implementations directly (use PRMath facade)",
            description: "PR3: Business logic can only import PRMath facade",
            pathFilter: "Core/Evidence/PR3"
        ),

        // PR3: Zero-trig determinism patterns - only applies to PR3 directory (not PRMath which implements them)
        ForbiddenPattern(
            regex: #"\batan2\s*\("#,
            message: "Use ZeroTrigThetaBucketing.thetaBucket() instead of atan2()",
            description: "PR3: Zero-trig policy - canonical path must not use atan2",
            pathFilter: "Core/Evidence/PR3"
        ),
        ForbiddenPattern(
            regex: #"\basin\s*\("#,
            message: "Use ZeroTrigPhiBucketing.phiBucket() instead of asin()",
            description: "PR3: Zero-trig policy - canonical path must not use asin",
            pathFilter: "Core/Evidence/PR3"
        ),

        // PR3: Determinism violation patterns - only applies to PR3 directory
        ForbiddenPattern(
            regex: #"\bDate\s*\(\)|UUID\s*\(\)|\brandom\s*\("#,
            message: "Core/Evidence/PR3/ must NOT use Date(), UUID(), or random()",
            description: "PR3: Determinism requirement - no random number generation",
            pathFilter: "Core/Evidence/PR3"
        ),

        // PR3: Type safety patterns - only applies to PR3 directory
        ForbiddenPattern(
            regex: #"Quantizer\.quantize|Quantizer\.dequantize"#,
            message: "Use QuantizerQ01 or QuantizerAngle (type-safe quantizers)",
            description: "PR3: Generic Quantizer is forbidden - use type-safe variants",
            pathFilter: "Core/Evidence/PR3"
        ),
        ForbiddenPattern(
            regex: #":\s*Float\s*[=,)]"#,
            message: "Core/Evidence/PR3/ must use Double (not Float)",
            description: "PR3: Type safety - all PR3 logic uses Double",
            pathFilter: "Core/Evidence/PR3"
        ),

        // PR3: Tier injection patterns - only applies to PR3 directory
        ForbiddenPattern(
            regex: #"PerformanceTier\.autoDetect\s*\("#,
            message: "Core/Evidence/PR3/ must NOT call autoDetect() (tier must be injected)",
            description: "PR3: Tier injection policy - core algorithm cannot auto-detect",
            pathFilter: "Core/Evidence/PR3"
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments (documentation that references patterns is OK)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") {
                continue
            }

            // Skip deprecated annotations and their following line
            if trimmed.contains("@available(*, deprecated") {
                continue
            }

            // Skip lines with LINT_OK marker
            if line.contains("// LINT_OK") || line.contains("// LINT:OK") {
                continue
            }

            for pattern in forbiddenPatterns {
                // Check path filter
                if let pathFilter = pattern.pathFilter {
                    if !fileURL.path.contains(pathFilter) {
                        continue  // Skip this pattern for files outside the filter path
                    }
                }

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
            "docs/pr/PR3",
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
