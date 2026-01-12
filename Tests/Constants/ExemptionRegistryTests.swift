//
// ExemptionRegistryTests.swift
// Aether3D
//
// Tests for exemption registry.
//

import XCTest
@testable import Aether3DCore

final class ExemptionRegistryTests: XCTestCase {
    
    func test_exemptionFileExists() throws {
        let url = try RepoRootLocator.fileURL(for: "docs/constitution/SSOT_EXEMPTIONS.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "SSOT_EXEMPTIONS.md must exist"
        )
    }
    
    func test_exemptionFileHasRequiredBlocks() throws {
        let url = try RepoRootLocator.fileURL(for: "docs/constitution/SSOT_EXEMPTIONS.md")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("File not yet created")
        }
        
        let content = try String(contentsOf: url, encoding: .utf8)
        
        XCTAssertTrue(
            content.contains("<!-- SSOT:EXEMPTIONS:BEGIN -->"),
            "EXEMPTIONS block required"
        )
    }
}

