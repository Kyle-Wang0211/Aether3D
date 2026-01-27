//
// EvidenceBudgetPolicyTests.swift
// Aether3D
//
// Tests for EvidenceBudgetPolicy (budget validation, profile mappings)
//

import XCTest
@testable import Aether3DCore

final class EvidenceBudgetPolicyTests: XCTestCase {
    
    // MARK: - Policy Existence Tests
    
    func testAllPoliciesExist() {
        let policies = EvidenceBudgetPolicy.allPolicies
        XCTAssertEqual(policies.count, CaptureProfile.allCases.count,
                      "Must have policy for each profile")
        
        for profile in CaptureProfile.allCases {
            let policy = EvidenceBudgetPolicy.policy(for: profile)
            XCTAssertEqual(policy.profileId, profile.profileId,
                          "Policy profileId must match for \(profile.name)")
        }
    }
    
    // MARK: - Budget Validation Tests
    
    func testPolicyBudgetsArePositive() {
        for profile in CaptureProfile.allCases {
            let policy = EvidenceBudgetPolicy.policy(for: profile)
            
            XCTAssertGreaterThan(policy.maxCells, 0,
                                "maxCells must be positive for \(profile.name)")
            XCTAssertGreaterThan(policy.maxPatches, 0,
                                "maxPatches must be positive for \(profile.name)")
            XCTAssertGreaterThan(policy.maxEvidenceEvents, 0,
                                "maxEvidenceEvents must be positive for \(profile.name)")
            XCTAssertGreaterThan(policy.maxAuditBytes, 0,
                                "maxAuditBytes must be positive for \(profile.name)")
        }
    }
    
    func testPolicyBudgetsAreReasonable() {
        for profile in CaptureProfile.allCases {
            let policy = EvidenceBudgetPolicy.policy(for: profile)
            
            // Budgets should be finite and not excessive
            XCTAssertLessThan(policy.maxCells, Int.max / 2,
                            "maxCells should be reasonable for \(profile.name)")
            XCTAssertLessThan(policy.maxPatches, Int.max / 2,
                            "maxPatches should be reasonable for \(profile.name)")
            XCTAssertLessThan(policy.maxEvidenceEvents, Int.max / 2,
                            "maxEvidenceEvents should be reasonable for \(profile.name)")
            XCTAssertLessThan(policy.maxAuditBytes, Int64.max / 2,
                            "maxAuditBytes should be reasonable for \(profile.name)")
        }
    }
    
    func testPolicyDocumentationExplainsRationale() {
        for profile in CaptureProfile.allCases {
            let policy = EvidenceBudgetPolicy.policy(for: profile)
            
            // Documentation must not be empty
            XCTAssertFalse(policy.documentation.isEmpty,
                         "Documentation must not be empty for \(profile.name)")
            
            // Documentation should explain something (not just be a placeholder)
            XCTAssertGreaterThan(policy.documentation.count, 10,
                               "Documentation should be meaningful for \(profile.name)")
        }
    }
    
    func testPolicySchemaVersionIdMatches() {
        for policy in EvidenceBudgetPolicy.allPolicies {
            XCTAssertEqual(policy.schemaVersionId, SSOTVersion.schemaVersionId,
                          "Policy schemaVersionId must match SSOTVersion")
        }
    }
    
    // MARK: - Profile-Specific Budget Tests
    
    func testSmallObjectMacroHasHigherBudgets() {
        let macroPolicy = EvidenceBudgetPolicy.policy(for: .smallObjectMacro)
        let standardPolicy = EvidenceBudgetPolicy.policy(for: .standard)
        
        // Macro profile may need higher budgets due to finer resolution
        XCTAssertGreaterThanOrEqual(macroPolicy.maxCells, standardPolicy.maxCells,
                                   "Macro profile may need >= cells")
    }
    
    // MARK: - Digest Input Tests
    
    func testDigestInput() throws {
        let digestInput = EvidenceBudgetPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.schemaVersionId, SSOTVersion.schemaVersionId)
        XCTAssertEqual(digestInput.policies.count, CaptureProfile.allCases.count)
    }
    
    func testDigestInputDeterministic() throws {
        let digest1 = try CanonicalDigest.computeDigest(
            EvidenceBudgetPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        let digest2 = try CanonicalDigest.computeDigest(
            EvidenceBudgetPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        XCTAssertEqual(digest1, digest2, "Digest must be deterministic")
    }
    
    func testDigestInputContainsAllProfiles() throws {
        let digestInput = EvidenceBudgetPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        
        var profileIds: Set<UInt8> = []
        for policy in digestInput.policies {
            XCTAssertFalse(profileIds.contains(policy.profileId),
                          "Duplicate profileId: \(policy.profileId)")
            profileIds.insert(policy.profileId)
        }
        
        XCTAssertEqual(profileIds.count, CaptureProfile.allCases.count,
                      "Must include all profiles")
    }
    
    // MARK: - Budget Blow-Up Prevention
    
    func testBudgetBlowUpPrevention() throws {
        // This test prevents budgets from silently increasing beyond 2x threshold
        // If budgets increase significantly, it must be intentional and documented
        
        // Load golden digest for EvidenceBudgetPolicy
        let repoRoot = findRepoRoot()
        let goldenDigests = try SSOTVersion.loadGoldenPolicyDigests(repoRoot: repoRoot)
        
        guard let goldenBudgetDigest = goldenDigests["EvidenceBudgetPolicy"] else {
            XCTFail("Missing EvidenceBudgetPolicy digest in golden file")
            return
        }
        
        // Compute current digest
        let currentDigest = try CanonicalDigest.computeDigest(
            EvidenceBudgetPolicy.digestInput(schemaVersionId: SSOTVersion.schemaVersionId)
        )
        
        // If digests differ, check if budgets increased significantly
        if currentDigest != goldenBudgetDigest {
            // Compare actual budget values
            var maxIncreaseRatio: Double = 1.0
            var increasedProfile: String? = nil
            
            // Load old budgets from golden (if available) and compare
            // For now, we'll check if any budget exceeds reasonable thresholds
            for profile in CaptureProfile.allCases {
                let policy = EvidenceBudgetPolicy.policy(for: profile)
                
                // Define reasonable maximum thresholds (2x typical values)
                let maxReasonableCells = 10_000_000  // 10M cells
                let maxReasonablePatches = 5_000_000  // 5M patches
                let maxReasonableEvents = 1_000_000  // 1M events
                let maxReasonableBytes: Int64 = 1_000_000_000  // 1GB
                
                if policy.maxCells > maxReasonableCells ||
                   policy.maxPatches > maxReasonablePatches ||
                   policy.maxEvidenceEvents > maxReasonableEvents ||
                   policy.maxAuditBytes > maxReasonableBytes {
                    increasedProfile = profile.name
                    break
                }
            }
            
            if let profile = increasedProfile {
                XCTFail("""
                    Budget blow-up detected for profile: \(profile)
                    
                    EvidenceBudgetPolicy digest changed and budgets exceed 2x threshold.
                    This requires explicit acknowledgment:
                    1. Create/update RFC file in docs/rfcs/ describing budget increase
                    2. Update golden file: ./scripts/update_golden_policy_digests.sh
                    3. Document rationale in RFC
                    
                    Current digest: \(currentDigest)
                    Golden digest: \(goldenBudgetDigest)
                    """)
            }
        }
        
        // Always verify current digest matches golden (or golden needs update)
        XCTAssertEqual(currentDigest, goldenBudgetDigest,
                      """
                      EvidenceBudgetPolicy digest mismatch.
                      If intentional budget change: update golden file and document in RFC.
                      Run: ./scripts/update_golden_policy_digests.sh
                      """)
    }
    
    // Helper to find repo root (for golden file loading)
    private func findRepoRoot() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--show-toplevel"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let root = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !root.isEmpty {
                    return root
                }
            }
        } catch {
            // Fall through
        }
        
        // Fallback: walk up from test file
        let testFile = #filePath
        var currentDir = (testFile as NSString).deletingLastPathComponent
        while currentDir != "/" {
            let packagePath = "\(currentDir)/Package.swift"
            if FileManager.default.fileExists(atPath: packagePath) {
                return currentDir
            }
            currentDir = (currentDir as NSString).deletingLastPathComponent
        }
        
        fatalError("Could not find repository root")
    }
}
