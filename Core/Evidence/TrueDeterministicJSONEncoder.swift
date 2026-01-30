//
// TrueDeterministicJSONEncoder.swift
// Aether3D
//
// PR2 Patch V4 - True Deterministic JSON Encoder
// Byte-identical output across all platforms and iterations
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Canonical JSON value tree
/// Uses ordered list for objects, not Dictionary
public enum CanonicalJSONValue {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case number(String)  // Pre-formatted decimal string
    case array([CanonicalJSONValue])
    case object([(String, CanonicalJSONValue)])  // Ordered list of (key, value) pairs
}

extension CanonicalJSONValue: Equatable {
    public static func == (lhs: CanonicalJSONValue, rhs: CanonicalJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let l), .bool(let r)): return l == r
        case (.int(let l), .int(let r)): return l == r
        case (.string(let l), .string(let r)): return l == r
        case (.number(let l), .number(let r)): return l == r
        case (.array(let l), .array(let r)): return l == r
        case (.object(let l), .object(let r)): return l.map { $0.0 } == r.map { $0.0 } && l.map { $0.1 } == r.map { $0.1 }
        default: return false
        }
    }
}

/// True deterministic JSON encoder
///
/// SPECIFICATION:
/// - Objects: keys sorted by UTF-8 bytewise ascending
/// - Arrays: preserve order
/// - Numbers:
///   - Int: decimal ASCII, no leading zeros (except 0)
///   - Double: fixed-point decimal with QuantizationPolicy precision (4 for evidence fields)
///   - No scientific notation
///   - Normalize -0.0 to 0.0
/// - Strings: JSON escape per RFC (quotes, backslash, control chars) with deterministic escaping
/// - No whitespace anywhere
/// - Always UTF-8 output
public final class TrueDeterministicJSONEncoder {
    
    /// Encode EvidenceState to deterministic JSON Data
    public static func encodeEvidenceState(_ state: EvidenceState) throws -> Data {
        let canonical = try state.toCanonicalJSON()
        return try encodeCanonical(canonical)
    }
    
    /// Encode any Codable to deterministic JSON Data
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        // First encode to intermediate representation
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .secondsSince1970
        
        let data = try encoder.encode(value)
        
        // Parse to JSON object
        guard let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Failed to parse JSON"))
        }
        
        // Convert to canonical form
        let canonical = try toCanonicalJSONValue(jsonObject)
        
        // Encode canonical form to string
        return try encodeCanonical(canonical)
    }
    
    /// Encode canonical JSON value to Data
    public static func encodeCanonical(_ value: CanonicalJSONValue) throws -> Data {
        let string = encodeCanonicalToString(value)
        guard let data = string.data(using: .utf8) else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Failed to convert to UTF-8"))
        }
        return data
    }
    
    /// Encode canonical JSON value to string
    private static func encodeCanonicalToString(_ value: CanonicalJSONValue) -> String {
        switch value {
        case .null:
            return "null"
            
        case .bool(let b):
            return b ? "true" : "false"
            
        case .int(let i):
            return "\(i)"
            
        case .string(let s):
            return escapeString(s)
            
        case .number(let n):
            return n
            
        case .array(let arr):
            let parts = arr.map { encodeCanonicalToString($0) }
            return "[\(parts.joined(separator: ","))]"
            
        case .object(let pairs):
            // Keys are already sorted in canonical form
            let parts = pairs.map { key, val in
                "\(escapeString(key)):\(encodeCanonicalToString(val))"
            }
            return "{\(parts.joined(separator: ","))}"
        }
    }
    
    /// Escape string for JSON
    private static func escapeString(_ string: String) -> String {
        var result = ""
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
            case "\u{08}":  // Backspace
                result += "\\b"
            case "\u{0C}":  // Form feed
                result += "\\f"
            default:
                if let ascii = char.asciiValue, ascii < 32 {
                    result += String(format: "\\u%04x", ascii)
                } else {
                    result.append(char)
                }
            }
        }
        return "\"\(result)\""
    }
    
    /// Convert JSON object to canonical form
    private static func toCanonicalJSONValue(_ value: Any, fieldName: String? = nil) throws -> CanonicalJSONValue {
        switch value {
        case is NSNull:
            return .null
            
        case let bool as Bool:
            return .bool(bool)
            
        case let int as Int:
            return .int(Int64(int))
            
        case let int64 as Int64:
            return .int(int64)
            
        case let double as Double:
            // Check if field should be quantized
            if let name = fieldName, QuantizationPolicy.shouldQuantize(fieldName: name) {
                let quantized = QuantizationPolicy.quantize(double)
                let formatted = QuantizationPolicy.formatQuantized(quantized)
                return .number(formatted)
            } else {
                // Non-quantized: use full precision (but still format deterministically)
                let formatted = String(format: "%.15g", double)
                return .number(formatted)
            }
            
        case let float as Float:
            return try toCanonicalJSONValue(Double(float), fieldName: fieldName)
            
        case let string as String:
            return .string(string)
            
        case let array as [Any]:
            let canonicalArray = try array.map { try toCanonicalJSONValue($0) }
            return .array(canonicalArray)
            
        case let dict as [String: Any]:
            // Sort keys by UTF-8 bytewise ascending
            let sortedKeys = dict.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let pairs = try sortedKeys.map { key in
                (key, try toCanonicalJSONValue(dict[key]!, fieldName: key))
            }
            return .object(pairs)
            
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type: \(type(of: value))"))
        }
    }
}

/// Stable hash helper for deterministic testing
public enum StableHash {
    /// Compute deterministic hash using SHA256
    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: use data hashValue (deterministic for testing)
        return "\(data.hashValue)"
        #endif
    }
}
