// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// AuditStaticLintTests.swift
// PR#8.5 / v0.0.1

import XCTest
import Foundation

/// Static lint tests for PR#8.5 audit trace contract.
///
/// Enforces coding standards and banned patterns.
/// This is a read-only static analysis test.
final class AuditStaticLintTests: XCTestCase {
    
    // MARK: - PR#8.5 File Markers
    
    /// PR#8.5 created/modified files must contain "PR#8.5" marker in header.
    func test_pr85Files_haveMarker() {
        let pr85Files = [
            // Core/Audit - New files
            "Core/Audit/AuditEventType.swift",
            "Core/Audit/AuditActionType.swift",
            "Core/Audit/InputDescriptor.swift",
            "Core/Audit/TraceMetrics.swift",
            "Core/Audit/CanonicalJSONEncoder.swift",
            "Core/Audit/TraceIdGenerator.swift",
            "Core/Audit/TraceValidator.swift",
            "Core/Audit/AuditTraceEmitter.swift",
            "Core/Audit/OrphanTraceReport.swift",
            
            // Core/Audit - Modified files
            "Core/Audit/AuditEntry.swift",
            
            // Core - Modified files
            "Core/Utils/Clock.swift",
            "Core/BuildMeta/BuildMeta.swift",
            
            // Tests - New files
            "Tests/Audit/TestHelpers/InMemoryAuditLog.swift",
            "Tests/Audit/AuditTraceContractTests.swift",
            "Tests/Audit/AuditTraceContractTests_Smoke.swift",
            "Tests/Audit/TestHelpers/AuditTraceTestFactories.swift",
        ]
        
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Tests/Audit
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
        
        var failures: [String] = []
        
        for relativePath in pr85Files {
            let fileURL = projectRoot.appendingPathComponent(relativePath)
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                failures.append("\(relativePath): File not found or unreadable")
                continue
            }
            
            // Check first 10 lines for PR#8.5 marker
            let lines = content.components(separatedBy: .newlines).prefix(10)
            let header = lines.joined(separator: "\n")
            
            if !header.contains("PR#8.5") && !header.contains("PR#8") {
                failures.append("\(relativePath): Missing PR#8.5 marker in header")
            }
        }
        
        if !failures.isEmpty {
            XCTFail("Files missing PR#8.5 marker:\n" + failures.joined(separator: "\n"))
        }
    }
    
    // MARK: - Banned Patterns in Core/Audit
    
    /// Enforce banned patterns in Core/Audit source files.
    func test_coreAudit_noBannedPatterns() {
        let bannedPatterns: [(pattern: String, description: String)] = [
            ("\\bUUID\\b", "UUID (use deterministic ID generation)"),
            ("\\bUUID\\(\\)", "UUID() constructor"),
            ("\\bNSUUID\\b", "NSUUID (use deterministic ID generation)"),
            ("\\brandom\\(\\)", "random() (non-deterministic)"),
            ("\\barc4random", "arc4random (non-deterministic)"),
            ("\\bDate\\(\\)", "Date() (use WallClock.now())"),
            ("\\bprint\\s*\\(", "print() (banned in production code)"),
            ("\\bNSLog\\s*\\(", "NSLog() (banned)"),
            ("\\bos_log\\s*\\(", "os_log() (banned)"),
            ("@unchecked\\s+Sendable", "@unchecked Sendable (unsafe concurrency)"),
            ("\\bFileManager\\.default", "FileManager.default (use dependency injection)"),
            ("\\bFileManager\\(", "FileManager() (use dependency injection)"),
        ]
        
        let coreAuditFiles = [
            "Core/Audit/AuditEventType.swift",
            "Core/Audit/AuditActionType.swift",
            "Core/Audit/InputDescriptor.swift",
            "Core/Audit/TraceMetrics.swift",
            "Core/Audit/CanonicalJSONEncoder.swift",
            "Core/Audit/TraceIdGenerator.swift",
            "Core/Audit/TraceValidator.swift",
            "Core/Audit/AuditTraceEmitter.swift",
            "Core/Audit/OrphanTraceReport.swift",
            "Core/Audit/AuditEntry.swift",
        ]
        
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Tests/Audit
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
        
        var failures: [String] = []
        
        for relativePath in coreAuditFiles {
            let fileURL = projectRoot.appendingPathComponent(relativePath)
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue  // Skip if file doesn't exist
            }
            
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                for (pattern, description) in bannedPatterns {
                    let regex = try? NSRegularExpression(pattern: pattern, options: [])
                    let range = NSRange(location: 0, length: line.utf16.count)
                    
                    if let matches = regex?.matches(in: line, options: [], range: range), !matches.isEmpty {
                        // Allow in comments or strings (but be conservative)
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        
                        // Skip if it's clearly in a comment
                        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") {
                            continue
                        }
                        
                        // Skip if it's in a multi-line comment block (basic check)
                        if trimmed.contains("/*") && trimmed.contains("*/") {
                            continue
                        }
                        
                        let lineNumber = index + 1
                        let snippet = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        let maxSnippetLength = 80
                        let displaySnippet = snippet.count > maxSnippetLength
                            ? String(snippet.prefix(maxSnippetLength)) + "..."
                            : snippet
                        
                        failures.append("\(relativePath):\(lineNumber): \(description) - \(displaySnippet)")
                    }
                }
            }
        }
        
        if !failures.isEmpty {
            XCTFail("Banned patterns found in Core/Audit:\n" + failures.joined(separator: "\n"))
        }
    }
    
    // MARK: - Banned Patterns in Tests/Audit
    
    /// Enforce banned patterns in Tests/Audit files (where applicable).
    func test_testsAudit_noBannedPatterns() {
        // More lenient rules for test files, but still ban some patterns
        let bannedPatterns: [(pattern: String, description: String)] = [
            ("\\bUUID\\b", "UUID (use deterministic ID generation in tests)"),
            ("\\brandom\\(\\)", "random() (tests should be deterministic)"),
            ("\\barc4random", "arc4random (tests should be deterministic)"),
            ("@unchecked\\s+Sendable", "@unchecked Sendable (unsafe concurrency)"),
        ]
        
        let testAuditFiles = [
            "Tests/Audit/TestHelpers/InMemoryAuditLog.swift",
            "Tests/Audit/AuditTraceContractTests.swift",
            "Tests/Audit/AuditTraceContractTests_Smoke.swift",
            "Tests/Audit/TestHelpers/AuditTraceTestFactories.swift",
        ]
        
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Tests/Audit
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // project root
        
        var failures: [String] = []
        
        for relativePath in testAuditFiles {
            let fileURL = projectRoot.appendingPathComponent(relativePath)
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue  // Skip if file doesn't exist
            }
            
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                for (pattern, description) in bannedPatterns {
                    let regex = try? NSRegularExpression(pattern: pattern, options: [])
                    let range = NSRange(location: 0, length: line.utf16.count)
                    
                    if let matches = regex?.matches(in: line, options: [], range: range), !matches.isEmpty {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        
                        // Skip if it's clearly in a comment
                        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") {
                            continue
                        }
                        
                        let lineNumber = index + 1
                        let snippet = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        let maxSnippetLength = 80
                        let displaySnippet = snippet.count > maxSnippetLength
                            ? String(snippet.prefix(maxSnippetLength)) + "..."
                            : snippet
                        
                        failures.append("\(relativePath):\(lineNumber): \(description) - \(displaySnippet)")
                    }
                }
            }
        }
        
        if !failures.isEmpty {
            XCTFail("Banned patterns found in Tests/Audit:\n" + failures.joined(separator: "\n"))
        }
    }
}

