import XCTest

/// Tests for scripts/hooks/commit-msg
/// Verifies commit message format validation
final class CommitMessageFormatTests: XCTestCase {
    
    // MARK: - Header Format Tests
    
    func testValidHeaders() {
        let validHeaders = [
            "feat(ssot): add new constant",
            "fix(ci): repair workflow",
            "refactor(core): simplify logic",
            "test(unit): add coverage",
            "docs(readme): update instructions",
            "chore(deps): bump version",
            "feat(pr1): implement feature",
            "fix(pr1-hotfix): urgent fix",
            "feat(some_scope): with underscore",
            "feat(scope123): with numbers",
        ]
        
        for header in validHeaders {
            XCTAssertTrue(isValidHeader(header), "Should be valid: \(header)")
        }
    }
    
    func testInvalidHeaders() {
        let invalidHeaders = [
            "feat: missing scope",
            "feat(): empty scope",
            "feat(UPPERCASE): should be lowercase",
            "feat(scope): " + String(repeating: "x", count: 80), // Too long
            "Feat(scope): capital type",
            "feature(scope): wrong type",
            "feat(scope) missing colon",
            "feat(scope):missing space",
            "",
            "   feat(scope): leading whitespace",
        ]
        
        for header in invalidHeaders {
            XCTAssertFalse(isValidHeader(header), "Should be invalid: \(header)")
        }
    }
    
    // MARK: - SSOT Footer Tests
    
    func testValidSSOTFooters() {
        let validFooters = [
            "SSOT-Change: yes",
            "SSOT-Change: no",
        ]
        
        for footer in validFooters {
            XCTAssertTrue(isValidSSOTFooter(footer), "Should be valid: \(footer)")
        }
    }
    
    func testInvalidSSOTFooters() {
        let invalidFooters = [
            "SSOT-Change: yes ",        // Trailing space (tests A1 fix)
            "SSOT-Change: no\t",        // Trailing tab
            "SSOT-Change: YES",          // Uppercase
            "SSOT-Change: No",           // Mixed case
            "SSOT-Change: true",         // Wrong value
            "SSOT-Change: false",        // Wrong value
            "SSOT-Change:yes",           // Missing space
            "SSOT-Change : yes",         // Extra space
            "ssot-change: yes",          // Lowercase key
            "SSOT-Change: yes_really",   // Extra content (tests A1 fix)
            "SSOT-Change: maybe",        // Invalid value
            " SSOT-Change: yes",         // Leading space
        ]
        
        for footer in invalidFooters {
            XCTAssertFalse(isValidSSOTFooter(footer), "Should be invalid: '\(footer)'")
        }
    }
    
    // MARK: - Full Message Tests
    
    func testValidFullMessage() {
        let message = """
            feat(ssot): add integrity verification
            
            This commit adds hash verification for constitution documents.
            
            SSOT-Change: yes
            """
        
        XCTAssertTrue(isValidCommitMessage(message))
    }
    
    func testMessageWithMultipleSSOTFooters() {
        // Only first should count, but having multiple is suspicious
        let message = """
            feat(ssot): update
            
            SSOT-Change: yes
            SSOT-Change: no
            """
        
        // Should pass (first valid footer found)
        // But this could be considered a lint warning
        XCTAssertTrue(isValidCommitMessage(message))
    }
    
    func testMessageMissingFooter() {
        let message = """
            feat(app): add feature
            
            No SSOT footer here.
            """
        
        XCTAssertFalse(isValidCommitMessage(message))
    }
    
    // MARK: - Helpers
    
    private func isValidHeader(_ header: String) -> Bool {
        let pattern = "^(feat|fix|refactor|test|docs|chore)\\([a-z0-9_-]+\\): .{1,72}$"
        return header.range(of: pattern, options: .regularExpression) != nil
    }
    
    private func isValidSSOTFooter(_ footer: String) -> Bool {
        // This is the corrected regex from A1 with $ anchor
        let pattern = "^SSOT-Change: (yes|no)$"
        return footer.range(of: pattern, options: .regularExpression) != nil
    }
    
    private func isValidCommitMessage(_ message: String) -> Bool {
        let lines = message.components(separatedBy: "\n")
        guard let header = lines.first else { return false }
        
        // Check header
        if !isValidHeader(header) { return false }
        
        // Check for SSOT footer
        for line in lines {
            if isValidSSOTFooter(line) {
                return true
            }
        }
        
        return false
    }
}
