// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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
    /// Strips comments and string literals from code for brace depth calculation
    private static func stripCommentsAndStrings(_ content: String) -> String {
        var result = ""
        var i = content.startIndex
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var inMultilineString = false
        var escapeNext = false
        var multilineStringDelimiterCount = 0
        
        while i < content.endIndex {
            let char = content[i]
            let nextIndex = content.index(after: i)
            let nextChar = nextIndex < content.endIndex ? content[nextIndex] : nil
            
            if escapeNext {
                result.append(char)
                escapeNext = false
                i = nextIndex
                continue
            }
            
            // Handle escape sequences in strings
            if (inString || inMultilineString) && char == "\\" {
                escapeNext = true
                result.append(char)
                i = nextIndex
                continue
            }
            
            // Line comment
            if !inString && !inMultilineString && !inBlockComment && char == "/" && nextChar == "/" {
                inLineComment = true
                i = content.index(i, offsetBy: 2)
                continue
            }
            
            // Block comment start
            if !inString && !inMultilineString && !inLineComment && char == "/" && nextChar == "*" {
                inBlockComment = true
                i = content.index(i, offsetBy: 2)
                continue
            }
            
            // Block comment end
            if inBlockComment && char == "*" && nextChar == "/" {
                inBlockComment = false
                i = content.index(i, offsetBy: 2)
                continue
            }
            
            // Multiline string start
            if !inString && !inMultilineString && !inLineComment && !inBlockComment {
                if char == "\"" {
                    var j = nextIndex
                    var quoteCount = 1
                    while j < content.endIndex && content[j] == "\"" {
                        quoteCount += 1
                        j = content.index(after: j)
                    }
                    if quoteCount >= 3 {
                        inMultilineString = true
                        multilineStringDelimiterCount = quoteCount
                        i = j
                        continue
                    }
                }
            }
            
            // Multiline string end
            if inMultilineString {
                if char == "\"" {
                    var j = nextIndex
                    var quoteCount = 1
                    while j < content.endIndex && content[j] == "\"" {
                        quoteCount += 1
                        j = content.index(after: j)
                    }
                    if quoteCount >= multilineStringDelimiterCount {
                        inMultilineString = false
                        multilineStringDelimiterCount = 0
                        i = j
                        continue
                    }
                }
                i = nextIndex
                continue
            }
            
            // Regular string start/end
            if !inLineComment && !inBlockComment && !inMultilineString && char == "\"" {
                inString.toggle()
                i = nextIndex
                continue
            }
            
            // Newline ends line comment
            if inLineComment && char == "\n" {
                inLineComment = false
            }
            
            // Only append if not in comment or string
            if !inLineComment && !inBlockComment && !inString && !inMultilineString {
                result.append(char)
            }
            
            i = nextIndex
        }
        
        return result
    }
    
    /// Helper function to scan lines for scattered constants (for testing)
    static func scanLinesForScatteredConstants(_ lines: [String], fileName: String = "TestFile.swift") -> [String] {
        var violations: [String] = []
        
        // Join lines and strip comments/strings for brace depth calculation
        let fullContent = lines.joined(separator: "\n")
        let strippedContent = stripCommentsAndStrings(fullContent)
        let strippedLines = strippedContent.components(separatedBy: .newlines)
        
        var braceDepth = 0
        var inLocalScope = false
        var localScopeEntryDepth = -1
        var recentLocalScopeKeywords: [String] = []
        
        for (lineIndex, originalLine) in lines.enumerated() {
            let trimmed = originalLine.trimmingCharacters(in: .whitespaces)
            let strippedLine = lineIndex < strippedLines.count ? strippedLines[lineIndex] : ""
            
            // Check for local scope keywords (functions, accessors, closures, computed properties)
            // Computed properties: var/let name: Type { ... }
            let isComputedProperty = (trimmed.hasPrefix("var ") || trimmed.hasPrefix("let ")) &&
                                     trimmed.contains(":") && trimmed.contains("{")
            
            let hasLocalScopeKeyword = isComputedProperty ||
                                      trimmed.contains("func ") ||
                                      trimmed.contains("init(") ||
                                      trimmed.contains("deinit") ||
                                      trimmed.contains("subscript") ||
                                      trimmed.hasPrefix("get {") ||
                                      trimmed.hasPrefix("set {") ||
                                      trimmed.hasPrefix("willSet {") ||
                                      trimmed.hasPrefix("didSet {") ||
                                      trimmed.contains(" get {") ||
                                      trimmed.contains(" set {") ||
                                      trimmed.contains(" willSet {") ||
                                      trimmed.contains(" didSet {") ||
                                      (trimmed.contains("->") && !trimmed.contains("{")) ||
                                      trimmed.contains("= {") ||
                                      trimmed.contains(" in {")
            
            if hasLocalScopeKeyword {
                recentLocalScopeKeywords.append(trimmed)
                if recentLocalScopeKeywords.count > 3 {
                    recentLocalScopeKeywords.removeFirst()
                }
            }
            
            // Track brace depth from stripped code
            var openBraces = 0
            var closeBraces = 0
            for char in strippedLine {
                if char == "{" {
                    openBraces += 1
                    braceDepth += 1
                    
                    // Check if entering local scope
                    if !inLocalScope {
                        let lineBeforeBrace = String(originalLine[..<(originalLine.firstIndex(of: "{") ?? originalLine.endIndex)])
                        let trimmedBeforeBrace = lineBeforeBrace.trimmingCharacters(in: .whitespaces)
                        // Check for computed property: var/let name: Type {
                        let isComputedProp = (trimmedBeforeBrace.hasPrefix("var ") || trimmedBeforeBrace.hasPrefix("let ")) &&
                                            trimmedBeforeBrace.contains(":") && trimmedBeforeBrace.contains("{")
                        
                        let hasLocalPattern = isComputedProp ||
                                            trimmedBeforeBrace.contains("func ") ||
                                            trimmedBeforeBrace.contains("init(") ||
                                            trimmedBeforeBrace.contains("deinit") ||
                                            trimmedBeforeBrace.contains("subscript") ||
                                            trimmedBeforeBrace.hasPrefix("get {") ||
                                            trimmedBeforeBrace.hasPrefix("set {") ||
                                            trimmedBeforeBrace.hasPrefix("willSet {") ||
                                            trimmedBeforeBrace.hasPrefix("didSet {") ||
                                            trimmedBeforeBrace.contains(" get {") ||
                                            trimmedBeforeBrace.contains(" set {") ||
                                            trimmedBeforeBrace.contains(" willSet {") ||
                                            trimmedBeforeBrace.contains(" didSet {") ||
                                            (trimmedBeforeBrace.contains("->") && trimmedBeforeBrace.contains("{")) ||
                                            trimmedBeforeBrace.contains("= {") ||
                                            trimmedBeforeBrace.contains(" in {")
                        
                        let recentHasLocal = recentLocalScopeKeywords.contains { keyword in
                            let kwTrimmed = keyword.trimmingCharacters(in: .whitespaces)
                            let isCompProp = (kwTrimmed.hasPrefix("var ") || kwTrimmed.hasPrefix("let ")) &&
                                            kwTrimmed.contains(":") && kwTrimmed.contains("{")
                            return isCompProp ||
                                   kwTrimmed.contains("func ") || kwTrimmed.contains("init(") ||
                                   kwTrimmed.contains("deinit") || kwTrimmed.contains("subscript") ||
                                   kwTrimmed.hasPrefix("get {") || kwTrimmed.hasPrefix("set {") ||
                                   kwTrimmed.hasPrefix("willSet {") || kwTrimmed.hasPrefix("didSet {") ||
                                   kwTrimmed.contains(" get {") || kwTrimmed.contains(" set {") ||
                                   kwTrimmed.contains(" willSet {") || kwTrimmed.contains(" didSet {") ||
                                   kwTrimmed.contains("= {") || kwTrimmed.contains(" in {")
                        }
                        
                        if hasLocalPattern || recentHasLocal {
                            inLocalScope = true
                            localScopeEntryDepth = braceDepth - 1
                            recentLocalScopeKeywords.removeAll()
                        }
                    }
                } else if char == "}" {
                    closeBraces += 1
                    braceDepth -= 1
                    
                    // Check if exiting local scope
                    if inLocalScope && braceDepth <= localScopeEntryDepth {
                        inLocalScope = false
                        localScopeEntryDepth = -1
                    }
                }
            }
            
            // Clear recent keywords if we processed braces
            if openBraces > 0 || closeBraces > 0 {
                recentLocalScopeKeywords.removeAll()
            }
            
            // Skip scanning if we're inside a local scope
            if inLocalScope {
                continue
            }
            
            // Check for static let or let declarations that look like constants
            // Scan at ANY nesting depth when NOT in local scope
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
                            file: fileName,
                            line: lineIndex + 1,
                            reason: "Constants should be defined in Core/Constants/, not scattered in other directories"
                        )
                        violations.append(msg)
                    }
                }
            }
        }
        
        return violations
    }
    
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
               file.path.contains("/Utils/") ||
               file.path.contains("/Quality/") ||
               file.path.contains("/Evidence/") ||
               file.path.contains("/Jobs/") ||
               file.path.contains("/Network/") ||
               file.path.contains("/PIZ/") ||
               file.path.contains("/SSOT/") ||
               file.path.contains("/Upload/") ||
               file.path.contains("/Time/") ||
               file.path.contains("/TimeAnchoring/") ||
               file.path.contains("/Persistence/") ||
               file.path.contains("/MerkleTree/") ||
               file.path.contains("/Attestation/") ||
               file.path.contains("/DeviceAttestation/") ||
               file.path.contains("/FormatBridge/") ||
               file.path.contains("/Compliance/") ||
               file.path.contains("/TSDF/") {
                continue
            }
            
            guard let content = try? String(contentsOf: file) else { continue }
            
            let lines = content.components(separatedBy: .newlines)
            let fileViolations = Self.scanLinesForScatteredConstants(lines, fileName: file.lastPathComponent)
            violations.append(contentsOf: fileViolations)
        }
        
        XCTAssertTrue(violations.isEmpty, "Scattered constant violations found:\n" + violations.joined(separator: "\n"))
    }
}
