//
// GoldenDigestTests.swift
// Aether3D
//
// Tests for golden digest verification (H3: filesystem-based loading)
//

import XCTest
@testable import Aether3DCore

final class GoldenDigestTests: XCTestCase {
    
    // MARK: - Repo Root Detection
    
    func findRepoRoot() -> String {
        // Try git rev-parse first
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
            // Fall through to walking
        }
        
        // Fallback: walk up from test file location
        let testFile = #filePath
        var currentDir = (testFile as NSString).deletingLastPathComponent
        while currentDir != "/" {
            let packagePath = "\(currentDir)/Package.swift"
            if FileManager.default.fileExists(atPath: packagePath) {
                return currentDir
            }
            currentDir = (currentDir as NSString).deletingLastPathComponent
        }
        
        XCTFail("Could not find repository root")
        return ""
    }
    
    // MARK: - Golden File Loading
    
    func testLoadGoldenPolicyDigests() throws {
        let repoRoot = findRepoRoot()
        let digests = try SSOTVersion.loadGoldenPolicyDigests(repoRoot: repoRoot)
        
        XCTAssertFalse(digests.isEmpty, "Golden file must contain policy digests")
        
        // Verify expected keys exist
        XCTAssertTrue(digests.keys.contains { $0.contains("CaptureProfile") },
                     "Must contain CaptureProfile digests")
        XCTAssertTrue(digests.keys.contains { $0.contains("GridResolutionPolicy") },
                     "Must contain GridResolutionPolicy digest")
    }
    
    func testGoldenFileGeneratorSignature() throws {
        let repoRoot = findRepoRoot()
        let goldenPath = "\(repoRoot)/Tests/Golden/policy_digests.json"
        
        guard let goldenData = try? Data(contentsOf: URL(fileURLWithPath: goldenPath)),
              let goldenJson = try? JSONSerialization.jsonObject(with: goldenData) as? [String: Any],
              let generatorSignature = goldenJson["generatorSignature"] as? String else {
            XCTFail("Golden file missing generatorSignature. Run scripts/update_golden_policy_digests.sh")
            return
        }
        
        // Verify signature matches expected value (computed from generator version)
        let expectedGeneratorVersion = "UpdateGoldenDigests-v1.0-CanonicalDigest"
        let expectedSignature = try CanonicalDigest.computeDigest(expectedGeneratorVersion)
        
        XCTAssertEqual(generatorSignature, expectedSignature,
                      "Golden file generatorSignature mismatch. File may have been manually edited. Run scripts/update_golden_policy_digests.sh to regenerate.")
    }
    
    func testLoadEnvelopeDigest() throws {
        let repoRoot = findRepoRoot()
        let envelopeDigest = try SSOTVersion.loadEnvelopeDigest(repoRoot: repoRoot)
        
        XCTAssertFalse(envelopeDigest.isEmpty, "Envelope digest must be present")
        XCTAssertEqual(envelopeDigest.count, 64, "Envelope digest must be SHA-256 hex string")
    }
    
    // MARK: - Golden Digest Matching
    
    func testPolicyDigestsMatchGolden() throws {
        let repoRoot = findRepoRoot()
        let goldenDigests = try SSOTVersion.loadGoldenPolicyDigests(repoRoot: repoRoot)
        let schemaVersionId = SSOTVersion.schemaVersionId
        
        // Compute current digests
        var currentDigests: [String: String] = [:]
        
        // CaptureProfile digests
        for profile in CaptureProfile.allCases {
            let digestInput = profile.digestInput(schemaVersionId: schemaVersionId)
            let digest = try CanonicalDigest.computeDigest(digestInput)
            currentDigests["CaptureProfile.\(profile.name)"] = digest
        }
        
        // GridResolutionPolicy
        let gridDigest = try CanonicalDigest.computeDigest(
            GridResolutionPolicy.digestInput(schemaVersionId: schemaVersionId)
        )
        currentDigests["GridResolutionPolicy"] = gridDigest
        
        // PatchPolicy
        let patchDigest = try CanonicalDigest.computeDigest(
            PatchPolicy.digestInput(schemaVersionId: schemaVersionId)
        )
        currentDigests["PatchPolicy"] = patchDigest
        
        // CoveragePolicy
        let coverageDigest = try CanonicalDigest.computeDigest(
            CoveragePolicy.digestInput(schemaVersionId: schemaVersionId)
        )
        currentDigests["CoveragePolicy"] = coverageDigest
        
        // EvidenceBudgetPolicy
        let budgetDigest = try CanonicalDigest.computeDigest(
            EvidenceBudgetPolicy.digestInput(schemaVersionId: schemaVersionId)
        )
        currentDigests["EvidenceBudgetPolicy"] = budgetDigest
        
        // DisplayPolicy
        let displayDigest = try CanonicalDigest.computeDigest(
            DisplayPolicy.digestInput(schemaVersionId: schemaVersionId)
        )
        currentDigests["DisplayPolicy"] = displayDigest
        
        // Compare with golden
        for (key, currentDigest) in currentDigests {
            if let goldenDigest = goldenDigests[key] {
                XCTAssertEqual(currentDigest, goldenDigest,
                              "Policy digest mismatch for \(key). Run scripts/update_golden_policy_digests.sh to update.")
            } else {
                XCTFail("Missing golden digest for \(key). Run scripts/update_golden_policy_digests.sh to generate.")
            }
        }
    }
    
    func testEnvelopeDigestMatchesGolden() throws {
        let repoRoot = findRepoRoot()
        let goldenEnvelope = try SSOTVersion.loadEnvelopeDigest(repoRoot: repoRoot)
        
        // Compute current envelope digest
        // This matches the logic in UpdateGoldenDigests
        struct EnvelopeInput: Codable {
            let systemMinimumQuantum: LengthQ.DigestInput
            let recommendedCaptureFloors: [KeyedValue<UInt8, LengthQ.DigestInput>]
            let allowedGridResolutions: [KeyedValue<UInt8, [LengthQ.DigestInput]>]
            let budgets: [KeyedValue<UInt8, BudgetInput>]
            let schemaVersionId: UInt16
        }
        
        struct BudgetInput: Codable {
            let maxCells: Int
            let maxPatches: Int
            let maxEvidenceEvents: Int
            let maxAuditBytes: Int64
        }
        
        var recommendedFloorsArr: [KeyedValue<UInt8, LengthQ.DigestInput>] = []
        var allowedResolutionsArr: [KeyedValue<UInt8, [LengthQ.DigestInput]>] = []
        var budgetsArr: [KeyedValue<UInt8, BudgetInput>] = []
        
        // Use stable order (sorted by profileId) to ensure deterministic dictionary encoding
        let profiles = CaptureProfile.allCases.sorted { $0.profileId < $1.profileId }
        for profile in profiles {
            let floor = GridResolutionPolicy.recommendedCaptureFloor(for: profile)
            recommendedFloorsArr.append(KeyedValue(key: profile.profileId, value: floor.digestInput()))
            
            let resolutions = GridResolutionPolicy.allowedResolutions(for: profile)
            allowedResolutionsArr.append(KeyedValue(key: profile.profileId, value: resolutions.map { $0.digestInput() }))
            
            let budget = EvidenceBudgetPolicy.policy(for: profile)
            budgetsArr.append(KeyedValue(key: profile.profileId, value: BudgetInput(
                maxCells: budget.maxCells,
                maxPatches: budget.maxPatches,
                maxEvidenceEvents: budget.maxEvidenceEvents,
                maxAuditBytes: budget.maxAuditBytes
            )))
        }
        
        // Explicitly sort arrays by key to ensure determinism
        recommendedFloorsArr.sort { $0.key < $1.key }
        allowedResolutionsArr.sort { $0.key < $1.key }
        budgetsArr.sort { $0.key < $1.key }
        
        let envelopeInput = EnvelopeInput(
            systemMinimumQuantum: GridResolutionPolicy.systemMinimumQuantum.digestInput(),
            recommendedCaptureFloors: recommendedFloorsArr,
            allowedGridResolutions: allowedResolutionsArr,
            budgets: budgetsArr,
            schemaVersionId: SSOTVersion.schemaVersionId
        )
        
        let currentEnvelope = try CanonicalDigest.computeDigest(envelopeInput)
        
        XCTAssertEqual(currentEnvelope, goldenEnvelope,
                      "Envelope digest mismatch. Run scripts/update_golden_policy_digests.sh to update.")
    }
}
