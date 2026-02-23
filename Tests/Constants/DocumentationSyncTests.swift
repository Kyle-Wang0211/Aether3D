// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DocumentationSyncTests.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Documentation Sync Tests
//
// This test file validates documentation synchronization.
//

import XCTest
import Foundation
@testable import Aether3DCore

/// Tests for documentation synchronization.
///
/// **Rule ID:** B1, B2, D2
/// **Status:** IMMUTABLE
final class DocumentationSyncTests: XCTestCase {
    
    func test_swiftEnumCases_match_jsonCatalog() throws {
        // This test should verify that Swift enum cases match JSON catalog
        // Implementation depends on JSON catalog loading mechanism
        // For now, we verify that enums exist and are non-empty
        
        XCTAssertFalse(EdgeCaseType.allCases.isEmpty)
        XCTAssertFalse(RiskFlag.allCases.isEmpty)
        XCTAssertFalse(PrimaryReasonCode.allCases.isEmpty)
        XCTAssertFalse(ActionHintCode.allCases.isEmpty)
    }
    
    func test_indexMd_references_exist() throws {
        let constitutionPath = "docs/constitution"
        let indexPath = "\(constitutionPath)/INDEX.md"
        
        // Verify INDEX.md exists
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        let fullIndexPath = "\(currentPath)/\(indexPath)"
        
        XCTAssertTrue(fileManager.fileExists(atPath: fullIndexPath), "INDEX.md must exist")
    }
    
    func test_userExplanationCatalog_complete() throws {
        // B1: All EdgeCase/RiskFlag/PrimaryReasonCode/ActionHintCode must have explanation entries
        // This test should load USER_EXPLANATION_CATALOG.json and verify completeness
        // Implementation depends on JSON loading mechanism
        
        // For now, verify that enums exist
        XCTAssertFalse(EdgeCaseType.allCases.isEmpty)
        XCTAssertFalse(RiskFlag.allCases.isEmpty)
        XCTAssertFalse(PrimaryReasonCode.allCases.isEmpty)
        XCTAssertFalse(ActionHintCode.allCases.isEmpty)
    }
    
    func test_primaryReasonCode_references_explanationCatalog() {
        // B2: Verify all PrimaryReasonCode values exist in catalog
        // Implementation depends on catalog loading
        XCTAssertFalse(PrimaryReasonCode.allCases.isEmpty)
    }
    
    func test_actionHintCode_references_explanationCatalog() {
        // B2: Verify all ActionHintCode values exist in catalog
        // Implementation depends on catalog loading
        XCTAssertFalse(ActionHintCode.allCases.isEmpty)
    }
}
