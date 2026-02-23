// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ThrowPatternScanTests.swift
// Aether3D
//
// Tests for throw pattern detection.
//

import XCTest
@testable import Aether3DCore

final class ThrowPatternScanTests: XCTestCase {
    
    func test_scan_throwUsesSSOTError() throws {
        let constantsURL = try RepoRootLocator.directoryURL(for: "Core/Constants")
        
        let enumerator = FileManager.default.enumerator(
            at: constantsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        
        var violations: [String] = []
        
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                
                // Check for throw that doesn't use SSOTError
                // Allow standard library errors (DecodingError, EncodingError, etc.)
                // Allow SSOT-related errors (CanonicalDigestError, SSOTVersionError, etc.)
                if line.contains("throw ") && 
                   !line.contains("SSOTError") && 
                   !line.contains("CanonicalDigestError") &&
                   !line.contains("SSOTVersionError") &&
                   !line.contains("XCTSkip") &&
                   !line.contains("DecodingError") &&
                   !line.contains("EncodingError") &&
                   !line.contains("NSError") {
                    violations.append("\(url.lastPathComponent):\(index + 1): throw should use SSOTError or SSOT-related error")
                }
            }
        }
        
        XCTAssertTrue(violations.isEmpty, "Non-SSOT throws:\n\(violations.joined(separator: "\n"))")
    }
}

