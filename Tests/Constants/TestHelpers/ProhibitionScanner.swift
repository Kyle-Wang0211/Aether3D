//
// ProhibitionScanner.swift
// Aether3D
//
// Scanner for prohibited patterns in Swift source.
//

import Foundation

/// Scanner for prohibited code patterns
public enum ProhibitionScanner {
    /// Scan for fatalError/preconditionFailure/assertionFailure/precondition/assert
    public static func scanFatalPatterns(in content: String) -> [(pattern: String, line: Int)] {
        var results: [(pattern: String, line: Int)] = []
        let lines = content.components(separatedBy: .newlines)
        
        let patterns = [
            "fatalError",
            "preconditionFailure",
            "assertionFailure",
            "precondition(",
            "assert("
        ]
        
        for (lineIndex, line) in lines.enumerated() {
            // Skip comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") {
                continue
            }
            
            // Check if pattern is in a comment (after //)
            let codePart = line.components(separatedBy: "//").first ?? line
            
            for pattern in patterns {
                if codePart.contains(pattern) {
                    // Check for exemption
                    if !line.contains("// SSOT_EXEMPTION") && 
                       !line.contains("// FATAL_OK") {
                        results.append((pattern: pattern, line: lineIndex + 1))
                    }
                }
            }
        }
        
        return results
    }
    
    /// Scan for direct clamp patterns (e.g., min(max(...)))
    public static func scanClampPatterns(in content: String) -> [(line: Int, column: Int)] {
        var results: [(line: Int, column: Int)] = []
        let lines = content.components(separatedBy: .newlines)
        
        for (lineIndex, line) in lines.enumerated() {
            if line.contains("min(") || line.contains("max(") {
                // Check if it's a clamp pattern
                if (line.contains("min(") && line.contains("max(")) ||
                   (line.contains("Swift.min") || line.contains("Swift.max")) {
                    // Check for exemption
                    if !line.contains("// SSOT_EXEMPTION") && 
                       !line.contains("// CLAMP_OK") {
                        let column = line.range(of: "min(")?.lowerBound ?? line.range(of: "max(")?.lowerBound ?? line.startIndex
                        let col = line.distance(from: line.startIndex, to: column)
                        results.append((line: lineIndex + 1, column: col))
                    }
                }
            }
        }
        
        return results
    }
    
    /// Scan for throw statements not using SSOTError
    public static func scanThrowPatterns(in content: String) -> [Int] {
        var results: [Int] = []
        let lines = content.components(separatedBy: .newlines)
        
        for (lineIndex, line) in lines.enumerated() {
            if line.contains("throw ") && !line.contains("SSOTError") {
                // Check for exemption
                if !line.contains("// SSOT_EXEMPTION") && 
                   !line.contains("// THROW_OK") {
                    results.append(lineIndex + 1)
                }
            }
        }
        
        return results
    }
    
    /// Scan for print() statements
    public static func scanPrintStatements(in content: String) -> [Int] {
        var results: [Int] = []
        let lines = content.components(separatedBy: .newlines)
        
        for (lineIndex, line) in lines.enumerated() {
            if line.contains("print(") && !line.contains("// SSOT_EXEMPTION") && !line.contains("// PRINT_OK") {
                results.append(lineIndex + 1)
            }
        }
        
        return results
    }
    
    /// Scan for UserDefaults/remote config usage
    public static func scanConfigSourcePatterns(in content: String) -> [(pattern: String, line: Int)] {
        var results: [(pattern: String, line: Int)] = []
        let lines = content.components(separatedBy: .newlines)
        
        let patterns = [
            "UserDefaults",
            "remoteConfig",
            "RemoteConfig"
        ]
        
        for (lineIndex, line) in lines.enumerated() {
            for pattern in patterns {
                if line.contains(pattern) && !line.contains("// SSOT_EXEMPTION") {
                    results.append((pattern: pattern, line: lineIndex + 1))
                }
            }
        }
        
        return results
    }
    
    /// Scan for Date() or UUID() usage (non-deterministic)
    public static func scanNonDeterministicPatterns(in content: String) -> [(pattern: String, line: Int)] {
        var results: [(pattern: String, line: Int)] = []
        let lines = content.components(separatedBy: .newlines)
        
        let patterns = [
            "Date()",
            "UUID()"
        ]
        
        for (lineIndex, line) in lines.enumerated() {
            for pattern in patterns {
                if line.contains(pattern) && !line.contains("// SSOT_EXEMPTION") {
                    results.append((pattern: pattern, line: lineIndex + 1))
                }
            }
        }
        
        return results
    }
    
    /// Scan for var/lazy/global declarations in Constants/
    public static func scanDeclarationPatterns(in content: String) -> [(pattern: String, line: Int)] {
        var results: [(pattern: String, line: Int)] = []
        let lines = content.components(separatedBy: .newlines)
        
        let patterns = [
            "var ",
            "lazy var",
            "static var"
        ]
        
        for (lineIndex, line) in lines.enumerated() {
            for pattern in patterns {
                if line.contains(pattern) && !line.contains("// SSOT_EXEMPTION") {
                    results.append((pattern: pattern, line: lineIndex + 1))
                }
            }
        }
        
        return results
    }
    
    /// Scan for #if DEBUG changing thresholds
    public static func scanConditionalCompilationPatterns(in content: String) -> [Int] {
        var results: [Int] = []
        let lines = content.components(separatedBy: .newlines)
        
        var inDebugBlock = false
        for (lineIndex, line) in lines.enumerated() {
            if line.contains("#if DEBUG") {
                inDebugBlock = true
            } else if line.contains("#endif") {
                inDebugBlock = false
            } else if inDebugBlock {
                // Check if line modifies a threshold
                if line.contains("Threshold") || line.contains("Constant") {
                    if !line.contains("// SSOT_EXEMPTION") {
                        results.append(lineIndex + 1)
                    }
                }
            }
        }
        
        return results
    }
}

