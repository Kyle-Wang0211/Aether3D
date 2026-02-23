// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FixtureLoader.swift
// Aether3D
//
// PR1 v2.4 Addendum - Fixture Loading Utilities
//
// Single source of truth for loading fixtures with header validation
//

import Foundation

/// Fixture loader with header validation
public struct FixtureLoader {
    /// Load fixture lines (LF only, excludes header)
    /// 
    /// **Process:**
    /// 1. Read file
    /// 2. Validate header
    /// 3. Return content lines (excluding header)
    /// 
    /// **Line endings:** Normalized to LF
    public static func loadFixtureLines(path: String) throws -> [String] {
        let fileURL = URL(fileURLWithPath: path)
        
        // Validate header first
        try FixtureHeader.validateFixtureHeader(fileURL: fileURL)
        
        // Read content
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw FixtureLoaderError.invalidEncoding(path)
        }
        
        // Split by LF (normalize CRLF to LF)
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        
        // Skip header line (first line)
        guard lines.count > 0 else {
            throw FixtureLoaderError.emptyFile(path)
        }
        
        return Array(lines.dropFirst())
    }
    
    /// Load hex bytes fixture
    /// 
    /// **Format:** Each line contains hex string (whitespace ignored)
    /// **Validation:**
    /// - Rejects non-hex characters
    /// - Rejects odd-length hex strings
    /// - Allows whitespace (stripped)
    /// 
    /// **Returns:** Concatenated hex bytes as Data
    public static func loadHexBytesFixture(path: String) throws -> Data {
        let lines = try loadFixtureLines(path: path)
        
        var hexString = ""
        for line in lines {
            // Strip whitespace
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty || cleaned.hasPrefix("#") {
                continue // Skip empty lines and comments
            }
            
            // Extract hex part (may have format like "KEY=hexvalue" or just "hexvalue")
            let hexPart: String
            if let eqIndex = cleaned.firstIndex(of: "=") {
                hexPart = String(cleaned[cleaned.index(after: eqIndex)...])
            } else {
                hexPart = cleaned
            }
            
            let stripped = hexPart.replacingOccurrences(of: " ", with: "")
            
            // Validate hex
            guard stripped.allSatisfy({ $0.isHexDigit }) else {
                throw FixtureLoaderError.invalidHex(path, line: cleaned)
            }
            
            guard stripped.count % 2 == 0 else {
                throw FixtureLoaderError.oddLengthHex(path, line: cleaned)
            }
            
            hexString += stripped
        }
        
        // Convert hex string to Data
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                throw FixtureLoaderError.invalidHex(path, line: hexString)
            }
            data.append(byte)
            index = nextIndex
        }
        
        return data
    }
    
    /// Load fixture from test bundle (iOS/macOS)
    /// 
    /// **Usage:** For Xcode test bundles
    public static func loadFixtureFromBundle(bundle: Bundle, name: String, extension ext: String) throws -> [String] {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw FixtureLoaderError.fileNotFound("\(name).\(ext)")
        }
        return try loadFixtureLines(path: url.path)
    }
    
    /// Load hex bytes from test bundle
    public static func loadHexBytesFromBundle(bundle: Bundle, name: String, extension ext: String) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw FixtureLoaderError.fileNotFound("\(name).\(ext)")
        }
        return try loadHexBytesFixture(path: url.path)
    }
}

/// Fixture loader errors
public enum FixtureLoaderError: Error, CustomStringConvertible {
    case invalidEncoding(String)
    case emptyFile(String)
    case invalidHex(String, line: String)
    case oddLengthHex(String, line: String)
    case fileNotFound(String)
    
    public var description: String {
        switch self {
        case .invalidEncoding(let path):
            return "FixtureLoader: Invalid UTF-8 encoding in \(path)"
        case .emptyFile(let path):
            return "FixtureLoader: Empty file \(path)"
        case .invalidHex(let path, let line):
            return "FixtureLoader: Invalid hex in \(path), line: \(line)"
        case .oddLengthHex(let path, let line):
            return "FixtureLoader: Odd-length hex in \(path), line: \(line)"
        case .fileNotFound(let name):
            return "FixtureLoader: File not found: \(name)"
        }
    }
}

// Helper extension for hex digit check (shared across test support files)
extension Character {
    var isHexDigit: Bool {
        return ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
