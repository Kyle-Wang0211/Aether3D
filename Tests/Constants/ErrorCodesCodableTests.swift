// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ErrorCodesCodableTests.swift
// Aether3D
//
// Tests for error code serialization stability.
//

import XCTest
@testable import Aether3DCore

final class ErrorCodesCodableTests: XCTestCase {
    func testErrorCodeCodable() throws {
        let code = ErrorCodes.S_INVALID_SPEC
        let encoder = SSOTEncoder()
        let data = try encoder.encode(code)
        
        let decoder = SSOTDecoder()
        let decoded = try decoder.decode(SSOTErrorCode.self, from: data)
        
        XCTAssertEqual(decoded.stableName, code.stableName)
        XCTAssertEqual(decoded.code, code.code)
        XCTAssertEqual(decoded.domain.id, code.domain.id)
    }
    
    func testErrorRecordCodable() throws {
        let error = SSOTError(
            code: ErrorCodes.S_INVALID_SPEC,
            context: ["ssotId": "test.id"]
        )
        let record = SSOTErrorRecord(from: error)
        
        let encoder = SSOTEncoder()
        let data = try encoder.encode(record)
        
        let decoder = SSOTDecoder()
        let decoded = try decoder.decode(SSOTErrorRecord.self, from: data)
        
        XCTAssertEqual(decoded.domainId, record.domainId)
        XCTAssertEqual(decoded.code, record.code)
        XCTAssertEqual(decoded.stableName, record.stableName)
        XCTAssertEqual(decoded.context, record.context)
    }
    
    func testAllErrorCodesCodable() throws {
        let encoder = SSOTEncoder()
        let decoder = SSOTDecoder()
        
        for code in ErrorCodes.all {
            let data = try encoder.encode(code)
            let decoded = try decoder.decode(SSOTErrorCode.self, from: data)
            
            XCTAssertEqual(decoded.stableName, code.stableName)
            XCTAssertEqual(decoded.code, code.code)
            XCTAssertEqual(decoded.domain.id, code.domain.id)
        }
    }
}

