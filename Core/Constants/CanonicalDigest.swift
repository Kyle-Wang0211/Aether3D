//
// CanonicalDigest.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Canonical Digest with AST-based encoding
//
// H1: Encoder-driven canonical JSON with deterministic byte-for-byte serialization.
// Rejects Double/Float at encode-time. Cross-platform deterministic.
// Slot-based write-on-encode design (no finalize/deinit reliance).
//

import Foundation

#if canImport(Crypto)
import Crypto
#else
#error("Crypto module required for CanonicalDigest")
#endif

// MARK: - Errors (Foundational)

public enum CanonicalDigestError: Error {
    case missingValue
    case missingRootValue
    case floatForbidden(path: String, type: String)
    case valueOutOfRange(path: String)
    
    public var localizedDescription: String {
        switch self {
        case .missingValue:
            return "CanonicalDigest: Missing value after encoding"
        case .missingRootValue:
            return "CanonicalDigest: Root value not set after encoding"
        case .floatForbidden(let path, let type):
            return "CanonicalDigest: Float type \(type) not allowed (path: \(path)). Use LengthQ or Int64 instead."
        case .valueOutOfRange(let path):
            return "CanonicalDigest: Value out of Int64 range (path: \(path))"
        }
    }
}

// MARK: - Canonical JSON AST (Foundational)

/// Canonical JSON value types (no floats allowed)
public enum CJValue: Equatable {
    case object([(String, CJValue)])  // Sorted key-value pairs
    case array([CJValue])              // SSOT-defined order
    case string(String)
    case int(Int64)
    case bool(Bool)
    case null
    
    public static func == (lhs: CJValue, rhs: CJValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let l), .bool(let r)):
            return l == r
        case (.int(let l), .int(let r)):
            return l == r
        case (.string(let l), .string(let r)):
            return l == r
        case (.array(let l), .array(let r)):
            return l == r
        case (.object(let l), .object(let r)):
            if l.count != r.count { return false }
            for (i, (lk, lv)) in l.enumerated() {
                let (rk, rv) = r[i]
                if lk != rk || lv != rv {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Canonical JSON Writer (Deterministic Serialization)

extension CJValue {
    /// Serialize to deterministic UTF-8 bytes (LF only, no pretty print)
    public func serialize() -> Data {
        var result = Data()
        serialize(into: &result)
        return result
    }
    
    private func serialize(into data: inout Data) {
        switch self {
        case .object(let pairs):
            data.append(Data("{".utf8))
            // Sort pairs by key (lexicographic) for deterministic output
            let sortedPairs = pairs.sorted { $0.0 < $1.0 }
            for (index, (key, value)) in sortedPairs.enumerated() {
                if index > 0 {
                    data.append(Data(",".utf8))
                }
                // Escape key
                data.append(escapeString(key))
                data.append(Data(":".utf8))
                value.serialize(into: &data)
            }
            data.append(Data("}".utf8))
            
        case .array(let values):
            data.append(Data("[".utf8))
            // Preserve SSOT-defined order (no sorting)
            for (index, value) in values.enumerated() {
                if index > 0 {
                    data.append(Data(",".utf8))
                }
                value.serialize(into: &data)
            }
            data.append(Data("]".utf8))
            
        case .string(let s):
            data.append(escapeString(s))
            
        case .int(let i):
            data.append(Data(String(i).utf8))
            
        case .bool(let b):
            data.append(Data((b ? "true" : "false").utf8))
            
        case .null:
            data.append(Data("null".utf8))
        }
    }
    
    /// Stable escaping rules (RFC 7159 compliant, deterministic)
    /// Uses LF only (no CRLF)
    private func escapeString(_ s: String) -> Data {
        var result = Data()
        result.append(Data("\"".utf8))
        for char in s.utf8 {
            switch char {
            case UInt8(ascii: "\""):
                result.append(Data("\\\"".utf8))
            case UInt8(ascii: "\\"):
                result.append(Data("\\\\".utf8))
            case UInt8(ascii: "\n"):
                result.append(Data("\\n".utf8))
            case UInt8(ascii: "\r"):
                result.append(Data("\\r".utf8))
            case UInt8(ascii: "\t"):
                result.append(Data("\\t".utf8))
            case 0x00...0x1F:
                // Control characters: \uXXXX (4 hex digits, lowercase)
                let hex = String(format: "%04x", char)
                result.append(Data("\\u\(hex)".utf8))
            default:
                result.append(Data([char]))
            }
        }
        result.append(Data("\"".utf8))
        return result
    }
}

// MARK: - Slot (Write-Through Value Container)

/// Slot for write-on-encode: values are written immediately, not in finalize
final class Slot {
    var value: CJValue?
    
    init(value: CJValue? = nil) {
        self.value = value
    }
}

// MARK: - Canonical Digest Encoder

/// Custom encoder that builds CJValue AST, rejecting floats at encode-time
/// **Note:** This is different from Core/Audit/CanonicalJSONEncoder (which only handles flat dicts)
public class CanonicalDigestEncoder {
    let rootSlot: Slot
    
    public init() {
        self.rootSlot = Slot()
    }
    
    /// Encode a Codable value to CJValue
    public func encode<T: Encodable>(_ value: T) throws -> CJValue {
        rootSlot.value = nil
        let container = CanonicalEncodingContainer(encoder: self, slot: rootSlot)
        try value.encode(to: container)
        
        guard let result = rootSlot.value else {
            throw CanonicalDigestError.missingRootValue
        }
        return result
    }
}

// MARK: - Encoding Container

private struct CanonicalEncodingContainer: Encoder {
    let encoder: CanonicalDigestEncoder
    let slot: Slot
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    
    init(encoder: CanonicalDigestEncoder, slot: Slot) {
        self.encoder = encoder
        self.slot = slot
    }
    
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        // Initialize slot with empty object if not already set
        if slot.value == nil {
            slot.value = .object([])
        }
        let container = CanonicalKeyedEncodingContainer<Key>(encoder: encoder, slot: slot, codingPath: codingPath)
        return KeyedEncodingContainer(container)
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        // Initialize slot with empty array if not already set
        if slot.value == nil {
            slot.value = .array([])
        }
        return CanonicalUnkeyedEncodingContainer(encoder: encoder, slot: slot, codingPath: codingPath)
    }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        return CanonicalSingleValueEncodingContainer(encoder: encoder, slot: slot, codingPath: codingPath)
    }
}

// MARK: - Keyed Encoding Container (Struct with mutating, write-on-encode)

private struct CanonicalKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: CanonicalDigestEncoder
    let slot: Slot
    var codingPath: [CodingKey]
    private var storage: [String: CJValue] = [:]
    
    init(encoder: CanonicalDigestEncoder, slot: Slot, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.slot = slot
        self.codingPath = codingPath
    }
    
    private mutating func updateSlot() {
        // Convert storage to sorted array of pairs for deterministic serialization
        let sortedPairs = storage.sorted { $0.key < $1.key }
        slot.value = .object(sortedPairs)
    }
    
    mutating func encodeNil(forKey key: Key) throws {
        storage[key.stringValue] = .null
        updateSlot()
    }
    
    mutating func encode(_ value: Bool, forKey key: Key) throws {
        storage[key.stringValue] = .bool(value)
        updateSlot()
    }
    
    mutating func encode(_ value: String, forKey key: Key) throws {
        storage[key.stringValue] = .string(value)
        updateSlot()
    }
    
    mutating func encode(_ value: Double, forKey key: Key) throws {
        let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "." + key.stringValue
        throw CanonicalDigestError.floatForbidden(path: path, type: "Double")
    }
    
    mutating func encode(_ value: Float, forKey key: Key) throws {
        let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "." + key.stringValue
        throw CanonicalDigestError.floatForbidden(path: path, type: "Float")
    }
    
    mutating func encode(_ value: Int, forKey key: Key) throws {
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: Int8, forKey key: Key) throws {
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: Int16, forKey key: Key) throws {
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: Int32, forKey key: Key) throws {
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: Int64, forKey key: Key) throws {
        storage[key.stringValue] = .int(value)
        updateSlot()
    }
    
    mutating func encode(_ value: UInt, forKey key: Key) throws {
        if value > Int64.max {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "." + key.stringValue
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        if value > Int64.max {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "." + key.stringValue
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        if value > Int64.max {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "." + key.stringValue
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        storage[key.stringValue] = .int(Int64(value))
        updateSlot()
    }
    
    mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        // Create a child slot for nested encoding
        let childSlot = Slot()
        let childContainer = CanonicalEncodingContainer(encoder: encoder, slot: childSlot)
        try value.encode(to: childContainer)
        
        guard let childValue = childSlot.value else {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "." + key.stringValue
            throw CanonicalDigestError.missingValue
        }
        
        // Ensure nested objects are also sorted (defense-in-depth)
        let normalizedChildValue: CJValue
        if case .object(let pairs) = childValue {
            // Re-sort to ensure determinism (even if child container already sorted)
            let sortedPairs = pairs.sorted { $0.0 < $1.0 }
            normalizedChildValue = .object(sortedPairs)
        } else {
            normalizedChildValue = childValue
        }
        
        storage[key.stringValue] = normalizedChildValue
        updateSlot()
    }
    
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        // Nested containers handled via encode<T>
        // This should never be called - nested encoding goes through encode<T>
        // Return a container that will encode via encode<T> path
        let childSlot = Slot()
        var container = CanonicalKeyedEncodingContainer<NestedKey>(encoder: encoder, slot: childSlot, codingPath: codingPath + [key])
        return KeyedEncodingContainer(container)
    }
    
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        // Nested containers handled via encode<T>
        // This should never be called - nested encoding goes through encode<T>
        // Return a container that will encode via encode<T> path
        let childSlot = Slot()
        return CanonicalUnkeyedEncodingContainer(encoder: encoder, slot: childSlot, codingPath: codingPath + [key])
    }
    
    mutating func superEncoder(forKey key: Key) -> Encoder {
        // Not supported - create a dummy encoder
        // Note: This creates a new encoder, which is not ideal but avoids fatalError
        let encoder = CanonicalDigestEncoder()
        return CanonicalEncodingContainer(encoder: encoder, slot: encoder.rootSlot)
    }
    
    mutating func superEncoder() -> Encoder {
        // Not supported - create a dummy encoder
        let encoder = CanonicalDigestEncoder()
        return CanonicalEncodingContainer(encoder: encoder, slot: encoder.rootSlot)
    }
}

// MARK: - Unkeyed Encoding Container (Struct with mutating, write-on-encode)

private struct CanonicalUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: CanonicalDigestEncoder
    let slot: Slot
    var codingPath: [CodingKey]
    var count: Int { elements.count }
    private var elements: [CJValue] = []
    
    init(encoder: CanonicalDigestEncoder, slot: Slot, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.slot = slot
        self.codingPath = codingPath
    }
    
    private mutating func updateSlot() {
        slot.value = .array(elements)
    }
    
    mutating func encodeNil() throws {
        elements.append(.null)
        updateSlot()
    }
    
    mutating func encode(_ value: Bool) throws {
        elements.append(.bool(value))
        updateSlot()
    }
    
    mutating func encode(_ value: String) throws {
        elements.append(.string(value))
        updateSlot()
    }
    
    mutating func encode(_ value: Double) throws {
        let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "[\(count)]"
        throw CanonicalDigestError.floatForbidden(path: path, type: "Double")
    }
    
    mutating func encode(_ value: Float) throws {
        let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "[\(count)]"
        throw CanonicalDigestError.floatForbidden(path: path, type: "Float")
    }
    
    mutating func encode(_ value: Int) throws {
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: Int8) throws {
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: Int16) throws {
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: Int32) throws {
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: Int64) throws {
        elements.append(.int(value))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt) throws {
        if value > Int64.max {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "[\(count)]"
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt8) throws {
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt16) throws {
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt32) throws {
        if value > Int64.max {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "[\(count)]"
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode(_ value: UInt64) throws {
        if value > Int64.max {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "[\(count)]"
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        elements.append(.int(Int64(value)))
        updateSlot()
    }
    
    mutating func encode<T>(_ value: T) throws where T: Encodable {
        // Create a child slot for nested encoding
        let childSlot = Slot()
        let childContainer = CanonicalEncodingContainer(encoder: encoder, slot: childSlot)
        try value.encode(to: childContainer)
        
        guard let childValue = childSlot.value else {
            let path = codingPath.map { $0.stringValue }.joined(separator: ".") + "[\(count)]"
            throw CanonicalDigestError.missingValue
        }
        
        // Ensure nested objects are also sorted (defense-in-depth)
        let normalizedChildValue: CJValue
        if case .object(let pairs) = childValue {
            // Re-sort to ensure determinism (even if child container already sorted)
            let sortedPairs = pairs.sorted { $0.0 < $1.0 }
            normalizedChildValue = .object(sortedPairs)
        } else {
            normalizedChildValue = childValue
        }
        
        elements.append(normalizedChildValue)
        updateSlot()
    }
    
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        // Nested containers handled via encode<T>
        // This should never be called - nested encoding goes through encode<T>
        // Return a container that will encode via encode<T> path
        let childSlot = Slot()
        let container = CanonicalKeyedEncodingContainer<NestedKey>(encoder: encoder, slot: childSlot, codingPath: codingPath)
        return KeyedEncodingContainer(container)
    }
    
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        // Nested containers handled via encode<T>
        // This should never be called - nested encoding goes through encode<T>
        // Return a container that will encode via encode<T> path
        let childSlot = Slot()
        return CanonicalUnkeyedEncodingContainer(encoder: encoder, slot: childSlot, codingPath: codingPath)
    }
    
    mutating func superEncoder() -> Encoder {
        // Not supported - create a dummy encoder
        let encoder = CanonicalDigestEncoder()
        return CanonicalEncodingContainer(encoder: encoder, slot: encoder.rootSlot)
    }
}

// MARK: - Single Value Encoding Container (Struct with mutating, write-on-encode)

private struct CanonicalSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: CanonicalDigestEncoder
    let slot: Slot
    var codingPath: [CodingKey]
    
    init(encoder: CanonicalDigestEncoder, slot: Slot, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.slot = slot
        self.codingPath = codingPath
    }
    
    func encodeNil() throws {
        slot.value = .null
    }
    
    func encode(_ value: Bool) throws {
        slot.value = .bool(value)
    }
    
    func encode(_ value: String) throws {
        slot.value = .string(value)
    }
    
    func encode(_ value: Double) throws {
        let path = codingPath.isEmpty ? "root" : codingPath.map { $0.stringValue }.joined(separator: ".")
        throw CanonicalDigestError.floatForbidden(path: path, type: "Double")
    }
    
    func encode(_ value: Float) throws {
        let path = codingPath.isEmpty ? "root" : codingPath.map { $0.stringValue }.joined(separator: ".")
        throw CanonicalDigestError.floatForbidden(path: path, type: "Float")
    }
    
    func encode(_ value: Int) throws {
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: Int8) throws {
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: Int16) throws {
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: Int32) throws {
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: Int64) throws {
        slot.value = .int(value)
    }
    
    func encode(_ value: UInt) throws {
        if value > Int64.max {
            let path = codingPath.isEmpty ? "root" : codingPath.map { $0.stringValue }.joined(separator: ".")
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: UInt8) throws {
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: UInt16) throws {
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: UInt32) throws {
        if value > Int64.max {
            let path = codingPath.isEmpty ? "root" : codingPath.map { $0.stringValue }.joined(separator: ".")
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        slot.value = .int(Int64(value))
    }
    
    func encode(_ value: UInt64) throws {
        if value > Int64.max {
            let path = codingPath.isEmpty ? "root" : codingPath.map { $0.stringValue }.joined(separator: ".")
            throw CanonicalDigestError.valueOutOfRange(path: path)
        }
        slot.value = .int(Int64(value))
    }
    
    func encode<T>(_ value: T) throws where T: Encodable {
        let childSlot = Slot()
        let childContainer = CanonicalEncodingContainer(encoder: encoder, slot: childSlot)
        try value.encode(to: childContainer)
        
        guard let childValue = childSlot.value else {
            throw CanonicalDigestError.missingValue
        }
        
        // Ensure nested objects are also sorted (defense-in-depth)
        if case .object(let pairs) = childValue {
            // Re-sort to ensure determinism (even if child container already sorted)
            let sortedPairs = pairs.sorted { $0.0 < $1.0 }
            slot.value = .object(sortedPairs)
        } else {
            slot.value = childValue
        }
    }
}

// MARK: - KeyedValue Helper (Deterministic Dictionary Encoding)

/// Helper struct for deterministic dictionary encoding
/// Ensures key-value pairs are sorted by key for byte-for-byte determinism
public struct KeyedValue<Key: Codable & Comparable, Value: Codable>: Codable {
    public let key: Key
    public let value: Value
    
    public init(key: Key, value: Value) {
        self.key = key
        self.value = value
    }
}

// MARK: - Canonical Digest API

public enum CanonicalDigest {
    /// Encode to canonical JSON bytes (for debugging/verification)
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = CanonicalDigestEncoder()
        let cjValue = try encoder.encode(value)
        return cjValue.serialize()
    }
    
    /// Compute SHA-256 digest over canonical JSON bytes
    public static func computeDigest<T: Encodable>(_ value: T) throws -> String {
        let bytes = try encode(value)
        let hash = SHA256.hash(data: bytes)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Policy Digestable Protocol

/// Protocol for policy types that can provide digest input
public protocol PolicyDigestable {
    associatedtype DigestInput: Codable
    func digestInput() -> DigestInput
}
