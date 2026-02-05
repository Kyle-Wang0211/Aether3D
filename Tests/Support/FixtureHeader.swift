//
// FixtureHeader.swift
// Aether3D
//
// PR1 v2.4 Addendum - Fixture Header Validation
//
// Validates fixture file headers: # v=1 sha256=<hex> len=<decimal>
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Fixture header parser and validator
public struct FixtureHeader {
    /// Parse header line: # v=1 sha256=<hex> len=<decimal>
    /// 
    /// **Format:**
    /// - First line must start with `#`
    /// - Contains `v=<version>`
    /// - Contains `sha256=<64-char-hex>`
    /// - Contains `len=<decimal>`
    /// 
    /// **Example:** `# v=1 sha256=abc123... len=1024`
    public static func parseHeader(_ line: String) throws -> (version: Int, sha256Hex: String, len: Int) {
        guard line.hasPrefix("#") else {
            throw FixtureHeaderError.invalidFormat("Header must start with #")
        }
        
        let content = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        var version: Int?
        var sha256Hex: String?
        var len: Int?
        
        // Parse key=value pairs
        let parts = content.split(separator: " ")
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            
            let key = String(kv[0])
            let value = String(kv[1])
            
            switch key {
            case "v":
                version = Int(value)
            case "sha256":
                sha256Hex = value
                // Validate hex format (64 chars, lowercase)
                guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
                    throw FixtureHeaderError.invalidFormat("sha256 must be 64 hex characters, got: \(value)")
                }
            case "len":
                len = Int(value)
            default:
                break
            }
        }
        
        guard let v = version, let sha = sha256Hex, let l = len else {
            throw FixtureHeaderError.invalidFormat("Missing required fields: v, sha256, or len")
        }
        
        return (version: v, sha256Hex: sha, len: l)
    }
    
    /// Compute SHA256 hash of data
    /// 
    /// **Cross-platform:** Uses CryptoKit (macOS/iOS) or Crypto (Linux)
    public static func computeSHA256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let hash = CryptoKit.SHA256.hash(data: data)
        #elseif canImport(Crypto)
        let hash = Crypto.SHA256.hash(data: data)
        #else
        #error("No SHA256 implementation available")
        #endif
        
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Validate fixture file header
    /// 
    /// **Process:**
    /// 1. Read first line (header)
    /// 2. Parse header fields
    /// 3. Read remaining content (excluding header line)
    /// 4. Compute SHA256 of content bytes
    /// 5. Compare computed hash to header hash
    /// 6. Compare content length to header len
    /// 
    /// **Line endings:** Content includes trailing newline (LF only)
    public static func validateFixtureHeader(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw FixtureHeaderError.invalidFormat("File is not valid UTF-8")
        }
        
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else {
            throw FixtureHeaderError.invalidFormat("File is empty")
        }
        
        let headerLine = lines[0]
        let (_, expectedSHA256, expectedLen) = try parseHeader(headerLine)
        
        // Reconstruct content without header
        // Note: components(separatedBy: "\n") on "a\nb\n" produces ["a", "b", ""]
        // So joined(separator: "\n") produces "a\nb\n" (the empty string adds trailing newline)
        // We don't add extra "\n" because joined already restores it
        let contentLines = Array(lines.dropFirst())
        let contentString = contentLines.joined(separator: "\n")
        let contentBytes = Data(contentString.utf8)
        
        // Compute actual hash
        let actualSHA256 = computeSHA256(contentBytes)
        let actualLen = contentBytes.count
        
        // Validate
        guard actualSHA256 == expectedSHA256 else {
            throw FixtureHeaderError.hashMismatch(
                expected: expectedSHA256,
                actual: actualSHA256,
                file: fileURL.lastPathComponent
            )
        }
        
        guard actualLen == expectedLen else {
            throw FixtureHeaderError.lengthMismatch(
                expected: expectedLen,
                actual: actualLen,
                file: fileURL.lastPathComponent
            )
        }
    }
    
    /// Generate header line for content
    /// 
    /// **Usage:** Write header, then write content
    public static func generateHeader(version: Int, contentBytes: Data) -> String {
        let sha256 = computeSHA256(contentBytes)
        let len = contentBytes.count
        return "# v=\(version) sha256=\(sha256) len=\(len)\n"
    }
}

/// Fixture header errors
public enum FixtureHeaderError: Error, CustomStringConvertible {
    case invalidFormat(String)
    case hashMismatch(expected: String, actual: String, file: String)
    case lengthMismatch(expected: Int, actual: Int, file: String)
    
    public var description: String {
        switch self {
        case .invalidFormat(let msg):
            return "FixtureHeader invalid format: \(msg)"
        case .hashMismatch(let expected, let actual, let file):
            return "FixtureHeader hash mismatch in \(file): expected \(expected.prefix(16))..., got \(actual.prefix(16))..."
        case .lengthMismatch(let expected, let actual, let file):
            return "FixtureHeader length mismatch in \(file): expected \(expected), got \(actual)"
        }
    }
}

// Note: isHexDigit extension is defined in FixtureLoader.swift to avoid duplicate declaration
