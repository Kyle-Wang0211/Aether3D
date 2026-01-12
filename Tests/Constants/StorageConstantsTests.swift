//
// StorageConstantsTests.swift
// Aether3D
//
// Tests for StorageConstants.
//

import XCTest
@testable import Aether3DCore

final class StorageConstantsTests: XCTestCase {
    
    func testLowStorageWarningBytes() {
        XCTAssertEqual(StorageConstants.lowStorageWarningBytes, 1_610_612_736)
    }
    
    func testMaxAssetCount() {
        XCTAssertEqual(StorageConstants.maxAssetCount, .max)
    }
    
    func testAutoCleanupEnabled() {
        XCTAssertEqual(StorageConstants.autoCleanupEnabled, false)
    }
    
    func testAllSpecsCount() {
        XCTAssertEqual(StorageConstants.allSpecs.count, 3)
    }
}

