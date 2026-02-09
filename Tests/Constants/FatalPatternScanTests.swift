// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FatalPatternScanTests.swift
// Aether3D
//
// Tests for prohibited fatal/precondition/assert patterns.
// PATCH E: Extended to include precondition/assert.
//

import XCTest
@testable import Aether3DCore

final class FatalPatternScanTests: XCTestCase {
    func testNoFatalErrorInConstantsDirectory() {
        let constantsDir = RepoRootLocator.resolvePath("Core/Constants")
        XCTAssertNotNil(constantsDir, "Could not locate Core/Constants directory")
        
        guard let dir = constantsDir else { return }
        
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("Could not read Constants directory")
            return
        }
        
        var violations: [String] = []
        
        for file in files where file.pathExtension == "swift" {
            guard let content = try? String(contentsOf: file) else { continue }
            
            let patterns = ProhibitionScanner.scanFatalPatterns(in: content)
            for pattern in patterns {
                let msg = TestFailureFormatter.formatProhibitionViolation(
                    pattern: pattern.pattern,
                    file: file.lastPathComponent,
                    line: pattern.line,
                    reason: "fatalError/preconditionFailure/assertionFailure/precondition/assert are prohibited in Core/Constants/"
                )
                violations.append(msg)
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Fatal pattern violations found:\n" + violations.joined(separator: "\n"))
    }
    
    func testNoFatalErrorWithoutBindingInCore() {
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
            
            // Skip Constants directory (tested separately)
            if file.path.contains("/Constants/") {
                continue
            }

            // Skip Pipeline directory (existing code, not part of SSOT Phase 1)
            if file.path.contains("/Pipeline/") {
                continue
            }

            // Skip Quality directory (existing code, not part of SSOT Phase 1)
            if file.path.contains("/Quality/") {
                continue
            }

            // Skip Infrastructure directory (existing code, not part of SSOT Phase 1)
            if file.path.contains("/Infrastructure/") {
                continue
            }

            // Skip Evidence directory (PR2 code with debug-only fatalError in invariants)
            if file.path.contains("/Evidence/") {
                continue
            }
            
            guard let content = try? String(contentsOf: file) else { continue }
            
            let lines = content.components(separatedBy: .newlines)
            for (lineIndex, line) in lines.enumerated() {
            // Skip comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") {
                continue
            }
            
            // Check if pattern is in a comment (after //)
            let codePart = line.components(separatedBy: "//").first ?? line
            
            // Check for fatal patterns
            let fatalPatterns = ["fatalError", "preconditionFailure", "assertionFailure"]
            for pattern in fatalPatterns {
                if codePart.contains(pattern) {
                    // Check if it's properly bound (e.g., in a guard statement or function)
                    let hasBinding = codePart.contains("guard") || 
                                    codePart.contains("if") || 
                                    codePart.contains("else") ||
                                    codePart.contains("return") ||
                                    codePart.contains("throw")
                    
                    if !hasBinding {
                        let msg = TestFailureFormatter.formatProhibitionViolation(
                            pattern: pattern,
                            file: file.lastPathComponent,
                            line: lineIndex + 1,
                            reason: "fatalError/preconditionFailure/assertionFailure must be properly bound in Core/"
                        )
                        violations.append(msg)
                    }
                }
            }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Unbound fatal pattern violations found:\n" + violations.joined(separator: "\n"))
    }
}

