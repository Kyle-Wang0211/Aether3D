// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EnumUnknownHandlingTests.swift
// Aether3D
//
// PR2 Patch V4 - Enum Unknown Value Handling Tests
//

import XCTest
@testable import Aether3DCore

final class EnumUnknownHandlingTests: XCTestCase {
    
    // MARK: - ObservationVerdict Tests
    
    func testObservationVerdictUnknownDecoding() throws {
        // Decode unknown value
        let unknownJSON = "\"invalid_verdict\""
        let data = unknownJSON.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let verdict = try decoder.decode(ObservationVerdict.self, from: data)
        
        // Should default to .unknown
        XCTAssertEqual(verdict, .unknown, "Unknown verdict should decode to .unknown")
    }
    
    func testObservationVerdictRoundTrip() throws {
        let verdicts: [ObservationVerdict] = [.good, .suspect, .bad]
        
        for verdict in verdicts {
            let encoder = JSONEncoder()
            let data = try encoder.encode(verdict)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ObservationVerdict.self, from: data)
            
            XCTAssertEqual(decoded, verdict, "Round-trip should preserve verdict")
        }
    }
    
    // MARK: - ColorState Tests
    
    func testColorStateUnknownDecoding() throws {
        let unknownJSON = "\"invalid_color\""
        let data = unknownJSON.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let colorState = try decoder.decode(ColorState.self, from: data)
        
        // Should default to .unknown
        XCTAssertEqual(colorState, .unknown, "Unknown ColorState should decode to .unknown")
    }
    
    func testColorStateRoundTrip() throws {
        let states: [ColorState] = [.black, .darkGray, .lightGray, .white, .original]
        
        for state in states {
            let encoder = JSONEncoder()
            let data = try encoder.encode(state)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ColorState.self, from: data)
            
            XCTAssertEqual(decoded, state, "Round-trip should preserve ColorState")
        }
    }
    
    // MARK: - ObservationErrorType Tests
    
    func testObservationErrorTypeUnknownDecoding() throws {
        let unknownJSON = "\"invalid_error\""
        let data = unknownJSON.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let errorType = try decoder.decode(ObservationErrorType.self, from: data)
        
        // Should default to .unknown
        XCTAssertEqual(errorType, .unknown, "Unknown ObservationErrorType should decode to .unknown")
    }
    
    func testObservationErrorTypeRoundTrip() throws {
        let errorTypes: [ObservationErrorType] = [
            .dynamicObject,
            .depthDistortion,
            .exposureDrift,
            .whiteBalanceDrift,
            .motionBlur
        ]
        
        for errorType in errorTypes {
            let encoder = JSONEncoder()
            let data = try encoder.encode(errorType)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ObservationErrorType.self, from: data)
            
            XCTAssertEqual(decoded, errorType, "Round-trip should preserve ObservationErrorType")
        }
    }
    
    // MARK: - ReasonCode Tests
    
    func testReasonCodeUnknownDecoding() throws {
        let unknownJSON = "\"invalid_reason\""
        let data = unknownJSON.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let reasonCode = try decoder.decode(ObservationVerdict.Reason.ReasonCode.self, from: data)
        
        // Should default to .unknown
        XCTAssertEqual(reasonCode, .unknown, "Unknown ReasonCode should decode to .unknown")
    }
    
    // MARK: - Deterministic Behavior Tests
    
    func testUnknownDecodingIsDeterministic() throws {
        let unknownJSON = "\"some_unknown_value\""
        let data = unknownJSON.data(using: .utf8)!
        
        var results: Set<ObservationVerdict> = []
        
        // Decode multiple times
        for _ in 0..<100 {
            let decoder = JSONDecoder()
            let verdict = try decoder.decode(ObservationVerdict.self, from: data)
            results.insert(verdict)
        }
        
        // Should always produce same result
        XCTAssertEqual(results.count, 1, "Unknown decoding should be deterministic")
        XCTAssertEqual(results.first, .unknown, "Should always decode to .unknown")
    }
}
