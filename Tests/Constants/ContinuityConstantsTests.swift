// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ContinuityConstantsTests.swift
// Aether3D
//
// Tests for ContinuityConstants.
//

import XCTest
@testable import Aether3DCore

final class ContinuityConstantsTests: XCTestCase {
    
    func testMaxDeltaThetaDegPerFrame() {
        XCTAssertEqual(ContinuityConstants.maxDeltaThetaDegPerFrame, 30.0)
    }
    
    func testMaxDeltaTranslationMPerFrame() {
        XCTAssertEqual(ContinuityConstants.maxDeltaTranslationMPerFrame, 0.25)
    }
    
    func testFreezeWindowFrames() {
        XCTAssertEqual(ContinuityConstants.freezeWindowFrames, 20)
    }
    
    func testRecoveryStableFrames() {
        XCTAssertEqual(ContinuityConstants.recoveryStableFrames, 15)
    }
    
    func testRecoveryMaxDeltaThetaDegPerFrame() {
        XCTAssertEqual(ContinuityConstants.recoveryMaxDeltaThetaDegPerFrame, 15.0)
    }
    
    func testAllSpecsCount() {
        XCTAssertEqual(ContinuityConstants.allSpecs.count, 5)
    }
}

