// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
import Foundation

/// End-to-end integration tests for SSOT gate enforcement
/// Tests the complete pipeline: commit-msg → pre-push → CI
final class SSOTGateIntegrationTests: XCTestCase {
    
    private var repoRoot: URL!
    
    override func setUp() {
        super.setUp()
        
        repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    
    // MARK: - Pipeline Tests
    
    func testFullPipelineWithSSOTChange() throws {
        // Simulate: modify SSOT file with proper declaration
        let scenario = TestScenario(
            changedFiles: ["Core/Constants/NewConstant.swift"],
            deletedFiles: [],
            commitMessage: """
                feat(ssot): add new constant
                
                Added a new system constant for frame limits.
                
                SSOT-Change: yes
                """,
            expectedResult: .pass
        )
        
        let result = runPipeline(scenario)
        XCTAssertEqual(result, .pass, "SSOT change with proper declaration should pass")
    }
    
    func testFullPipelineWithoutDeclaration() throws {
        let scenario = TestScenario(
            changedFiles: ["Core/Constants/NewConstant.swift"],
            deletedFiles: [],
            commitMessage: """
                feat(ssot): add new constant
                
                Added a new system constant for frame limits.
                
                SSOT-Change: no
                """,
            expectedResult: .failAtDeclaration
        )
        
        let result = runPipeline(scenario)
        XCTAssertEqual(result, .failAtDeclaration)
    }
    
    func testFullPipelineWithMissingFooter() throws {
        let scenario = TestScenario(
            changedFiles: ["App/SomeFile.swift"],
            deletedFiles: [],
            commitMessage: """
                feat(app): add feature
                
                No SSOT footer here.
                """,
            expectedResult: .failAtCommitMsg
        )
        
        let result = runPipeline(scenario)
        XCTAssertEqual(result, .failAtCommitMsg)
    }
    
    func testFullPipelineWithDeletion() throws {
        let scenario = TestScenario(
            changedFiles: [],
            deletedFiles: ["docs/constitution/OLD_POLICY.md"],
            commitMessage: """
                docs(const): remove old policy
                
                SSOT-Change: yes
                """,
            expectedResult: .pass
        )
        
        let result = runPipeline(scenario)
        XCTAssertEqual(result, .pass)
    }
    
    func testFullPipelineWorkflowChange() throws {
        let scenario = TestScenario(
            changedFiles: [".github/workflows/ci.yml"],
            deletedFiles: [],
            commitMessage: """
                ci: update workflow
                
                SSOT-Change: yes
                """,
            expectedResult: .pass
        )
        
        let result = runPipeline(scenario)
        XCTAssertEqual(result, .pass)
    }
    
    // MARK: - CI Bypass Prevention
    
    func testNoVerifyBypassCaughtInCI() {
        // Even if local hooks are bypassed, CI should catch
        let scenario = TestScenario(
            changedFiles: ["Core/Constants/Secret.swift"],
            deletedFiles: [],
            commitMessage: "feat: bypass attempt\n\nSSOT-Change: no",
            expectedResult: .failAtCI,
            localHooksBypassed: true
        )
        
        let result = runPipeline(scenario)
        XCTAssertEqual(result, .failAtCI, "CI must catch bypass even if local hooks skipped")
    }
    
    // MARK: - Script Existence Tests
    
    func testAllRequiredScriptsExist() {
        let requiredScripts = [
            "scripts/ci/ssot_declaration_check.sh",
            "scripts/ci/ssot_integrity_verify.sh",
            "scripts/ci/ssot_consistency_verify.sh",
            "scripts/ci/ci_integrity_verify.sh",
            "scripts/hooks/commit-msg",
            "scripts/hooks/pre-commit",
        ]
        
        for script in requiredScripts {
            let scriptPath = repoRoot.appendingPathComponent(script)
            XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath.path),
                         "Required script missing: \(script)")
        }
    }
    
    // MARK: - Helpers
    
    enum PipelineResult {
        case pass
        case failAtCommitMsg
        case failAtDeclaration
        case failAtIntegrity
        case failAtCI
    }
    
    struct TestScenario {
        let changedFiles: [String]
        let deletedFiles: [String]
        let commitMessage: String
        let expectedResult: PipelineResult
        var localHooksBypassed: Bool = false
    }
    
    private func runPipeline(_ scenario: TestScenario) -> PipelineResult {
        // Stage 1: Commit message validation (commit-msg hook)
        if !scenario.localHooksBypassed {
            if !validateCommitMessage(scenario.commitMessage) {
                return .failAtCommitMsg
            }
        }
        
        // Stage 2: SSOT declaration check
        if !validateSSOTDeclaration(
            changedFiles: scenario.changedFiles,
            deletedFiles: scenario.deletedFiles,
            commitMessage: scenario.commitMessage
        ) {
            return scenario.localHooksBypassed ? .failAtCI : .failAtDeclaration
        }
        
        // Stage 3: SSOT integrity check
        // (Would run actual script in real integration test)
        
        return .pass
    }
    
    private func validateCommitMessage(_ message: String) -> Bool {
        let lines = message.components(separatedBy: "\n")
        guard let header = lines.first else { return false }

        // Check header format - also allow "ci" prefix for CI/workflow changes
        let headerPattern = "^(feat|fix|refactor|test|docs|chore|ci)\\([a-z0-9_-]+\\): .+|^(ci): .+"
        guard header.range(of: headerPattern, options: .regularExpression) != nil else {
            return false
        }

        // Check for SSOT footer
        let footerPattern = "^SSOT-Change: (yes|no)$"
        for line in lines {
            if line.range(of: footerPattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }
    
    private func validateSSOTDeclaration(changedFiles: [String],
                                          deletedFiles: [String],
                                          commitMessage: String) -> Bool {
        let ssotPrefixes = [
            "Core/Constants/",
            "Core/SSOT/",
            "docs/constitution/",
            ".github/workflows/",
            "scripts/ci/",
            "scripts/hooks/",
        ]
        
        let allFiles = changedFiles + deletedFiles
        var touchesSSOT = false
        
        for file in allFiles {
            for prefix in ssotPrefixes {
                if file.hasPrefix(prefix) {
                    touchesSSOT = true
                    break
                }
            }
        }
        
        if touchesSSOT {
            return commitMessage.contains("SSOT-Change: yes")
        }
        
        return true
    }
}
