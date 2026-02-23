// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// APIContractConstantsRegressionTests.swift
// Aether3D
//
// Anti-regression test to prevent reintroducing scattered literals in API Contract files
//

import Foundation
import XCTest
@testable import Aether3DCore

final class APIContractConstantsRegressionTests: XCTestCase {
    func testAPIContractNoScatteredLiterals() {
        guard let apiContractFile = RepoRootLocator.resolvePath("Core/Network/APIContract.swift") else {
            XCTFail("APIContract.swift must exist")
            return
        }
        
        guard let content = try? String(contentsOf: apiContractFile) else {
            XCTFail("Could not read APIContract.swift")
            return
        }
        
        let lines = content.components(separatedBy: "\n")
        var violations: [String] = []
        
        // Patterns that should use APIContractConstants instead
        let forbiddenPatterns: [(pattern: String, description: String)] = [
            (pattern: "\"true\"", description: "JSON boolean true literal"),
            (pattern: "\"false\"", description: "JSON boolean false literal"),
            (pattern: "\"null\"", description: "JSON null literal"),
            (pattern: "\"{\"", description: "JSON object open brace"),
            (pattern: "\"}\"", description: "JSON object close brace"),
            (pattern: "\"[\"", description: "JSON array open bracket"),
            (pattern: "\"]\"", description: "JSON array close bracket"),
            (pattern: "\":\"", description: "JSON key-value separator"),
            (pattern: "\",\"", description: "JSON element separator"),
            (pattern: "\"\\\"\"", description: "JSON quote character"),
            (pattern: "\"\\\\\\\"\"", description: "JSON escaped quote"),
            (pattern: "%02x", description: "Hex byte format string"),
            (pattern: "%.15g", description: "Float format string"),
            (pattern: "\\\\u%04X", description: "Unicode escape format"),
            (pattern: "0x22", description: "Unicode double quote scalar"),
            (pattern: "0x5C", description: "Unicode backslash scalar"),
            (pattern: "0x08", description: "Unicode backspace scalar"),
            (pattern: "0x0C", description: "Unicode form feed scalar"),
            (pattern: "0x0A", description: "Unicode newline scalar"),
            (pattern: "0x0D", description: "Unicode carriage return scalar"),
            (pattern: "0x09", description: "Unicode tab scalar"),
            (pattern: "0x20", description: "Unicode control threshold"),
            (pattern: "\"c\"", description: "ObjC type char marker"),
            (pattern: "== 200", description: "HTTP success code start"),
            (pattern: "< 300", description: "HTTP success code end"),
            (pattern: " / 60", description: "Seconds per minute divisor"),
            (pattern: " * 60", description: "Seconds per minute multiplier"),
        ]
        
        for (lineIndex, line) in lines.enumerated() {
            // Skip comments and strings that are part of documentation
            if line.trimmingCharacters(in: CharacterSet.whitespaces).hasPrefix("//") {
                continue
            }
            
            // Skip lines that already reference APIContractConstants
            if line.contains("APIContractConstants.") {
                continue
            }
            
            // Check for forbidden patterns
            for (pattern, description) in forbiddenPatterns {
                if line.contains(pattern) && !line.contains("APIContractConstants") {
                    // Allow if it's in a comment explaining the constant
                    if line.contains("//") && (line.contains("constant") || line.contains("Constant")) {
                        continue
                    }
                    
                    violations.append("Line \(lineIndex + 1): Found \(description) '\(pattern)' - use APIContractConstants instead")
                }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Scattered literals found in APIContract.swift:\n" + violations.joined(separator: "\n"))
    }
    
    func testAPIErrorNoScatteredLiterals() {
        guard let apiErrorFile = RepoRootLocator.resolvePath("Core/Network/APIError.swift") else {
            XCTFail("APIError.swift must exist")
            return
        }
        
        guard let content = try? String(contentsOf: apiErrorFile) else {
            XCTFail("Could not read APIError.swift")
            return
        }
        
        let lines = content.components(separatedBy: "\n")
        var violations: [String] = []
        
        // Patterns that should use APIContractConstants instead
        let forbiddenPatterns: [(pattern: String, description: String)] = [
            (pattern: ">= 200", description: "HTTP success code start"),
            (pattern: "< 300", description: "HTTP success code end"),
        ]
        
        for (lineIndex, line) in lines.enumerated() {
            // Skip comments
            if line.trimmingCharacters(in: CharacterSet.whitespaces).hasPrefix("//") {
                continue
            }
            
            // Skip lines that already reference APIContractConstants
            if line.contains("APIContractConstants.") {
                continue
            }
            
            // Skip enum raw values (e.g., case ok = 200)
            if line.contains("case ") && line.contains(" = ") {
                continue
            }
            
            // Check for forbidden patterns
            for (pattern, description) in forbiddenPatterns {
                if line.contains(pattern) && !line.contains("APIContractConstants") {
                    violations.append("Line \(lineIndex + 1): Found \(description) '\(pattern)' - use APIContractConstants instead")
                }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Scattered literals found in APIError.swift:\n" + violations.joined(separator: "\n"))
    }
    
    // MARK: - Scanner Behavior Regression Tests
    
    func testScannerCatchesTypeScopeConstants() {
        // Test that type-scope constants (e.g., in extensions) are caught
        let testLines = [
            "extension SomeType {",
            "    static let badConstant = 60",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertFalse(violations.isEmpty, "Scanner should catch type-scope constant 'static let badConstant = 60'. Violations: \(violations)")
        XCTAssertTrue(violations.joined().contains("badConstant") || violations.joined().contains("TestFile.swift:2"), 
                     "Violation should mention 'badConstant' or line 2. Violations: \(violations)")
    }
    
    func testScannerIgnoresFunctionScopeLocals() {
        // Test that local variables inside functions are NOT caught
        let testLines = [
            "func someFunction() {",
            "    let localVar = 60",
            "    let anotherLocal = \"test\"",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertTrue(violations.isEmpty, "Scanner should NOT catch local variables inside function bodies")
    }
    
    func testScannerCatchesTopLevelConstants() {
        // Test that top-level constants are caught
        let testLines = [
            "let topLevelConstant = 60",
            "static let anotherTopLevel = \"test\""
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertFalse(violations.isEmpty, "Scanner should catch top-level constants. Violations: \(violations)")
        let violationsText = violations.joined()
        XCTAssertTrue(violationsText.contains("topLevelConstant") || violationsText.contains("anotherTopLevel") || 
                     violationsText.contains("TestFile.swift:1") || violationsText.contains("TestFile.swift:2"),
                     "Violation should mention the constant or line number. Violations: \(violations)")
    }
    
    // MARK: - Comprehensive Scanner Hardening Tests
    
    func testScannerCatchesNestedTypeConstants() {
        // Test that constants in nested types (braceDepth > 1) are caught
        let testLines = [
            "struct Outer {",
            "    struct Inner {",
            "        static let nestedConstant = 60",
            "    }",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertFalse(violations.isEmpty, "Scanner should catch nested-type constant at braceDepth > 1. Violations: \(violations)")
        XCTAssertTrue(violations.joined().contains("nestedConstant") || violations.joined().contains("TestFile.swift:3"),
                     "Violation should mention 'nestedConstant' or line 3. Violations: \(violations)")
    }
    
    func testScannerIgnoresFunctionLocalsWithBracesInStrings() {
        // Test that function locals are ignored even when braces appear in strings/comments
        let testLines = [
            "func someFunction() {",
            "    let localVar = 60",
            "    let str = \"} // this brace should be ignored\"",
            "    // } this brace in comment should be ignored",
            "    let anotherLocal = \"test\"",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertTrue(violations.isEmpty, "Scanner should NOT catch local variables even with braces in strings/comments. Violations: \(violations)")
    }
    
    func testScannerIgnoresClosureLocals() {
        // Test that closure locals are ignored
        let testLines = [
            "static let x = {",
            "    let tmp = 1",
            "    return tmp",
            "}()"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertTrue(violations.isEmpty, "Scanner should NOT catch closure locals. Violations: \(violations)")
    }
    
    func testScannerIgnoresAccessorLocals() {
        // Test that accessor locals are ignored
        let testLines = [
            "var x: Int {",
            "    get {",
            "        let t = 1",
            "        return t",
            "    }",
            "    set {",
            "        let newValue = newValue",
            "    }",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertTrue(violations.isEmpty, "Scanner should NOT catch accessor locals. Violations: \(violations)")
    }
    
    func testScannerHandlesBracesInCommentsAndStrings() {
        // Test that braces in comments/strings do NOT affect detection
        let testLines = [
            "// This is a comment with { and }",
            "let constant1 = \"string with { and }\"",
            "struct Test {",
            "    static let goodConstant = 60  // } this should not affect",
            "    // { this should not affect",
            "    let str = \"} // { should be ignored\"",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        // Should catch goodConstant (type-scope constant) but NOT the braces in comments/strings
        XCTAssertFalse(violations.isEmpty, "Scanner should catch type-scope constant. Violations: \(violations)")
        XCTAssertTrue(violations.joined().contains("goodConstant") || violations.joined().contains("TestFile.swift:4"),
                     "Violation should mention 'goodConstant' or line 4. Violations: \(violations)")
    }
    
    func testScannerCatchesConstantsInNestedExtensions() {
        // Test that constants in nested extensions are caught
        let testLines = [
            "extension Outer {",
            "    extension Inner {",
            "        static let extensionConstant = 60",
            "    }",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertFalse(violations.isEmpty, "Scanner should catch constants in nested extensions. Violations: \(violations)")
        XCTAssertTrue(violations.joined().contains("extensionConstant") || violations.joined().contains("TestFile.swift:3"),
                     "Violation should mention 'extensionConstant' or line 3. Violations: \(violations)")
    }
    
    func testScannerIgnoresWillSetDidSetLocals() {
        // Test that willSet/didSet locals are ignored
        let testLines = [
            "var property: Int {",
            "    willSet {",
            "        let old = property",
            "    }",
            "    didSet {",
            "        let new = property",
            "    }",
            "}"
        ]
        
        let violations = ScatteredConstantScanTests.scanLinesForScatteredConstants(testLines, fileName: "TestFile.swift")
        
        XCTAssertTrue(violations.isEmpty, "Scanner should NOT catch willSet/didSet locals. Violations: \(violations)")
    }
}
