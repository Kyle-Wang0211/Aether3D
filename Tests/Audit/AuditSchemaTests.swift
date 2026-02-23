// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  AuditSchemaTests.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import XCTest
@testable import Aether3DCore

final class AuditSchemaTests: XCTestCase {
    func test_schemaVersion() {
        XCTAssertEqual(AuditSchema.version, "1.0")
    }
    
    func test_auditEntryCodableRoundtrip() throws {
        let entry = AuditEntry(
            timestamp: Date(),
            eventType: "test_event",
            detailsJson: "{\"key\":\"value\"}",
            detailsSchemaVersion: "1.0"
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuditEntry.self, from: data)
        
        XCTAssertEqual(decoded.eventType, entry.eventType)
        XCTAssertEqual(decoded.detailsJson, entry.detailsJson)
        XCTAssertEqual(decoded.detailsSchemaVersion, entry.detailsSchemaVersion)
        // ISO8601 编码可能丢失毫秒精度，使用 1 秒精度比较
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, entry.timestamp.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func test_auditEntryWithoutDetails() throws {
        let entry = AuditEntry(
            timestamp: Date(),
            eventType: "simple_event"
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuditEntry.self, from: data)
        
        XCTAssertEqual(decoded.eventType, entry.eventType)
        XCTAssertNil(decoded.detailsJson)
        XCTAssertEqual(decoded.detailsSchemaVersion, AuditSchema.version)
    }
}

