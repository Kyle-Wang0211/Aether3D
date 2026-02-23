// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DocumentConsistencyTests.swift
// Aether3D
//
// Tests for document-code synchronization.
//

import XCTest
@testable import Aether3DCore

final class DocumentConsistencyTests: XCTestCase {
    
    var docContent: String!
    
    override func setUpWithError() throws {
        let docURL = try RepoRootLocator.fileURL(for: "docs/constitution/SSOT_CONSTANTS.md")
        
        guard FileManager.default.fileExists(atPath: docURL.path) else {
            throw XCTSkip("Document not yet created")
        }
        
        docContent = try String(contentsOf: docURL, encoding: .utf8)
    }
    
    func test_doc_hasVersionBlock() {
        XCTAssertTrue(
            docContent.contains("<!-- SSOT:VERSION:BEGIN -->"),
            "VERSION block must exist"
        )
        XCTAssertTrue(
            docContent.contains("<!-- SSOT:VERSION:END -->"),
            "VERSION block must be closed"
        )
    }
    
    func test_doc_hasErrorCodesBlock() {
        XCTAssertTrue(
            docContent.contains("<!-- SSOT:ERRORCODES:BEGIN -->"),
            "ERRORCODES block must exist"
        )
    }
    
    func test_doc_errorCodeCountMatches() throws {
        // Extract error code table from doc
        let pattern = #"\| ([A-Z_]+) \| (\w+) \| (\d+) \|"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(docContent.startIndex..., in: docContent)
        let matches = regex.matches(in: docContent, range: range)
        
        // Should match code count (allowing some variance for header rows)
        let docCodeCount = matches.count
        let actualCodeCount = SSOTRegistry.allErrorCodes.count
        
        XCTAssertEqual(
            docCodeCount,
            actualCodeCount,
            "Document has \(docCodeCount) codes, registry has \(actualCodeCount)"
        )
    }
    
    func test_doc_allStableNamesPresent() {
        for code in SSOTRegistry.allErrorCodes {
            XCTAssertTrue(
                docContent.contains(code.stableName),
                "Missing \(code.stableName) in document"
            )
        }
    }
}

