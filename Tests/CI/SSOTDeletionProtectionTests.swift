import XCTest
import Foundation

/// Tests for SSOT deletion protection
/// Verifies that deleting SSOT files requires SSOT-Change: yes
final class SSOTDeletionProtectionTests: XCTestCase {
    
    // MARK: - Deletion Detection Tests
    
    func testDeletingConstantsFileRequiresSSOTYes() {
        let deletedFiles = ["Core/Constants/OldConstant.swift"]
        let commitMessage = "chore: cleanup old constants\n\nSSOT-Change: no"
        
        let result = validateDeletion(deletedFiles: deletedFiles, commitMessage: commitMessage)
        
        XCTAssertFalse(result.passed, "Deleting Constants file without SSOT-Change: yes should fail")
        XCTAssertTrue(result.message.contains("SSOT") || result.message.contains("DELETION"))
    }
    
    func testDeletingConstantsFileWithSSOTYesPasses() {
        let deletedFiles = ["Core/Constants/OldConstant.swift"]
        let commitMessage = "chore: cleanup old constants\n\nSSOT-Change: yes"
        
        let result = validateDeletion(deletedFiles: deletedFiles, commitMessage: commitMessage)
        
        XCTAssertTrue(result.passed, "Deleting Constants file with SSOT-Change: yes should pass")
    }
    
    func testDeletingConstitutionDocRequiresSSOTYes() {
        let deletedFiles = ["docs/constitution/OLD_POLICY.md"]
        let commitMessage = "docs: remove outdated policy\n\nSSOT-Change: no"
        
        let result = validateDeletion(deletedFiles: deletedFiles, commitMessage: commitMessage)
        
        XCTAssertFalse(result.passed)
    }
    
    func testDeletingWorkflowRequiresSSOTYes() {
        let deletedFiles = [".github/workflows/old_ci.yml"]
        let commitMessage = "ci: remove old workflow\n\nSSOT-Change: no"
        
        let result = validateDeletion(deletedFiles: deletedFiles, commitMessage: commitMessage)
        
        XCTAssertFalse(result.passed)
    }
    
    func testDeletingNonSSOTFileAllowed() {
        let deletedFiles = ["App/OldFile.swift", "Tests/OldTest.swift"]
        let commitMessage = "chore: cleanup\n\nSSOT-Change: no"
        
        let result = validateDeletion(deletedFiles: deletedFiles, commitMessage: commitMessage)
        
        XCTAssertTrue(result.passed, "Deleting non-SSOT files should be allowed")
    }
    
    func testMultipleDeletesWithMixedPaths() {
        // Mixed: one SSOT, one non-SSOT
        let deletedFiles = ["App/OldFile.swift", "Core/Constants/Old.swift"]
        let commitMessage = "chore: cleanup\n\nSSOT-Change: no"
        
        let result = validateDeletion(deletedFiles: deletedFiles, commitMessage: commitMessage)
        
        XCTAssertFalse(result.passed, "Even one SSOT deletion requires SSOT-Change: yes")
    }
    
    // MARK: - Edge Cases
    
    func testEmptyDeleteListPasses() {
        let result = validateDeletion(deletedFiles: [], commitMessage: "feat: add\n\nSSOT-Change: no")
        XCTAssertTrue(result.passed)
    }
    
    func testDeleteWithRenamePattern() {
        // Git rename shows as delete + add
        let deletedFiles = ["Core/Constants/OldName.swift"]
        // Renames still require SSOT declaration
        let result = validateDeletion(deletedFiles: deletedFiles,
                                       commitMessage: "refactor: rename\n\nSSOT-Change: no")
        
        XCTAssertFalse(result.passed, "Renames involving SSOT files require declaration")
    }
    
    // MARK: - Helpers
    
    private func validateDeletion(deletedFiles: [String], commitMessage: String) -> (passed: Bool, message: String) {
        let ssotPrefixes = [
            "Core/Constants/",
            "Core/SSOT/",
            "docs/constitution/",
            ".github/workflows/",
            "scripts/ci/",
            "scripts/hooks/",
        ]
        
        var deletedSSOT = false
        var detectedFiles: [String] = []
        
        for file in deletedFiles {
            for prefix in ssotPrefixes {
                if file.hasPrefix(prefix) {
                    deletedSSOT = true
                    detectedFiles.append(file)
                    break
                }
            }
        }
        
        if deletedSSOT {
            // Check for SSOT-Change: yes
            if !commitMessage.contains("SSOT-Change: yes") {
                return (false, "SSOT DELETION DETECTED: \(detectedFiles)")
            }
        }
        
        return (true, "OK")
    }
}
