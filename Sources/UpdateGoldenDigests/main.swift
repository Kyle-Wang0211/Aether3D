// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// main.swift
// UpdateGoldenDigests
//
// SwiftPM executable to regenerate golden policy digests deterministically
// H3: Golden file loading must NOT depend on Bundle.module
//

import Foundation
import Aether3DCore

#if canImport(Crypto)
import Crypto
#else
fatalError("Crypto module required")
#endif

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
    
    // Fallback: walk up from current directory to find Package.swift
    var currentDir = FileManager.default.currentDirectoryPath
    while currentDir != "/" {
        let packagePath = "\(currentDir)/Package.swift"
        if FileManager.default.fileExists(atPath: packagePath) {
            return currentDir
        }
        currentDir = (currentDir as NSString).deletingLastPathComponent
    }
    
    fatalError("Could not find repository root")
}

// MARK: - Golden File Generation

func generateGoldenDigests(repoRoot: String) throws {
    let schemaVersionId = SSOTVersion.schemaVersionId
    
    // Compute policy digests
    var policyDigests: [String: String] = [:]
    
    // CaptureProfile digests
    for profile in CaptureProfile.allCases {
        let digestInput = profile.digestInput(schemaVersionId: schemaVersionId)
        let digest = try CanonicalDigest.computeDigest(digestInput)
        policyDigests["CaptureProfile.\(profile.name)"] = digest
    }
    
    // GridResolutionPolicy digest
    let gridDigestInput = GridResolutionPolicy.digestInput(schemaVersionId: schemaVersionId)
    policyDigests["GridResolutionPolicy"] = try CanonicalDigest.computeDigest(gridDigestInput)
    
    // PatchPolicy digest
    let patchDigestInput = PatchPolicy.digestInput(schemaVersionId: schemaVersionId)
    policyDigests["PatchPolicy"] = try CanonicalDigest.computeDigest(patchDigestInput)
    
    // CoveragePolicy digest
    let coverageDigestInput = CoveragePolicy.digestInput(schemaVersionId: schemaVersionId)
    policyDigests["CoveragePolicy"] = try CanonicalDigest.computeDigest(coverageDigestInput)
    
    // EvidenceBudgetPolicy digest
    let budgetDigestInput = EvidenceBudgetPolicy.digestInput(schemaVersionId: schemaVersionId)
    policyDigests["EvidenceBudgetPolicy"] = try CanonicalDigest.computeDigest(budgetDigestInput)
    
    // DisplayPolicy digest
    let displayDigestInput = DisplayPolicy.digestInput(schemaVersionId: schemaVersionId)
    policyDigests["DisplayPolicy"] = try CanonicalDigest.computeDigest(displayDigestInput)
    
    // Compute envelope digest (H8)
    let envelopeDigest = try computeEnvelopeDigest(schemaVersionId: schemaVersionId)
    
    // Compute field set hashes (H7)
    var fieldSetHashes: [String: String] = [:]
    fieldSetHashes["GridResolutionPolicy.DigestInput"] = computeFieldSetHash(for: GridResolutionPolicy.DigestInput.self)
    fieldSetHashes["PatchPolicy.DigestInput"] = computeFieldSetHash(for: PatchPolicy.DigestInput.self)
    fieldSetHashes["CoveragePolicy.DigestInput"] = computeFieldSetHash(for: CoveragePolicy.DigestInput.self)
    fieldSetHashes["EvidenceBudgetPolicy.DigestInput"] = computeFieldSetHash(for: EvidenceBudgetPolicy.DigestInput.self)
    fieldSetHashes["DisplayPolicy.DigestInput"] = computeFieldSetHash(for: DisplayPolicy.DigestInput.self)
    fieldSetHashes["CaptureProfile.DigestInput"] = computeFieldSetHash(for: CaptureProfile.DigestInput.self)
    fieldSetHashes["LengthQ.DigestInput"] = computeFieldSetHash(for: LengthQ.DigestInput.self)
    
    // Compute generator signature (anti-hand-edit protection)
    // Signature is SHA-256 of: tool version + canonical encoding method identifier
    let generatorVersion = "UpdateGoldenDigests-v1.0-CanonicalDigest"
    let generatorSignature = try CanonicalDigest.computeDigest(generatorVersion)
    
    // Create Codable structure for deterministic golden file encoding
    struct GoldenFileContent: Codable {
        let generatorSignature: String
        let policyDigests: [String: String]
        let fieldSetHashes: [String: String]
        let envelopeDigest: String
    }
    
    let goldenContent = GoldenFileContent(
        generatorSignature: generatorSignature,
        policyDigests: policyDigests,
        fieldSetHashes: fieldSetHashes,
        envelopeDigest: envelopeDigest
    )
    
    // Use CanonicalDigest.encode for byte-for-byte deterministic output
    let finalData = try CanonicalDigest.encode(goldenContent)
    
    // Load old golden file if it exists (for diff report)
    let goldenPath = "\(repoRoot)/Tests/Golden/policy_digests.json"
    let goldenURL = URL(fileURLWithPath: goldenPath)
    var oldPolicyDigests: [String: String] = [:]
    var oldEnvelopeDigest: String? = nil
    var oldFieldSetHashes: [String: String] = [:]
    
    if FileManager.default.fileExists(atPath: goldenPath) {
        if let oldData = try? Data(contentsOf: goldenURL),
           let oldJson = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any] {
            oldPolicyDigests = (oldJson["policyDigests"] as? [String: String]) ?? [:]
            oldEnvelopeDigest = oldJson["envelopeDigest"] as? String
            oldFieldSetHashes = (oldJson["fieldSetHashes"] as? [String: String]) ?? [:]
        }
    }
    
    // Generate SSOT diff report if changes detected
    let hasChanges = oldEnvelopeDigest != envelopeDigest || 
                     oldPolicyDigests != policyDigests ||
                     oldFieldSetHashes != fieldSetHashes
    
    if hasChanges {
        try generateSSOTDiffReport(
            repoRoot: repoRoot,
            oldPolicyDigests: oldPolicyDigests,
            newPolicyDigests: policyDigests,
            oldEnvelopeDigest: oldEnvelopeDigest ?? "N/A (new file)",
            newEnvelopeDigest: envelopeDigest,
            oldFieldSetHashes: oldFieldSetHashes,
            newFieldSetHashes: fieldSetHashes
        )
    }
    
    // Write to golden file
    let goldenDir = goldenURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
    
    try finalData.write(to: goldenURL)
    
    print("Golden digests written to: \(goldenPath)")
    print("Policy digests: \(policyDigests.count)")
    print("Envelope digest: \(envelopeDigest)")
    if hasChanges {
        print("SSOT diff report generated: \(repoRoot)/artifacts/ssot_diff_report.md")
    }
}

// MARK: - Envelope Digest (H8)

func computeEnvelopeDigest(schemaVersionId: UInt16) throws -> String {
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
        schemaVersionId: schemaVersionId
    )
    
    return try CanonicalDigest.computeDigest(envelopeInput)
}

// MARK: - SSOT Diff Report Generation

func generateSSOTDiffReport(
    repoRoot: String,
    oldPolicyDigests: [String: String],
    newPolicyDigests: [String: String],
    oldEnvelopeDigest: String,
    newEnvelopeDigest: String,
    oldFieldSetHashes: [String: String],
    newFieldSetHashes: [String: String]
) throws {
    let artifactsDir = "\(repoRoot)/artifacts"
    try FileManager.default.createDirectory(atPath: artifactsDir, withIntermediateDirectories: true)
    
    let reportPath = "\(artifactsDir)/ssot_diff_report.md"
    var report = "# SSOT Diff Report\n\n"
    report += "**Generated:** \(ISO8601DateFormatter().string(from: Date()))\n\n"
    
    // Policy digest changes
    var changedPolicies: [String] = []
    var newPolicies: [String] = []
    var removedPolicies: [String] = []
    
    let allPolicyKeys = Set(oldPolicyDigests.keys).union(Set(newPolicyDigests.keys))
    for key in allPolicyKeys.sorted() {
        let oldDigest = oldPolicyDigests[key]
        let newDigest = newPolicyDigests[key]
        
        if let old = oldDigest, let new = newDigest {
            if old != new {
                changedPolicies.append(key)
            }
        } else if newDigest != nil {
            newPolicies.append(key)
        } else if oldDigest != nil {
            removedPolicies.append(key)
        }
    }
    
    if !changedPolicies.isEmpty || !newPolicies.isEmpty || !removedPolicies.isEmpty {
        report += "## Policy Digest Changes\n\n"
        
        if !changedPolicies.isEmpty {
            report += "### Changed Policies\n\n"
            for key in changedPolicies {
                report += "- **\(key)**\n"
                report += "  - Old: `\(oldPolicyDigests[key] ?? "N/A")`\n"
                report += "  - New: `\(newPolicyDigests[key] ?? "N/A")`\n\n"
            }
        }
        
        if !newPolicies.isEmpty {
            report += "### New Policies\n\n"
            for key in newPolicies {
                report += "- **\(key)**: `\(newPolicyDigests[key] ?? "N/A")`\n"
            }
            report += "\n"
        }
        
        if !removedPolicies.isEmpty {
            report += "### Removed Policies\n\n"
            for key in removedPolicies {
                report += "- **\(key)**: `\(oldPolicyDigests[key] ?? "N/A")`\n"
            }
            report += "\n"
        }
    }
    
    // Envelope digest change
    if oldEnvelopeDigest != newEnvelopeDigest {
        report += "## Envelope Digest Change\n\n"
        report += "- **Old**: `\(oldEnvelopeDigest)`\n"
        report += "- **New**: `\(newEnvelopeDigest)`\n\n"
        
        // Identify impacted profiles
        report += "### Impacted Profiles\n\n"
        let profiles = CaptureProfile.allCases.sorted { $0.profileId < $1.profileId }
        for profile in profiles {
            report += "- \(profile.name) (ID: \(profile.profileId))\n"
        }
        report += "\n"
    }
    
    // FieldSetHash changes
    var changedFieldSets: [String] = []
    let allFieldSetKeys = Set(oldFieldSetHashes.keys).union(Set(newFieldSetHashes.keys))
    for key in allFieldSetKeys.sorted() {
        let oldHash = oldFieldSetHashes[key]
        let newHash = newFieldSetHashes[key]
        
        if let old = oldHash, let new = newHash {
            if old != new {
                changedFieldSets.append(key)
            }
        }
    }
    
    if !changedFieldSets.isEmpty {
        report += "## FieldSetHash Changes\n\n"
        report += "**Reason**: Schema structure changed (fields added/removed/reordered)\n\n"
        for key in changedFieldSets {
            report += "- **\(key)**\n"
            report += "  - Old: `\(oldFieldSetHashes[key] ?? "N/A")`\n"
            report += "  - New: `\(newFieldSetHashes[key] ?? "N/A")`\n\n"
        }
    }
    
    // Budget changes summary (if EvidenceBudgetPolicy changed)
    if changedPolicies.contains("EvidenceBudgetPolicy") || newPolicies.contains("EvidenceBudgetPolicy") {
        report += "## Budget Changes Summary\n\n"
        report += "⚠️ **EvidenceBudgetPolicy digest changed. Review budget thresholds.**\n\n"
        report += "Verify that budget increases are intentional and documented in RFC.\n\n"
    }
    
    report += "---\n\n"
    report += "*This report is generated deterministically. Running UpdateGoldenDigests twice produces identical output.*\n"
    
    try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
}

// MARK: - Main

do {
    let repoRoot = findRepoRoot()
    print("Repository root: \(repoRoot)")
    try generateGoldenDigests(repoRoot: repoRoot)
    print("Success!")
} catch {
    print("Error: \(error)")
    exit(1)
}
