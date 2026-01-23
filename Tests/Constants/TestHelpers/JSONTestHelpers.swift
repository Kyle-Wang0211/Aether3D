//
// JSONTestHelpers.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - JSON Test Helpers
//
// This file provides utilities for loading and decoding JSON in tests.
//

import Foundation
import XCTest

/// JSON loading and decoding utilities for tests.
///
/// **Purpose:** Stable, reusable JSON loading for golden vector tests and catalog validation.
/// **Scope:** Test-only, not production code.
public enum JSONTestHelpers {
    
    /// Loads JSON data from test bundle.
    ///
    /// - Parameter filename: JSON filename (e.g., "GOLDEN_VECTORS_ENCODING.json")
    /// - Returns: JSON data
    /// - Throws: Error with filename context if file not found
    public static func loadJSONData(filename: String) throws -> Data {
        // Try multiple paths to find the JSON file
        let fileManager = FileManager.default
        
        // Path 1: Relative to current working directory (for CI/local runs)
        let currentDir = fileManager.currentDirectoryPath
        let relativePath = "\(currentDir)/docs/constitution/constants/\(filename)"
        if fileManager.fileExists(atPath: relativePath) {
            guard let data = fileManager.contents(atPath: relativePath) else {
                throw JSONTestError.fileNotFound(filename: filename, reason: "Could not read file at \(relativePath)")
            }
            return data
        }
        
        // Path 2: Relative to test bundle (for Xcode runs)
        // Use a test class to get the bundle
        let testBundle = Bundle(for: JSONTestHelperClass.self)
        if let bundlePath = testBundle.resourcePath {
            let bundleRelativePath = "\(bundlePath)/../../docs/constitution/constants/\(filename)"
            if fileManager.fileExists(atPath: bundleRelativePath) {
                guard let data = fileManager.contents(atPath: bundleRelativePath) else {
                    throw JSONTestError.fileNotFound(filename: filename, reason: "Could not read file at \(bundleRelativePath)")
                }
                return data
            }
        }
        
        // Path 3: Try absolute path from repo root
        if let repoRoot = findRepoRoot() {
            let absolutePath = "\(repoRoot)/docs/constitution/constants/\(filename)"
            if fileManager.fileExists(atPath: absolutePath) {
                guard let data = fileManager.contents(atPath: absolutePath) else {
                    throw JSONTestError.fileNotFound(filename: filename, reason: "Could not read file at \(absolutePath)")
                }
                return data
            }
        }
        
        throw JSONTestError.fileNotFound(filename: filename, reason: "File not found in any expected location")
    }
    
    /// Finds repository root by looking for .git directory.
    private static func findRepoRoot() -> String? {
        var currentPath = FileManager.default.currentDirectoryPath
        let fileManager = FileManager.default
        
        while !currentPath.isEmpty && currentPath != "/" {
            let gitPath = "\(currentPath)/.git"
            if fileManager.fileExists(atPath: gitPath) {
                return currentPath
            }
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }
        
        return nil
    }
    
    /// Decodes JSON file to specified type.
    ///
    /// - Parameters:
    ///   - filename: JSON filename
    ///   - type: Decodable type
    /// - Returns: Decoded object
    /// - Throws: DecodingError with filename context
    public static func decode<T: Decodable>(filename: String, as type: T.Type) throws -> T {
        let data = try loadJSONData(filename: filename)
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw JSONTestError.decodingFailed(filename: filename, error: error)
        } catch {
            throw JSONTestError.decodingFailed(filename: filename, error: error)
        }
    }
    
    /// Loads JSON as dictionary for flexible validation.
    ///
    /// - Parameter filename: JSON filename
    /// - Returns: Dictionary representation
    /// - Throws: Error if file cannot be loaded or parsed
    public static func loadJSONDictionary(filename: String) throws -> [String: Any] {
        let data = try loadJSONData(filename: filename)
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONTestError.invalidFormat(filename: filename, reason: "Root is not a dictionary")
        }
        
        return json
    }
}

/// Helper class for bundle access (enum cannot be used with Bundle(for:))
private class JSONTestHelperClass {}

/// JSON test errors with filename context.
public enum JSONTestError: Error, CustomStringConvertible {
    case fileNotFound(filename: String, reason: String)
    case decodingFailed(filename: String, error: Error)
    case invalidFormat(filename: String, reason: String)
    
    public var description: String {
        switch self {
        case .fileNotFound(let filename, let reason):
            return "JSONTestError: File '\(filename)' not found. Reason: \(reason)"
        case .decodingFailed(let filename, let error):
            return "JSONTestError: Failed to decode '\(filename)'. Error: \(error.localizedDescription)"
        case .invalidFormat(let filename, let reason):
            return "JSONTestError: Invalid format in '\(filename)'. Reason: \(reason)"
        }
    }
}

/// Hex string utilities for byte comparison in tests.
public enum HexTestHelpers {
    /// Converts Data to lowercase hex string.
    public static func toHex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Converts hex string to Data.
    public static func fromHex(_ hex: String) throws -> Data {
        let hex = hex.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteString = String(hex[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else {
                throw HexTestError.invalidHexString(hex)
            }
            data.append(byte)
            index = nextIndex
        }
        
        return data
    }
    
    /// Compares two Data objects and returns detailed diff message.
    public static func compareBytes(_ expected: Data, _ actual: Data, context: String = "") -> String? {
        guard expected != actual else { return nil }
        
        var message = "Byte mismatch"
        if !context.isEmpty {
            message += " in \(context)"
        }
        message += ":\n"
        message += "Expected: \(toHex(expected))\n"
        message += "Actual:   \(toHex(actual))\n"
        
        if expected.count != actual.count {
            message += "Length mismatch: expected \(expected.count), got \(actual.count)\n"
        } else {
            let firstDiff = zip(expected, actual).enumerated().first { $0.element.0 != $0.element.1 }
            if let (index, (exp, act)) = firstDiff {
                message += "First difference at byte \(index): expected 0x\(String(format: "%02x", exp)), got 0x\(String(format: "%02x", act))"
            }
        }
        
        return message
    }
}

public enum HexTestError: Error {
    case invalidHexString(String)
}
