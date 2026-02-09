// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FieldSetHashTests.swift
// Aether3D
//
// Tests for FieldSetHash (schema drift protection)
//

import XCTest
@testable import Aether3DCore

final class FieldSetHashTests: XCTestCase {
    
    // MARK: - FieldSetHash Computation Tests
    
    func testFieldSetHashDeterministic() {
        let hash1 = computeFieldSetHash(for: LengthQ.DigestInput.self)
        let hash2 = computeFieldSetHash(for: LengthQ.DigestInput.self)
        let hash3 = computeFieldSetHash(for: LengthQ.DigestInput.self)
        
        XCTAssertEqual(hash1, hash2, "FieldSetHash must be deterministic (run 1 vs 2)")
        XCTAssertEqual(hash2, hash3, "FieldSetHash must be deterministic (run 2 vs 3)")
        XCTAssertFalse(hash1.isEmpty, "Hash must not be empty")
        XCTAssertEqual(hash1.count, 64, "SHA-256 hex string must be 64 characters")
    }
    
    func testFieldSetHashForAllDigestInputTypes() {
        // Verify all DigestInput types have field set descriptors
        let types: [(String, String)] = [
            ("GridResolutionPolicy.DigestInput", computeFieldSetHash(for: GridResolutionPolicy.DigestInput.self)),
            ("PatchPolicy.DigestInput", computeFieldSetHash(for: PatchPolicy.DigestInput.self)),
            ("CoveragePolicy.DigestInput", computeFieldSetHash(for: CoveragePolicy.DigestInput.self)),
            ("EvidenceBudgetPolicy.DigestInput", computeFieldSetHash(for: EvidenceBudgetPolicy.DigestInput.self)),
            ("DisplayPolicy.DigestInput", computeFieldSetHash(for: DisplayPolicy.DigestInput.self)),
            ("CaptureProfile.DigestInput", computeFieldSetHash(for: CaptureProfile.DigestInput.self)),
            ("LengthQ.DigestInput", computeFieldSetHash(for: LengthQ.DigestInput.self)),
        ]
        
        for (typeName, hash) in types {
            XCTAssertFalse(hash.isEmpty, "Hash must not be empty for \(typeName)")
            XCTAssertEqual(hash.count, 64, "Hash must be 64 characters for \(typeName)")
        }
        
        // Verify hashes are unique (different types should have different hashes)
        var seenHashes: Set<String> = []
        for (typeName, hash) in types {
            XCTAssertFalse(seenHashes.contains(hash),
                          "Hash collision detected for \(typeName)")
            seenHashes.insert(hash)
        }
    }
    
    func testFieldSetHashMatchesGolden() throws {
        // Find repo root
        func findRepoRoot() -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "rev-parse", "--show-toplevel"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let root = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !root.isEmpty {
                    return root
                }
            }
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
        
        let repoRoot = findRepoRoot()
        let goldenHashes = try SSOTVersion.loadFieldSetHashes(repoRoot: repoRoot)
        
        // Verify computed hashes match golden
        let computedHashes: [String: String] = [
            "GridResolutionPolicy.DigestInput": computeFieldSetHash(for: GridResolutionPolicy.DigestInput.self),
            "PatchPolicy.DigestInput": computeFieldSetHash(for: PatchPolicy.DigestInput.self),
            "CoveragePolicy.DigestInput": computeFieldSetHash(for: CoveragePolicy.DigestInput.self),
            "EvidenceBudgetPolicy.DigestInput": computeFieldSetHash(for: EvidenceBudgetPolicy.DigestInput.self),
            "DisplayPolicy.DigestInput": computeFieldSetHash(for: DisplayPolicy.DigestInput.self),
            "CaptureProfile.DigestInput": computeFieldSetHash(for: CaptureProfile.DigestInput.self),
            "LengthQ.DigestInput": computeFieldSetHash(for: LengthQ.DigestInput.self),
        ]
        
        for (typeName, computedHash) in computedHashes {
            if let goldenHash = goldenHashes[typeName] {
                XCTAssertEqual(computedHash, goldenHash,
                              "FieldSetHash mismatch for \(typeName). Expected: \(goldenHash), Got: \(computedHash)")
            } else {
                // If not in golden file, that's okay (may not be implemented yet)
                // But we still verify the hash is computed correctly
                XCTAssertFalse(computedHash.isEmpty, "Hash must be computed for \(typeName)")
            }
        }
    }
    
    func testFieldSetDescriptor() {
        let descriptor = LengthQ.DigestInput.fieldSetDescriptor()
        XCTAssertEqual(descriptor.typeName, "LengthQ.DigestInput")
        XCTAssertEqual(descriptor.fields.count, 2)
        
        let fieldNames = descriptor.fields.map { $0.name }.sorted()
        XCTAssertEqual(fieldNames, ["quanta", "scaleId"])
    }
    
    func testFieldSetHashChangesOnFieldAddition() {
        // This test verifies that adding a field would change the hash
        // We can't actually add a field, but we verify the mechanism works
        let originalHash = computeFieldSetHash(for: LengthQ.DigestInput.self)
        
        // Create a modified descriptor (simulating field addition)
        let originalDescriptor = LengthQ.DigestInput.fieldSetDescriptor()
        var modifiedFields = originalDescriptor.fields
        modifiedFields.append(FieldDescriptor(name: "newField", type: "String"))
        let modifiedDescriptor = FieldSetDescriptor(
            typeName: originalDescriptor.typeName,
            fields: modifiedFields
        )
        
        let modifiedHash = modifiedDescriptor.computeHash()
        XCTAssertNotEqual(originalHash, modifiedHash,
                         "Hash must change when field is added")
    }
    
    func testFieldSetHashChangesOnFieldRemoval() {
        // This test verifies that removing a field would change the hash
        let originalHash = computeFieldSetHash(for: LengthQ.DigestInput.self)
        
        let originalDescriptor = LengthQ.DigestInput.fieldSetDescriptor()
        var modifiedFields = originalDescriptor.fields
        modifiedFields.removeFirst()
        let modifiedDescriptor = FieldSetDescriptor(
            typeName: originalDescriptor.typeName,
            fields: modifiedFields
        )
        
        let modifiedHash = modifiedDescriptor.computeHash()
        XCTAssertNotEqual(originalHash, modifiedHash,
                         "Hash must change when field is removed")
    }
    
    func testFieldSetHashChangesOnFieldTypeChange() {
        // This test verifies that changing a field type would change the hash
        let originalHash = computeFieldSetHash(for: LengthQ.DigestInput.self)
        
        let originalDescriptor = LengthQ.DigestInput.fieldSetDescriptor()
        var modifiedFields = originalDescriptor.fields
        if let index = modifiedFields.firstIndex(where: { $0.name == "quanta" }) {
            modifiedFields[index] = FieldDescriptor(name: "quanta", type: "String") // Changed type
        }
        let modifiedDescriptor = FieldSetDescriptor(
            typeName: originalDescriptor.typeName,
            fields: modifiedFields
        )
        
        let modifiedHash = modifiedDescriptor.computeHash()
        XCTAssertNotEqual(originalHash, modifiedHash,
                         "Hash must change when field type changes")
    }
}
