// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SwiftSourceScannerTests.swift
// Aether3D
//
// Unit tests for SwiftSourceScanner.
// v5.1: Uses strictForTesting config.
//

import XCTest
@testable import Aether3DCore

final class SwiftSourceScannerTests: XCTestCase {
    func testScanNumberLiterals() {
        let content = """
        let x = 42
        let y = 3.14
        let z = 0xFF
        """
        
        let results = SwiftSourceScanner.scanNumberLiterals(
            in: content,
            config: .strictForTesting
        )
        
        XCTAssertEqual(results.count, 3, "Should find 3 number literals")
        XCTAssertTrue(results.contains { $0.value == "42" })
        XCTAssertTrue(results.contains { $0.value == "3.14" })
        XCTAssertTrue(results.contains { $0.value == "0xFF" })
    }
    
    func testScanIgnoresStrings() {
        let content = """
        let message = "The value is 42"
        let x = 100
        """
        
        let results = SwiftSourceScanner.scanNumberLiterals(
            in: content,
            config: .strictForTesting
        )
        
        // Should only find 100, not 42 (which is in a string)
        XCTAssertEqual(results.count, 1, "Should find 1 number literal")
        XCTAssertEqual(results.first?.value, "100")
    }
    
    func testScanIgnoresComments() {
        let content = """
        // This is 42 in a comment
        let x = 100
        """
        
        let results = SwiftSourceScanner.scanNumberLiterals(
            in: content,
            config: .strictForTesting
        )
        
        // Should only find 100, not 42 (which is in a comment)
        XCTAssertEqual(results.count, 1, "Should find 1 number literal")
        XCTAssertEqual(results.first?.value, "100")
    }
    
    func testScanRespectsExemption() {
        let content = """
        // SSOT_EXEMPTION
        let x = 42
        """
        
        let results = SwiftSourceScanner.scanNumberLiterals(
            in: content,
            config: .strictForTesting
        )
        
        // Should ignore 42 due to exemption
        XCTAssertEqual(results.count, 0, "Should find 0 number literals with exemption")
    }
    
    func testStrictConfigDoesNotAllowOne() {
        let content = """
        let x = 1
        """
        
        let results = SwiftSourceScanner.scanNumberLiterals(
            in: content,
            config: .strictForTesting
        )
        
        // Strict config should find "1" as a magic number
        XCTAssertEqual(results.count, 1, "Strict config should find '1' as magic number")
    }
}

