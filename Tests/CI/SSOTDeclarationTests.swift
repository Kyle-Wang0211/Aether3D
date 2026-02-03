import XCTest
import Foundation

/// Tests for scripts/ci/ssot_declaration_check.sh
/// Verifies SSOT declaration enforcement logic
final class SSOTDeclarationTests: XCTestCase {
    
    private var repoRoot: URL!
    private var scriptPath: URL!
    
    override func setUp() {
        super.setUp()
        
        // Get repository root directory
        repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // CI
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        
        scriptPath = repoRoot.appendingPathComponent("scripts/ci/ssot_declaration_check.sh")
    }
    
    // MARK: - Script Existence and Structure Tests
    
    func testScriptExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath.path),
                      "SSOT declaration script must exist at: \(scriptPath.path)")
    }
    
    func testScriptIsExecutable() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: scriptPath.path)
        let permissions = attributes?[.posixPermissions] as? Int
        XCTAssertNotNil(permissions)
        XCTAssertTrue((permissions! & 0o111) != 0, "Script must be executable")
    }
    
    func testScriptHasCorrectShebang() throws {
        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("#!/usr/bin/env bash") || content.hasPrefix("#!/bin/bash"),
                      "Script must have bash shebang")
    }
    
    func testScriptContainsRequiredPrefixes() throws {
        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        
        let requiredPrefixes = [
            "Core/Constants/",
            "Core/SSOT/",
            "docs/constitution/",
            ".github/workflows/",
            "scripts/ci/",
            "scripts/hooks/"
        ]
        
        for prefix in requiredPrefixes {
            XCTAssertTrue(content.contains("\"\(prefix)\""),
                          "Script must check SSOT prefix: \(prefix)")
        }
    }
    
    func testScriptContainsRequiredPatterns() throws {
        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        
        let requiredPatterns = [
            "Observation",
            "EvidenceEscalation"
        ]
        
        for pattern in requiredPatterns {
            XCTAssertTrue(content.contains(pattern),
                          "Script must check SSOT pattern: \(pattern)")
        }
    }
    
    func testScriptHandlesDeletion() throws {
        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        XCTAssertTrue(content.contains("diff-filter=D") || content.contains("--diff-filter"),
                      "Script must handle deleted files")
    }
    
    func testScriptHandlesMultipleCommits() throws {
        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        XCTAssertTrue(content.contains("rev-list") || content.contains("for commit"),
                      "Script must handle multiple commits in push")
    }
    
    // MARK: - Regex Pattern Tests
    
    func testSSOTChangeRegexWithAnchor() {
        let validFooters = [
            "SSOT-Change: yes",
            "SSOT-Change: no"
        ]
        
        let invalidFooters = [
            "SSOT-Change: yes ",       // trailing space
            "SSOT-Change: yes\t",      // trailing tab
            "SSOT-Change: yes_extra",  // extra content
            "SSOT-Change: YES",        // uppercase
            "SSOT-Change: true",       // wrong value
            " SSOT-Change: yes",       // leading space
            "SSOT-Change:yes",         // missing space
        ]
        
        let pattern = "^SSOT-Change: (yes|no)$"
        
        for footer in validFooters {
            XCTAssertNotNil(footer.range(of: pattern, options: .regularExpression),
                            "Should match valid footer: '\(footer)'")
        }
        
        for footer in invalidFooters {
            XCTAssertNil(footer.range(of: pattern, options: .regularExpression),
                         "Should NOT match invalid footer: '\(footer)'")
        }
    }
    
    // MARK: - Path Prefix Matching Tests
    
    func testPathPrefixMatching() {
        let ssotPrefixes = [
            "Core/Constants/",
            "Core/SSOT/",
            "docs/constitution/",
            ".github/workflows/",
            "scripts/ci/",
            "scripts/hooks/"
        ]
        
        let shouldMatch = [
            "Core/Constants/SSOT.swift",
            "Core/Constants/SubDir/File.swift",
            "Core/SSOT/EvidenceEscalation.swift",
            "docs/constitution/GATES_POLICY.md",
            ".github/workflows/ci.yml",
            "scripts/ci/new_check.sh",
            "scripts/hooks/pre-push"
        ]
        
        let shouldNotMatch = [
            "Core/ConstantsExtra/File.swift",
            "Core/Services/SSOT.swift",
            "docs/constitutionXYZ/File.md",
            ".github/actions/file.yml",
            "scripts/dev/test.sh",
            "App/SomeFile.swift"
        ]
        
        for path in shouldMatch {
            let matches = ssotPrefixes.contains { path.hasPrefix($0) }
            XCTAssertTrue(matches, "Should match SSOT prefix: \(path)")
        }
        
        for path in shouldNotMatch {
            let matches = ssotPrefixes.contains { path.hasPrefix($0) }
            XCTAssertFalse(matches, "Should NOT match SSOT prefix: \(path)")
        }
    }
    
    func testFilePatternMatching() {
        // These patterns are already regex patterns: .* means any char, \\. means literal dot
        let patterns = [
            "Core/Models/Observation.*\\.swift",
            "Core/Models/EvidenceEscalation.*\\.swift"
        ]

        let shouldMatch = [
            "Core/Models/ObservationModel.swift",
            "Core/Models/ObservationTypes.swift",
            "Core/Models/EvidenceEscalationBoundary.swift"
        ]

        let shouldNotMatch = [
            "Core/Models/ObservationHelper.swift.bak",
            "Core/Models/Observation/SubDir.swift",
            "Core/Models/OtherModel.swift"
        ]

        for path in shouldMatch {
            var matched = false
            for pattern in patterns {
                // Patterns are already in regex format, use them directly
                // Replace .* with [^/]* to prevent matching across directories
                let regexPattern = pattern.replacingOccurrences(of: ".*", with: "[^/]*")
                if path.range(of: "^\(regexPattern)$", options: .regularExpression) != nil {
                    matched = true
                    break
                }
            }
            XCTAssertTrue(matched, "Should match pattern: \(path)")
        }

        for path in shouldNotMatch {
            var matched = false
            for pattern in patterns {
                // Patterns are already in regex format, use them directly
                // Replace .* with [^/]* to prevent matching across directories
                let regexPattern = pattern.replacingOccurrences(of: ".*", with: "[^/]*")
                if path.range(of: "^\(regexPattern)$", options: .regularExpression) != nil {
                    matched = true
                    break
                }
            }
            XCTAssertFalse(matched, "Should NOT match pattern: \(path)")
        }
    }
}
