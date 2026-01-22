//
// SchemaRegistryTests.swift
// Aether3D
//
// Tests for SchemaRegistry completeness and validity.
//

import XCTest
@testable import Aether3DCore

final class SchemaRegistryTests: XCTestCase {
    func testAllSchemasRegistered() {
        let schemas = SchemaRegistry.allSchemas
        XCTAssertFalse(schemas.isEmpty, "Should have registered schemas")
        
        // Check key schemas exist
        let schemaIds = Set(schemas.map { $0.id })
        XCTAssertTrue(schemaIds.contains("SSOTErrorRecord"))
        XCTAssertTrue(schemaIds.contains("SSOTLogEvent"))
        XCTAssertTrue(schemaIds.contains("ThresholdSpec"))
        XCTAssertTrue(schemaIds.contains("SystemConstantSpec"))
        XCTAssertTrue(schemaIds.contains("MinLimitSpec"))
        XCTAssertTrue(schemaIds.contains("FixedConstantSpec"))
    }
    
    func testFindSchema() {
        let schema = SchemaRegistry.findSchema(id: "SSOTErrorRecord")
        XCTAssertNotNil(schema, "Should find SSOTErrorRecord schema")
        XCTAssertEqual(schema?.id, "SSOTErrorRecord")
        XCTAssertEqual(schema?.version, "1.0.0")
    }
    
    func testValidateSchema() {
        let errors = SchemaRegistry.validateSchema(
            id: "SSOTErrorRecord",
            expectedFields: ["domainId", "code", "stableName", "timestamp", "context"]
        )
        XCTAssertTrue(errors.isEmpty, "SSOTErrorRecord schema should be valid: \(errors.joined(separator: "; "))")
    }
    
    func testValidateSchemaMissingFields() {
        let errors = SchemaRegistry.validateSchema(
            id: "SSOTErrorRecord",
            expectedFields: ["domainId", "code", "stableName", "timestamp", "context", "missingField"]
        )
        XCTAssertFalse(errors.isEmpty, "Should detect missing field")
        XCTAssertTrue(errors.contains { $0.contains("missing") })
    }
    
    func testValidateSchemaExtraFields() {
        let errors = SchemaRegistry.validateSchema(
            id: "SSOTErrorRecord",
            expectedFields: ["domainId", "code"]
        )
        XCTAssertFalse(errors.isEmpty, "Should detect extra fields")
        XCTAssertTrue(errors.contains { $0.contains("extra") })
    }
    
    func testSchemaVersions() {
        let schemas = SchemaRegistry.allSchemas
        for schema in schemas {
            XCTAssertFalse(schema.version.isEmpty, "Schema \(schema.id) should have version")
            XCTAssertFalse(schema.fields.isEmpty, "Schema \(schema.id) should have fields")
        }
    }
}

