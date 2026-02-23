// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EnumFrozenOrderTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Enum Frozen Order Tests (B3)
//
// This test file validates that append-only enums maintain frozen case order.
//

import XCTest
@testable import Aether3DCore

/// Tests for enum frozen order hash validation (B3).
///
/// **Rule ID:** B3
/// **Status:** IMMUTABLE
///
/// These tests ensure that:
/// - Case order matches frozenCaseOrderHash
/// - Any reorder/rename/delete fails CI
/// - Only legal change: append new cases to the end
final class EnumFrozenOrderTests: XCTestCase {
    
    // MARK: - Helper Functions
    
    /// Computes frozen case order hash from enum cases.
    ///
    /// Format: "caseName=rawValue\ncaseName=rawValue\n..."
    /// Then SHA-256 hash.
    private func computeFrozenHash<T: CaseIterable & RawRepresentable>(
        _ type: T.Type
    ) -> String where T.RawValue == String {
        let cases = type.allCases
        let caseStrings = cases.map { "\($0)=\($0.rawValue)" }
        let joined = caseStrings.joined(separator: "\n")
        
        let data = Data(joined.utf8)
        return CryptoShim.sha256Hex(data)
    }
    
    // MARK: - EdgeCaseType Tests
    
    func test_edgeCaseType_frozenOrderHash_unchanged() {
        let computed = computeFrozenHash(EdgeCaseType.self)
        XCTAssertEqual(
            computed,
            EdgeCaseType.frozenCaseOrderHash,
            "EdgeCaseType case order changed. Only legal change: append new cases to the end."
        )
    }
    
    // MARK: - RiskFlag Tests
    
    func test_riskFlag_frozenOrderHash_unchanged() {
        let computed = computeFrozenHash(RiskFlag.self)
        XCTAssertEqual(
            computed,
            RiskFlag.frozenCaseOrderHash,
            "RiskFlag case order changed. Only legal change: append new cases to the end."
        )
    }
    
    // MARK: - PrimaryReasonCode Tests
    
    func test_primaryReasonCode_frozenOrderHash_unchanged() {
        let computed = computeFrozenHash(PrimaryReasonCode.self)
        XCTAssertEqual(
            computed,
            PrimaryReasonCode.frozenCaseOrderHash,
            "PrimaryReasonCode case order changed. Only legal change: append new cases to the end."
        )
    }
    
    // MARK: - ActionHintCode Tests
    
    func test_actionHintCode_frozenOrderHash_unchanged() {
        let computed = computeFrozenHash(ActionHintCode.self)
        XCTAssertEqual(
            computed,
            ActionHintCode.frozenCaseOrderHash,
            "ActionHintCode case order changed. Only legal change: append new cases to the end."
        )
    }
    
    // MARK: - RecordLifecycleEventType Tests (v1.1.1)
    
    func test_recordLifecycleEventType_frozenOrderHash_unchanged() {
        let computed = computeFrozenHash(RecordLifecycleEventType.self)
        XCTAssertEqual(
            computed,
            RecordLifecycleEventType.frozenCaseOrderHash,
            "RecordLifecycleEventType case order changed. Only legal change: append new cases to the end."
        )
    }
}
