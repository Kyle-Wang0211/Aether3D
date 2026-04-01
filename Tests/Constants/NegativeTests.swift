// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// NegativeTests.swift
// Aether3D
//
// Negative tests (must fail if invariants are violated)
//

import XCTest
@testable import Aether3DCore

final class NegativeTests: XCTestCase {
    
    // MARK: - Closed Set Violation Tests
    
    func testResolutionNotInClosedSet() {
        let invalidResolution = LengthQ(scaleId: .geomId, quanta: 999)  // Not in closed set
        
        XCTAssertFalse(GridResolutionPolicy.validateResolution(invalidResolution),
                      "Resolution not in closed set should be rejected")
    }
    
    func testResolutionNotAllowedForProfile() {
        let resolution = LengthQ(scaleId: .geomId, quanta: 50)  // 5cm
        let profile = CaptureProfile.smallObjectMacro
        
        // 5cm might not be in smallObjectMacro's allowed set
        let allowed = GridResolutionPolicy.allowedResolutions(for: profile)
        if !allowed.contains(resolution) {
            XCTAssertFalse(GridResolutionPolicy.validateResolution(resolution, for: profile),
                          "Resolution not allowed for profile should be rejected")
        }
    }
}
