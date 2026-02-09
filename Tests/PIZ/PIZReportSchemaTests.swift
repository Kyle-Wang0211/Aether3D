// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZReportSchemaTests.swift
// Aether3D
//
// PR1 PIZ Detection - Schema Tests
//
// Tests for closed-set decoding, profile gating, and schema compatibility.
// **Rule ID:** PIZ_SCHEMA_PROFILE_001, PIZ_SCHEMA_COMPAT_001

import XCTest
@testable import Aether3DCore

final class PIZReportSchemaTests: XCTestCase {
    
    /// Test DecisionOnly decoding rejects explainability fields.
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    func testDecisionOnlyRejectsExplainabilityFields() {
        let json = """
        {
            "schemaVersion": {"major": 1, "minor": 0, "patch": 0},
            "outputProfile": "DecisionOnly",
            "gateRecommendation": "ALLOW_PUBLISH",
            "globalTrigger": false,
            "localTriggerCount": 0,
            "regions": []
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(PIZReport.self, from: json)) { error in
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .dataCorrupted(let context):
                    XCTAssertTrue(context.debugDescription.contains("regions") || context.debugDescription.contains("forbidden"))
                default:
                    XCTFail("Unexpected error type: \(decodingError)")
                }
            }
        }
    }
    
    /// Test DecisionOnly decoding accepts only decision fields.
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    func testDecisionOnlyAcceptsDecisionFields() throws {
        let json = """
        {
            "schemaVersion": {"major": 1, "minor": 0, "patch": 0},
            "outputProfile": "DecisionOnly",
            "gateRecommendation": "ALLOW_PUBLISH",
            "globalTrigger": false,
            "localTriggerCount": 0
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let report = try decoder.decode(PIZReport.self, from: json)
        
        XCTAssertEqual(report.outputProfile, .decisionOnly)
        XCTAssertEqual(report.gateRecommendation, .allowPublish)
        XCTAssertEqual(report.globalTrigger, false)
        XCTAssertEqual(report.localTriggerCount, 0)
        XCTAssertNil(report.heatmap)
        XCTAssertNil(report.regions)
    }
    
    /// Test FullExplainability decoding requires all fields.
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    func testFullExplainabilityRequiresAllFields() {
        let json = """
        {
            "schemaVersion": {"major": 1, "minor": 0, "patch": 0},
            "outputProfile": "FullExplainability",
            "gateRecommendation": "ALLOW_PUBLISH",
            "globalTrigger": false,
            "localTriggerCount": 0
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(PIZReport.self, from: json))
    }
    
    /// Test unknown enum raw values are rejected.
    /// **Rule ID:** PIZ_SCHEMA_COMPAT_001
    func testUnknownEnumValuesRejected() {
        let json = """
        {
            "schemaVersion": {"major": 1, "minor": 0, "patch": 0},
            "outputProfile": "InvalidProfile",
            "gateRecommendation": "ALLOW_PUBLISH",
            "globalTrigger": false,
            "localTriggerCount": 0
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(PIZReport.self, from: json))
    }
    
    /// Test unknown fields rejected for same version.
    /// **Rule ID:** PIZ_SCHEMA_COMPAT_001
    func testUnknownFieldsRejectedSameVersion() {
        let json = """
        {
            "schemaVersion": {"major": 1, "minor": 0, "patch": 0},
            "outputProfile": "DecisionOnly",
            "gateRecommendation": "ALLOW_PUBLISH",
            "globalTrigger": false,
            "localTriggerCount": 0,
            "unknownField": "value"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        decoder.userInfo[.pizSchemaVersion] = PIZSchemaVersion.current
        XCTAssertThrowsError(try decoder.decode(PIZReport.self, from: json)) { error in
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .dataCorrupted(let context):
                    XCTAssertTrue(context.debugDescription.contains("Unknown fields"))
                default:
                    XCTFail("Unexpected error type: \(decodingError)")
                }
            }
        }
    }
    
    /// Test unknown fields ignored for older minor version parser.
    /// **Rule ID:** PIZ_SCHEMA_COMPAT_001
    func testUnknownFieldsIgnoredOlderMinor() throws {
        let json = """
        {
            "schemaVersion": {"major": 1, "minor": 1, "patch": 0},
            "outputProfile": "DecisionOnly",
            "gateRecommendation": "ALLOW_PUBLISH",
            "globalTrigger": false,
            "localTriggerCount": 0,
            "newFieldInMinor": "value"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        // Simulate older parser (minor 0) parsing newer data (minor 1)
        decoder.userInfo[.pizSchemaVersion] = PIZSchemaVersion(major: 1, minor: 0, patch: 0)
        
        // Should succeed (unknown fields ignored)
        let report = try decoder.decode(PIZReport.self, from: json)
        XCTAssertEqual(report.outputProfile, .decisionOnly)
    }
}
