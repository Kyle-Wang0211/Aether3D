// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SQLitePlatformTests.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Cross-platform SQLite Tests
//  Validates SQLite linkage works identically on all platforms (CSQLite shim)
//

import XCTest
import CSQLite
@testable import Aether3DCore

final class SQLitePlatformTests: XCTestCase {
    
    /// Test SQLite library version is available
    /// Validates that sqlite3_libversion() returns a non-empty C string
    /// This is a minimal platform safety test that doesn't depend on filesystem
    func testSQLiteLibVersion() throws {
        guard let versionPtr = sqlite3_libversion() else {
            XCTFail("sqlite3_libversion() returned nil")
            return
        }
        
        let versionString = String(cString: versionPtr)
        XCTAssertFalse(versionString.isEmpty, "SQLite version string must not be empty")
        XCTAssertGreaterThan(versionString.count, 0, "SQLite version string must have content")
        
        // Version string should contain at least one digit (e.g., "3.x.x")
        let hasDigit = versionString.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        XCTAssertTrue(hasDigit, "SQLite version string should contain at least one digit")
    }
    
    /// Test SQLite version number is available
    /// Validates that sqlite3_libversion_number() returns a non-zero value
    /// This is deterministic and doesn't depend on filesystem
    func testSQLiteLibVersionNumber() throws {
        let versionNumber = sqlite3_libversion_number()
        XCTAssertGreaterThan(versionNumber, 0, "SQLite version number must be greater than 0")
        
        // SQLite 3.x versions should be >= 3000000 (3.0.0)
        XCTAssertGreaterThanOrEqual(versionNumber, 3000000, "SQLite version should be at least 3.0.0")
    }
    
    /// Test SQLite source ID is available
    /// Validates that sqlite3_sourceid() returns a non-empty C string
    /// This is deterministic and doesn't depend on filesystem
    func testSQLiteSourceID() throws {
        guard let sourceIdPtr = sqlite3_sourceid() else {
            XCTFail("sqlite3_sourceid() returned nil")
            return
        }
        
        let sourceIdString = String(cString: sourceIdPtr)
        XCTAssertFalse(sourceIdString.isEmpty, "SQLite source ID string must not be empty")
        XCTAssertGreaterThan(sourceIdString.count, 0, "SQLite source ID string must have content")
    }
}
