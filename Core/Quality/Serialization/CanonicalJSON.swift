// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CanonicalJSON.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  Canonical JSON encoder (P3/P13/P23/H1/H2)
//  Single source of truth for audit record serialization
//  Pure Swift implementation - NO JSONEncoder/JSONSerialization
//

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - String Extension for Padding

private extension String {
    /// Left-pad string to specified length
    ///
    /// Used for formatting fractional part of floats with leading zeros.
    /// Example: "123".leftPadding(toLength: 6, withPad: "0") -> "000123"
    func leftPadding(toLength length: Int, withPad character: Character) -> String {
        let currentLength = self.count
        if currentLength >= length {
            return self
        }
        let paddingCount = length - currentLength
        let padding = String(repeating: character, count: paddingCount)
        return padding + self
    }
}

/// CanonicalJSON - canonical JSON encoder for audit records
/// H1: All floats use fixed 6 decimal format, no exceptions
/// H2: Integer width contracts, overflow detection, float epsilon comparison
/// SSOT: Pure Swift implementation, no Foundation JSON encoding
public struct CanonicalJSON {
    
    /// Encode AuditRecord to canonical JSON string
    /// - Parameter record: AuditRecord to encode
    /// - Returns: Canonical JSON string
    /// - Throws: EncodingError if value cannot be encoded
    public static func encode(_ record: AuditRecord) throws -> String {
        // Convert AuditRecord to dictionary manually (no JSONEncoder)
        let dict = try recordToDictionary(record)
        return try canonicalize(dict)
    }
    
    /// Convert AuditRecord to dictionary
    private static func recordToDictionary(_ record: AuditRecord) throws -> [String: Any] {
        // Convert ruleIds array
        let ruleIdsArray = record.ruleIds.map { $0.rawValue }
        
        // Convert metricSnapshot
        var metricSnapshotDict: [String: Any] = [:]
        if let brightness = record.metricSnapshot.brightness {
            metricSnapshotDict["brightness"] = brightness
        }
        if let laplacian = record.metricSnapshot.laplacian {
            metricSnapshotDict["laplacian"] = laplacian
        }
        if let featureScore = record.metricSnapshot.featureScore {
            metricSnapshotDict["featureScore"] = featureScore
        }
        if let motionScore = record.metricSnapshot.motionScore {
            metricSnapshotDict["motionScore"] = motionScore
        }
        
        return [
            "ruleIds": ruleIdsArray,
            "metricSnapshot": metricSnapshotDict,
            "decisionPathDigest": record.decisionPathDigest,
            "thresholdVersion": record.thresholdVersion,
            "buildGitSha": record.buildGitSha
        ]
    }
    
    /// Canonicalize JSON object
    private static func canonicalize(_ object: [String: Any]) throws -> String {
        // Sort keys using UTF-8 bytewise lexicographic order (P23/H2)
        let sortedKeys = object.keys.sorted { key1, key2 in
            let data1 = key1.data(using: .utf8) ?? Data()
            let data2 = key2.data(using: .utf8) ?? Data()
            return data1.lexicographicallyPrecedes(data2)
        }
        
        var parts: [String] = []
        parts.append("{")
        
        for (index, key) in sortedKeys.enumerated() {
            if index > 0 {
                parts.append(",")
            }
            
            // Encode key (UTF-8, no normalization per P13)
            let keyEscaped = escapeString(key)
            parts.append("\"\(keyEscaped)\":")
            
            // Encode value
            let value = object[key]!
            let valueStr = try encodeValue(value)
            parts.append(valueStr)
        }
        
        parts.append("}")
        return parts.joined()
    }
    
    /// Encode value
    private static func encodeValue(_ value: Any) throws -> String {
        switch value {
        case let dict as [String: Any]:
            return try canonicalize(dict)
            
        case let array as [Any]:
            // Arrays preserve order (P23)
            let arrayParts = try array.map { try encodeValue($0) }
            return "[" + arrayParts.joined(separator: ",") + "]"
            
        case let str as String:
            return "\"\(escapeString(str))\""
            
        case let num as NSNumber:
            #if canImport(CoreFoundation)
            // On Apple platforms, use CoreFoundation to detect boolean
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            } else {
                // Check if it's a floating point number
                let objCType = String(cString: num.objCType)
                if objCType.contains("f") || objCType.contains("d") {
                    return try formatFloat(num.doubleValue)
                } else {
                    return "\(num.intValue)"
                }
            }
            #else
            // On Linux, NSNumber boolean detection via objCType
            let objCType = String(cString: num.objCType)
            if objCType == "c" || objCType == "B" {
                // 'c' is char (used for Bool in some contexts), 'B' is Bool
                return num.boolValue ? "true" : "false"
            } else if objCType.contains("f") || objCType.contains("d") {
                return try formatFloat(num.doubleValue)
            } else {
                return "\(num.intValue)"
            }
            #endif
            
        case let double as Double:
            return try formatFloat(double)
            
        case let float as Float:
            return try formatFloat(Double(float))
            
        case let int as Int:
            return "\(int)"
            
        case let int32 as Int32:
            return "\(int32)"
            
        case let int64 as Int64:
            return "\(int64)"
            
        case let bool as Bool:
            return bool ? "true" : "false"
            
        case is NSNull:
            return "null"
            
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Unsupported type: \(type(of: value))"))
        }
    }
    
    /// Format float with fixed 6 decimal places (H1)
    ///
    /// **Rule ID:** P23, H1
    /// **Status:** SEALED (v6.0)
    ///
    /// **CHANGED (v6.0):** Replaced NumberFormatter with pure arithmetic formatting
    /// to eliminate Locale dependency and ensure cross-platform determinism.
    ///
    /// **Algorithm:**
    /// 1. Check for NaN/Inf (forbidden)
    /// 2. Normalize negative zero to positive zero
    /// 3. Scale to 6 decimal places
    /// 4. Round half-away-from-zero (banker's rounding alternative)
    /// 5. Format as "[-]<int>.<6digits>"
    ///
    /// **P23:** Negative zero normalization (-0.0 → "0.000000")
    /// **H1:** Round half away from zero
    private static func formatFloat(_ value: Double) throws -> String {
        // Check for NaN/Inf (forbidden per P23)
        if value.isNaN || value.isInfinite {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "NaN/Inf not allowed in canonical JSON"
            ))
        }

        // Normalize negative zero (P23)
        let normalizedValue = value == -0.0 ? 0.0 : value

        // Pure arithmetic formatting (NO NumberFormatter for determinism)
        let isNegative = normalizedValue < 0
        let absValue = abs(normalizedValue)

        // Scale to 6 decimal places
        // Use .toNearestOrAwayFromZero for half-away-from-zero rounding
        let scale: Double = 1_000_000.0
        let scaled = (absValue * scale).rounded(.toNearestOrAwayFromZero)

        // Check for overflow (very large numbers)
        guard scaled < Double(UInt64.max) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "Float value too large for canonical encoding"
            ))
        }

        let scaledInt = UInt64(scaled)
        let intPart = scaledInt / 1_000_000
        let fracPart = scaledInt % 1_000_000

        // Format with exactly 6 decimal places using pure string formatting
        let sign = isNegative ? "-" : ""
        let fracStr = String(fracPart).leftPadding(toLength: 6, withPad: "0")

        return "\(sign)\(intPart).\(fracStr)"
    }
    
    /// Escape string for JSON
    private static func escapeString(_ str: String) -> String {
        var result = ""
        for char in str {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                // UTF-8 encoding, no normalization (P13)
                result.append(char)
            }
        }
        return result
    }
}
