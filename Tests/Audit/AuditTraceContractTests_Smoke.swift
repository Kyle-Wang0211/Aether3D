// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// AuditTraceContractTests_Smoke.swift
// PR#8.5 / v0.0.1
// Minimal smoke tests to isolate runtime failures

import XCTest
@testable import Aether3DCore

/// Minimal smoke tests to isolate runtime failures before expanding test suite.
final class AuditTraceContractTests_Smoke: XCTestCase {
    
    func makeTestBuildMeta() -> BuildMeta {
        return BuildMeta(
            version: "test",
            buildId: "test-build",
            gitCommit: "test-commit",
            buildTime: "test-time"
        )
    }
    
    func makeTestPolicyHash() -> String {
        return String(repeating: "a", count: 64)
    }
    
    // MARK: - Smoke Test 1: Minimal Valid AuditEntry Encoding
    
    func test_smoke_minimalValidEntry_encodes() throws {
        // Construct the smallest possible valid AuditEntry using only PR#8.5 fields
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: "trace_start",  // Legacy field
            detailsJson: nil,  // Legacy field
            detailsSchemaVersion: "1.0",  // Legacy field
            schemaVersion: 1,
            pr85EventType: .traceStart,
            entryType: "trace_start",  // MUST == pr85EventType.rawValue
            actionType: nil,
            traceId: String(repeating: "a", count: 64),
            sceneId: String(repeating: "b", count: 64),
            eventId: String(repeating: "a", count: 64) + ":0",
            policyHash: makeTestPolicyHash(),
            pipelineVersion: "B1",
            inputs: [],
            paramsSummary: [:],
            metrics: nil,
            artifactRef: nil,
            buildMeta: makeTestBuildMeta()
        )
        
        // Encode using standard JSONEncoder (not CanonicalJSONEncoder - that's only for paramsSummary)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        
        // Assert: encoding does not throw, output is non-empty, required keys exist
        XCTAssertFalse(data.isEmpty, "Encoded data should not be empty")
        
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["eventType"] as? String, "trace_start")  // pr85EventType maps to "eventType"
        XCTAssertEqual(json["entryType"] as? String, "trace_start")
        XCTAssertNotNil(json["traceId"])
        XCTAssertNotNil(json["buildMeta"])
    }
    
    // MARK: - Smoke Test 2: Validator Acceptance
    
    func test_smoke_minimalValidEntry_validates() {
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: "trace_start",
            detailsJson: nil,
            detailsSchemaVersion: "1.0",
            schemaVersion: 1,
            pr85EventType: .traceStart,
            entryType: "trace_start",
            actionType: nil,
            traceId: String(repeating: "a", count: 64),
            sceneId: String(repeating: "b", count: 64),
            eventId: String(repeating: "a", count: 64) + ":0",
            policyHash: makeTestPolicyHash(),
            pipelineVersion: "B1",
            inputs: [],
            paramsSummary: [:],
            metrics: nil,
            artifactRef: nil,
            buildMeta: makeTestBuildMeta()
        )
        
        let validator = TraceValidator()
        let error = validator.validate(entry)
        
        // Assert: validation passes without throwing
        XCTAssertNil(error, "Minimal valid entry should pass validation. Error: \(String(describing: error))")
    }
    
    // MARK: - Smoke Test 3: Intentional Failure
    
    func test_smoke_invalidSchemaVersion_rejected() {
        let entry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1000),
            eventType: "trace_start",
            detailsJson: nil,
            detailsSchemaVersion: "1.0",
            schemaVersion: 2,  // Invalid: must be 1
            pr85EventType: .traceStart,
            entryType: "trace_start",
            actionType: nil,
            traceId: String(repeating: "a", count: 64),
            sceneId: String(repeating: "b", count: 64),
            eventId: String(repeating: "a", count: 64) + ":0",
            policyHash: makeTestPolicyHash(),
            pipelineVersion: "B1",
            inputs: [],
            paramsSummary: [:],
            metrics: nil,
            artifactRef: nil,
            buildMeta: makeTestBuildMeta()
        )
        
        let validator = TraceValidator()
        let error = validator.validate(entry)
        
        // Assert: validation fails deterministically with expected error
        if case .some(.schemaVersionInvalid) = error {
            // Expected
        } else {
            XCTFail("Expected schemaVersionInvalid error, got: \(String(describing: error))")
        }
    }
}

