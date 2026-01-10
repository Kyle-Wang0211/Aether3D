// CanonicalJSONEncoder.swift
// PR#8.5 / v0.0.1

import Foundation

/// Canonical JSON encoder for deterministic output.
///
/// Used ONLY for paramsSummary encoding in ID generation.
/// NOT used for full AuditEntry encoding.
///
/// - Note: Thread-safety: All methods are static and stateless.
/// - Note: This is NOT a general canonicalizer. Only supports flat [String: String] dicts.
public enum CanonicalJSONEncoder {
    
    /// Encode dictionary to canonical JSON string.
    ///
    /// - Parameter dict: String-String dictionary (flat, no nesting)
    /// - Returns: Canonical JSON string (sorted keys, no whitespace)
    ///
    /// Format: {"key1":"value1","key2":"value2"}
    /// Keys sorted by UTF-8 byte lexicographic order (not Swift String <)
    /// Values escaped per JSON spec
    public static func encode(_ dict: [String: String]) -> String {
        if dict.isEmpty {
            return "{}"
        }
        
        // Sort keys by UTF-8 byte lexicographic order
        let sortedKeys = dict.keys.sorted { key1, key2 in
            let data1 = Data(key1.utf8)
            let data2 = Data(key2.utf8)
            return data1.lexicographicallyPrecedes(data2)
        }
        
        var parts: [String] = []
        parts.reserveCapacity(sortedKeys.count)
        
        for key in sortedKeys {
            let escapedKey = escapeJSONString(key)
            let escapedValue = escapeJSONString(dict[key]!)
            parts.append("\"\(escapedKey)\":\"\(escapedValue)\"")
        }
        
        return "{" + parts.joined(separator: ",") + "}"
    }
    
    /// Escape string for JSON.
    ///
    /// Escapes: " \ and control characters (0x00-0x1F, 0x7F)
    /// Does NOT escape: /
    public static func escapeJSONString(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        
        for char in string {
            switch char {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if let scalar = char.unicodeScalars.first {
                    let value = scalar.value
                    // Control characters: < 0x20 OR == 0x7F
                    if value < 0x20 || value == 0x7F {
                        // Control character: \u00XX (uppercase hex)
                        result += String(format: "\\u%04X", value)
                    } else {
                        result.append(char)
                    }
                } else {
                    result.append(char)
                }
            }
        }
        
        return result
    }
}

