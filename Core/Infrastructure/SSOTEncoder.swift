//
// SSOTEncoder.swift
// Aether3D
//
// Canonical JSON encoder/decoder for deterministic serialization.
// Direct JSONEncoder() usage outside this file is prohibited.
//

import Foundation

/// Canonical JSON encoder with deterministic settings.
public class SSOTEncoder {
    private let encoder: JSONEncoder
    
    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }
    
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        return try encoder.encode(value)
    }
    
    public func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        guard let str = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "Failed to convert data to UTF-8 string"
            ))
        }
        return str
    }
}

/// Canonical JSON decoder.
public class SSOTDecoder {
    private let decoder: JSONDecoder
    
    public init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }
    
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try decoder.decode(type, from: data)
    }
    
    public func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Failed to convert string to UTF-8 data"
            ))
        }
        return try decode(type, from: data)
    }
}

