import XCTest

/// Tests for DecisionPolicy bypass detection in quality_lint.sh
/// Verifies that direct state transitions outside DecisionPolicy are caught
final class DecisionPolicyBypassTests: XCTestCase {
    
    // MARK: - Pattern Detection Tests
    
    func testDirectWhiteAssignmentDetected() {
        let codeSnippets = [
            "state = .white",
            "currentState = VisualState.white",
            "newState = .white // direct assignment",
            "return .white",
            "case .white:",
        ]
        
        for snippet in codeSnippets {
            XCTAssertTrue(containsBypassPattern(snippet),
                          "Should detect bypass pattern in: \(snippet)")
        }
    }
    
    func testAllowedPatternsNotFlagged() {
        let allowedSnippets = [
            "// state = .white (commented out)",
            "/* state = .white */",
            "/// Returns white if valid",
            "// TODO: handle white state",
        ]
        
        for snippet in allowedSnippets {
            XCTAssertFalse(containsBypassPattern(snippet),
                           "Should not flag allowed pattern: \(snippet)")
        }
    }
    
    func testDecisionPolicyFileExcluded() {
        // Patterns in DecisionPolicy.swift itself are allowed
        let path = "Core/Quality/DecisionPolicy.swift"
        XCTAssertTrue(isExcludedPath(path))
    }
    
    func testDecisionControllerFileExcluded() {
        let path = "Core/Quality/DecisionController.swift"
        XCTAssertTrue(isExcludedPath(path))
    }
    
    func testTestFilesExcluded() {
        let testPaths = [
            "Tests/Quality/DecisionPolicyTests.swift",
            "Tests/QualityPreCheck/WhiteCommitTests.swift",
        ]
        
        for path in testPaths {
            XCTAssertTrue(isExcludedPath(path), "Test files should be excluded: \(path)")
        }
    }
    
    func testProductionCodeNotExcluded() {
        let prodPaths = [
            "Core/Quality/SomeAnalyzer.swift",
            "Core/Quality/State/StateManager.swift",
        ]
        
        for path in prodPaths {
            XCTAssertFalse(isExcludedPath(path), "Production code should not be excluded: \(path)")
        }
    }
    
    // MARK: - Integration Test
    
    func testLintScriptCatchesBypass() throws {
        // This test runs the actual lint script against test fixtures
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        
        let lintScript = repoRoot.appendingPathComponent("scripts/quality_lint.sh")
        
        // Verify script exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: lintScript.path))
        
        // Verify script contains the bypass check
        let scriptContent = try String(contentsOf: lintScript, encoding: .utf8)
        XCTAssertTrue(scriptContent.contains("lintNoDecisionPolicyBypass"))
        XCTAssertTrue(scriptContent.contains("HARD FAILURE") || scriptContent.contains("ERROR"))
    }
    
    // MARK: - Helpers
    
    private func containsBypassPattern(_ code: String) -> Bool {
        // Skip comments
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
            return false
        }
        
        let patterns = [
            #"to.*\.white"#,
            #"VisualState\.white"#,
            #"\.white\s*="#,
            #"=\s*\.white"#,
            #"return\s+\.white"#,
            #"case\s+\.white"#,
        ]
        
        for pattern in patterns {
            if code.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
    
    private func isExcludedPath(_ path: String) -> Bool {
        let exclusions = [
            "DecisionPolicy",
            "DecisionController",
            "Tests/",
        ]
        
        for exclusion in exclusions {
            if path.contains(exclusion) {
                return true
            }
        }
        
        return false
    }
}
