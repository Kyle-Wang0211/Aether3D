// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SwiftSourceScanner.swift
// Aether3D
//
// Minimal Swift lexer for detecting number literals and exemptions.
// v5.1: Fixed isHexDigitChar extension.
//

import Foundation

/// Configuration for scanner
public struct ScannerConfig {
    /// Allow "1" as a magic number (for testing)
    public let allowOne: Bool
    
    /// Strict mode (for production)
    public let strict: Bool
    
    public static let strictForTesting = ScannerConfig(allowOne: false, strict: true)
    public static let lenient = ScannerConfig(allowOne: true, strict: false)
}

/// Extension to check if character is hex digit
extension Character {
    /// Check if character is a hexadecimal digit (v5.1 fix)
    var isHexDigitChar: Bool {
        let lowercased = String(self).lowercased()
        guard lowercased.count == 1, let char = lowercased.first else {
            return false
        }
        return char.isNumber || (char >= "a" && char <= "f")
    }
}

/// Minimal Swift source scanner
public enum SwiftSourceScanner {
    /// Scan for number literals in Swift source
    public static func scanNumberLiterals(
        in content: String,
        config: ScannerConfig = .strictForTesting
    ) -> [(value: String, line: Int, column: Int)] {
        var results: [(value: String, line: Int, column: Int)] = []
        let lines = content.components(separatedBy: .newlines)
        
        for (lineIndex, line) in lines.enumerated() {
            var i = line.startIndex
            while i < line.endIndex {
                // Skip strings
                if line[i] == "\"" {
                    i = skipString(in: line, from: i)
                    continue
                }
                
                // Skip comments
                if i < line.index(before: line.endIndex) && 
                   line[i] == "/" && line[line.index(after: i)] == "/" {
                    break // Rest of line is comment
                }
                
                // Check for number literal
                if line[i].isNumber || (line[i] == "-" && i < line.index(before: line.endIndex) && line[line.index(after: i)].isNumber) {
                    if let (num, endIndex) = parseNumber(in: line, from: i) {
                        // Skip "1" if allowed
                        if config.allowOne && num == "1" {
                            i = endIndex
                            continue
                        }
                        
                        // Skip if part of exemption comment
                        if hasExemptionComment(near: lineIndex, in: lines, column: line.distance(from: line.startIndex, to: i)) {
                            i = endIndex
                            continue
                        }
                        
                        let column = line.distance(from: line.startIndex, to: i)
                        results.append((value: num, line: lineIndex + 1, column: column))
                        i = endIndex
                    } else {
                        i = line.index(after: i)
                    }
                } else {
                    i = line.index(after: i)
                }
            }
        }
        
        return results
    }
    
    /// Skip string literal
    private static func skipString(in line: String, from start: String.Index) -> String.Index {
        var i = line.index(after: start)
        var escaped = false
        
        while i < line.endIndex {
            if escaped {
                escaped = false
                i = line.index(after: i)
                continue
            }
            
            if line[i] == "\\" {
                escaped = true
                i = line.index(after: i)
                continue
            }
            
            if line[i] == "\"" {
                return line.index(after: i)
            }
            
            i = line.index(after: i)
        }
        
        return i
    }
    
    /// Parse number literal
    private static func parseNumber(in line: String, from start: String.Index) -> (String, String.Index)? {
        var i = start
        var num = ""
        
        // Handle negative sign
        if line[i] == "-" {
            num += "-"
            i = line.index(after: i)
            if i >= line.endIndex || !line[i].isNumber {
                return nil
            }
        }
        
        // Parse digits
        while i < line.endIndex && (line[i].isNumber || line[i].isHexDigitChar || line[i] == "." || line[i] == "_" || line[i] == "x" || line[i] == "o" || line[i] == "b") {
            num.append(line[i])
            i = line.index(after: i)
        }
        
        // Parse suffix (e.g., "f", "d", "u", "l")
        if i < line.endIndex {
            let suffix = line[i].lowercased()
            if suffix == "f" || suffix == "d" || suffix == "u" || suffix == "l" {
                num.append(line[i])
                i = line.index(after: i)
            }
        }
        
        return num.isEmpty ? nil : (num, i)
    }
    
    /// Check if there's an exemption comment nearby
    private static func hasExemptionComment(near lineIndex: Int, in lines: [String], column: Int) -> Bool {
        // Check current line
        let line = lines[lineIndex]
        if line.contains("// SSOT_EXEMPTION") || line.contains("// MAGIC_NUMBER_OK") {
            return true
        }
        
        // Check previous line
        if lineIndex > 0 {
            let prevLine = lines[lineIndex - 1]
            if prevLine.contains("// SSOT_EXEMPTION") || prevLine.contains("// MAGIC_NUMBER_OK") {
                return true
            }
        }
        
        return false
    }
}

