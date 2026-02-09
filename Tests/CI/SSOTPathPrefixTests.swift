// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest

/// Tests for SSOT path prefix coverage
/// Verifies that all critical paths are protected
final class SSOTPathPrefixTests: XCTestCase {
    
    // Expected SSOT prefixes (must match script)
    let expectedPrefixes = [
        "Core/Constants/",
        "Core/SSOT/",
        "docs/constitution/",
        ".github/workflows/",
        "scripts/ci/",
        "scripts/hooks/",
    ]
    
    let expectedPatterns = [
        "Core/Models/Observation*.swift",
        "Core/Models/EvidenceEscalation*.swift",
    ]
    
    // MARK: - Prefix Coverage Tests
    
    func testCriticalPathsAreCovered() {
        let criticalPaths = [
            // Constants
            "Core/Constants/SSOT.swift",
            "Core/Constants/SystemConstants.swift",
            
            // SSOT module
            "Core/SSOT/EvidenceEscalationBoundary.swift",
            
            // Constitution docs
            "docs/constitution/GATES_POLICY.md",
            "docs/constitution/SSOT_CONSTANTS.md",
            
            // CI workflows
            ".github/workflows/ci.yml",
            ".github/workflows/quality_precheck.yml",
            
            // CI scripts
            "scripts/ci/03_require_ssot_declaration.sh",
            "scripts/ci/ssot_declaration_check.sh",
            
            // Hooks
            "scripts/hooks/pre-push",
            "scripts/hooks/commit-msg",
        ]
        
        for path in criticalPaths {
            XCTAssertTrue(isProtectedPath(path), "Critical path not protected: \(path)")
        }
    }
    
    func testObservationModelFilesAreCovered() {
        let observationFiles = [
            "Core/Models/ObservationModel.swift",
            "Core/Models/ObservationTypes.swift",
            "Core/Models/ObservationConstants.swift",
            "Core/Models/EvidenceEscalationBoundary.swift",
        ]
        
        for path in observationFiles {
            XCTAssertTrue(isProtectedPath(path), "Observation model file not protected: \(path)")
        }
    }
    
    func testNonSSOTPathsAreNotProtected() {
        let nonSSOTPaths = [
            "App/SomeViewController.swift",
            "Core/Services/NetworkService.swift",
            "Tests/UnitTests/SomeTests.swift",
            "README.md",
            "Package.swift",
        ]
        
        for path in nonSSOTPaths {
            XCTAssertFalse(isProtectedPath(path), "Non-SSOT path incorrectly protected: \(path)")
        }
    }
    
    func testEdgeCases() {
        // Subdirectories of protected paths
        XCTAssertTrue(isProtectedPath("Core/Constants/SubDir/File.swift"))
        XCTAssertTrue(isProtectedPath(".github/workflows/nested/workflow.yml"))
        
        // Similar but different paths
        XCTAssertFalse(isProtectedPath("Core/ConstantsExtra/File.swift"))
        XCTAssertFalse(isProtectedPath("docs/constitutionXYZ/File.md"))
        
        // Case sensitivity
        XCTAssertFalse(isProtectedPath("core/constants/file.swift")) // Different case
    }
    
    // MARK: - Script Consistency Test
    
    func testScriptHasExpectedPrefixes() throws {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        
        let scriptPath = repoRoot.appendingPathComponent("scripts/ci/ssot_declaration_check.sh")
        let scriptContent = try String(contentsOf: scriptPath, encoding: .utf8)
        
        for prefix in expectedPrefixes {
            XCTAssertTrue(scriptContent.contains("\"\(prefix)\""),
                          "Script missing expected prefix: \(prefix)")
        }
    }
    
    // MARK: - Helpers
    
    private func isProtectedPath(_ path: String) -> Bool {
        // Check prefixes
        for prefix in expectedPrefixes {
            if path.hasPrefix(prefix) {
                return true
            }
        }
        
        // Check patterns
        for pattern in expectedPatterns {
            if matchesPattern(path: path, pattern: pattern) {
                return true
            }
        }
        
        return false
    }
    
    private func matchesPattern(path: String, pattern: String) -> Bool {
        // Convert glob pattern to regex
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: "[^/]*")
        
        return path.range(of: "^\(regexPattern)$", options: .regularExpression) != nil
    }
}
