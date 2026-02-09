// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SchemaRegistry.swift
// Aether3D
//
// Registry for all serialization schemas in the system.
//

import Foundation

/// Schema version information
public struct SchemaVersion: Codable, Equatable {
    /// Schema identifier
    public let id: String
    
    /// Version string
    public let version: String
    
    /// Field names in this schema
    public let fields: [String]
    
    public init(id: String, version: String, fields: [String]) {
        self.id = id
        self.version = version
        self.fields = fields
    }
}

/// Registry for all serialization schemas
public enum SchemaRegistry {
    /// All registered schemas
    public static let allSchemas: [SchemaVersion] = [
        SchemaVersion(
            id: "SSOTErrorRecord",
            version: "1.0.0",
            fields: ["domainId", "code", "stableName", "timestamp", "context"]
        ),
        SchemaVersion(
            id: "SSOTLogEvent",
            version: "1.0.0",
            fields: ["type", "timestamp", "ssotId", "message", "context"]
        ),
        SchemaVersion(
            id: "ThresholdSpec",
            version: "1.0.0",
            fields: ["ssotId", "name", "unit", "category", "min", "max", "defaultValue", "onExceed", "onUnderflow", "documentation"]
        ),
        SchemaVersion(
            id: "SystemConstantSpec",
            version: "1.0.0",
            fields: ["ssotId", "name", "unit", "value", "documentation"]
        ),
        SchemaVersion(
            id: "MinLimitSpec",
            version: "1.0.0",
            fields: ["ssotId", "name", "unit", "minValue", "onUnderflow", "documentation"]
        ),
        SchemaVersion(
            id: "FixedConstantSpec",
            version: "1.0.0",
            fields: ["ssotId", "name", "unit", "value", "documentation"]
        )
    ]
    
    /// Find schema by ID
    public static func findSchema(id: String) -> SchemaVersion? {
        return allSchemas.first { $0.id == id }
    }
    
    /// Validate that a schema exists and has expected fields
    public static func validateSchema(id: String, expectedFields: [String]) -> [String] {
        var errors: [String] = []
        
        guard let schema = findSchema(id: id) else {
            errors.append("Schema '\(id)' not found in registry")
            return errors
        }
        
        let schemaFields = Set(schema.fields)
        let expectedFieldsSet = Set(expectedFields)
        
        let missing = expectedFieldsSet.subtracting(schemaFields)
        if !missing.isEmpty {
            errors.append("Schema '\(id)' missing fields: \(missing.sorted().joined(separator: ", "))")
        }
        
        let extra = schemaFields.subtracting(expectedFieldsSet)
        if !extra.isEmpty {
            errors.append("Schema '\(id)' has extra fields: \(extra.sorted().joined(separator: ", "))")
        }
        
        return errors
    }
}

