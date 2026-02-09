// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CapacityLimitConstants Contract Tests
// PR1 C-Class: Ensures capacity constants remain stable
// ============================================================================

import XCTest
@testable import Aether3DCore

/// Contract tests for CapacityLimitConstants
/// 
/// These tests enforce that capacity control constants match expected values exactly.
/// This prevents silent drift in capacity control thresholds.
final class CapacityLimitConstantsContractTests: XCTestCase {
    
    func testSoftLimitPatchCount() {
        XCTAssertEqual(
            CapacityLimitConstants.SOFT_LIMIT_PATCH_COUNT,
            5000,
            "SOFT_LIMIT_PATCH_COUNT must be exactly 5000"
        )
    }
    
    func testHardLimitPatchCount() {
        XCTAssertEqual(
            CapacityLimitConstants.HARD_LIMIT_PATCH_COUNT,
            8000,
            "HARD_LIMIT_PATCH_COUNT must be exactly 8000"
        )
    }
    
    func testEebBaseBudget() {
        XCTAssertEqual(
            CapacityLimitConstants.EEB_BASE_BUDGET,
            10000.0,
            accuracy: 0.001,
            "EEB_BASE_BUDGET must be exactly 10000.0"
        )
    }
}
