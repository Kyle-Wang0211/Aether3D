// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SmokeTests.swift
// Aether3D
//
// Critical path tests for SSOT system.
// PATCH E: Must test SSOT single entry point and selfCheck.
//

import XCTest
@testable import Aether3DCore

final class SmokeTests: XCTestCase {
    func testSSOTConstantsAccessible() {
        // Test system constants
        XCTAssertEqual(SSOT.maxFrames, 5000)
        XCTAssertEqual(SSOT.minFrames, 10)
        XCTAssertEqual(SSOT.maxGaussians, 1000000)
        
        // Test conversion constants
        XCTAssertEqual(SSOT.bytesPerKB, 1024)
        XCTAssertEqual(SSOT.bytesPerMB, 1048576)
        
        // Test quality thresholds
        XCTAssertEqual(SSOT.sfmRegistrationMinRatio, 0.75, accuracy: 0.001)
        XCTAssertEqual(SSOT.psnrMinDb, 30.0, accuracy: 0.001)
        XCTAssertEqual(SSOT.psnrWarnDb, 32.0, accuracy: 0.001)
    }
    
    func testSSOTErrorCodesAccessible() {
        // Test error codes through SSOT
        XCTAssertEqual(SSOT.errorInvalidSpec.stableName, "SSOT_INVALID_SPEC")
        XCTAssertEqual(SSOT.errorExceededMax.stableName, "SSOT_EXCEEDED_MAX")
        XCTAssertEqual(SSOT.errorUnderflowedMin.stableName, "SSOT_UNDERFLOWED_MIN")
        XCTAssertEqual(SSOT.errorAssertionFailed.stableName, "SSOT_ASSERTION_FAILED")
    }
    
    func testSSOTRegistryAccessible() {
        // Test registry access through SSOT
        let specs = SSOT.registry.allConstantSpecs
        XCTAssertFalse(specs.isEmpty)
        
        let errorCodes = SSOT.registry.allErrorCodes
        XCTAssertFalse(errorCodes.isEmpty)
    }
    
    func testSSOTRegistrySelfCheck() {
        // PATCH E: Must call selfCheck()
        let errors = SSOT.registry.selfCheck()
        XCTAssertTrue(errors.isEmpty, "Registry self-check failed: \(errors.joined(separator: "; "))")
    }
    
    func testSSOTErrorCreation() {
        let error = SSOTError(
            code: SSOT.errorInvalidSpec,
            context: ["ssotId": "test.id"]
        )
        XCTAssertEqual(error.code.stableName, "SSOT_INVALID_SPEC")
        XCTAssertFalse(error.context.isEmpty)
    }
    
    func testSSOTLogEventCreation() {
        let event = SSOTLogEvent(
            type: .violation,
            ssotId: "test.id",
            message: "Test message"
        )
        XCTAssertEqual(event.type, .violation)
        XCTAssertEqual(event.ssotId, "test.id")
        XCTAssertEqual(event.message, "Test message")
    }
    
    func testSSOTKeyRelationships() {
        // Verify key relationships are valid
        let spec = SystemConstants.maxFramesSpec
        XCTAssertEqual(spec.ssotId, "SystemConstants.maxFrames")
        XCTAssertEqual(spec.value, SystemConstants.maxFrames)
    }
}

