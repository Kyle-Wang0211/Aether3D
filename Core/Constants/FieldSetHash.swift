// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FieldSetHash.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Field Set Hash (Schema Drift Protection)
//
// H7: "Closed-world cut" enforcement via FieldSetHash
// Computes a hash representing the exact field set of a DigestInput type
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("Crypto module required")
#endif

/// Field descriptor for a single field in a DigestInput type
public struct FieldDescriptor: Codable, Equatable {
    /// Field name
    public let name: String
    /// Field type (simplified: "Int64", "String", "UInt8", "Array", "Object", etc.)
    public let type: String
    /// Whether the field is optional
    public let isOptional: Bool
    
    public init(name: String, type: String, isOptional: Bool = false) {
        self.name = name
        self.type = type
        self.isOptional = isOptional
    }
}

/// Field set descriptor for a DigestInput type
public struct FieldSetDescriptor: Codable {
    /// Type name (e.g., "GridResolutionPolicy.DigestInput")
    public let typeName: String
    /// Ordered list of field descriptors
    public let fields: [FieldDescriptor]
    
    public init(typeName: String, fields: [FieldDescriptor]) {
        self.typeName = typeName
        self.fields = fields
    }
    
    /// Compute SHA-256 hash of the field set
    /// Hash is computed from: typeName + sorted field names + field types + optionality
    public func computeHash() -> String {
        // Create canonical representation
        var components: [String] = []
        components.append("type:\(typeName)")
        
        // Sort fields by name for determinism
        let sortedFields = fields.sorted { $0.name < $1.name }
        for field in sortedFields {
            components.append("field:\(field.name):\(field.type):\(field.isOptional ? "optional" : "required")")
        }
        
        let canonicalString = components.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(canonicalString.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// Protocol for types that can provide field set descriptors
public protocol FieldSetHashable {
    /// Get the field set descriptor for this type
    static func fieldSetDescriptor() -> FieldSetDescriptor
}

// MARK: - Field Set Descriptors for Policy DigestInput Types

extension GridResolutionPolicy.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "GridResolutionPolicy.DigestInput",
            fields: [
                FieldDescriptor(name: "schemaVersionId", type: "UInt16"),
                FieldDescriptor(name: "systemMinimumQuantum", type: "LengthQ.DigestInput"),
                FieldDescriptor(name: "recommendedCaptureFloors", type: "Dictionary<UInt8,LengthQ.DigestInput>"),
                FieldDescriptor(name: "allowedGridCellSizes", type: "Array<LengthQ.DigestInput>"),
                FieldDescriptor(name: "profileMappings", type: "Dictionary<UInt8,Array<LengthQ.DigestInput>>"),
            ]
        )
    }
}

extension PatchPolicy.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "PatchPolicy.DigestInput",
            fields: [
                FieldDescriptor(name: "schemaVersionId", type: "UInt16"),
                FieldDescriptor(name: "policies", type: "Array<PatchPolicySpec>"),
            ]
        )
    }
}

extension CoveragePolicy.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "CoveragePolicy.DigestInput",
            fields: [
                FieldDescriptor(name: "schemaVersionId", type: "UInt16"),
                FieldDescriptor(name: "policies", type: "Array<CoveragePolicySpec>"),
            ]
        )
    }
}

extension EvidenceBudgetPolicy.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "EvidenceBudgetPolicy.DigestInput",
            fields: [
                FieldDescriptor(name: "schemaVersionId", type: "UInt16"),
                FieldDescriptor(name: "policies", type: "Array<EvidenceBudgetPolicySpec>"),
            ]
        )
    }
}

extension DisplayPolicy.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "DisplayPolicy.DigestInput",
            fields: [
                FieldDescriptor(name: "schemaVersionId", type: "UInt16"),
                FieldDescriptor(name: "wireframeDebugOnly", type: "Bool"),
                FieldDescriptor(name: "requireAggregation", type: "Bool"),
                FieldDescriptor(name: "allowedAggregationLevels", type: "Array<LengthQ.DigestInput>"),
                FieldDescriptor(name: "allowedDrillDownLevels", type: "Array<LengthQ.DigestInput>"),
                FieldDescriptor(name: "targetDisplayPixelDensityPerVisualCell", type: "Int64"),
            ]
        )
    }
}

extension CaptureProfile.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "CaptureProfile.DigestInput",
            fields: [
                FieldDescriptor(name: "profileId", type: "UInt8"),
                FieldDescriptor(name: "name", type: "String"),
                FieldDescriptor(name: "documentation", type: "String"),
            ]
        )
    }
}

extension LengthQ.DigestInput: FieldSetHashable {
    public static func fieldSetDescriptor() -> FieldSetDescriptor {
        return FieldSetDescriptor(
            typeName: "LengthQ.DigestInput",
            fields: [
                FieldDescriptor(name: "scaleId", type: "UInt8"),
                FieldDescriptor(name: "quanta", type: "Int64"),
            ]
        )
    }
}

// MARK: - Helper Functions

/// Compute field set hash for a type
public func computeFieldSetHash<T: FieldSetHashable>(for type: T.Type) -> String {
    return type.fieldSetDescriptor().computeHash()
}
