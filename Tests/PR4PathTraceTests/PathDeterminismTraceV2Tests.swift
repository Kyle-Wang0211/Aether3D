// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PathDeterminismTraceV2Tests.swift
// PR4PathTraceTests
//
// Tests for Path Trace V2
//

import XCTest
@testable import PR4PathTrace

final class PathDeterminismTraceV2Tests: XCTestCase {
    
    func testTokenRecording() {
        let trace = PathDeterminismTraceV2()
        trace.record(.gateEnabled)
        trace.record(.softmaxNormal)
        
        XCTAssertEqual(trace.path.count, 2)
        XCTAssertEqual(trace.path[0], .gateEnabled)
        XCTAssertEqual(trace.path[1], .softmaxNormal)
    }
    
    func testSignatureComputation() {
        let trace1 = PathDeterminismTraceV2()
        trace1.record(.gateEnabled)
        trace1.record(.softmaxNormal)
        
        let trace2 = PathDeterminismTraceV2()
        trace2.record(.gateEnabled)
        trace2.record(.softmaxNormal)
        
        // Same path should produce same signature
        XCTAssertEqual(trace1.signature, trace2.signature)
    }
    
    func testSerialization() {
        let trace = PathDeterminismTraceV2()
        trace.record(.gateEnabled)
        trace.record(.softmaxNormal)
        
        let serialized = trace.serialize()
        XCTAssertEqual(serialized.version, 2)
        XCTAssertEqual(serialized.tokens.count, 2)
        
        let deserialized = PathDeterminismTraceV2.deserialize(serialized)
        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized?.path.count, 2)
    }
    
    func testReset() {
        let trace = PathDeterminismTraceV2()
        trace.record(.gateEnabled)
        trace.reset()
        
        XCTAssertEqual(trace.path.count, 0)
    }
}
