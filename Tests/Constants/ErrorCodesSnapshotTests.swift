//
// ErrorCodesSnapshotTests.swift
// Aether3D
//
// Tests for error code snapshot consistency.
//

import XCTest
@testable import Aether3DCore

final class ErrorCodesSnapshotTests: XCTestCase {
    
    func test_snapshot_errorCodeCountMatches() throws {
        let snapshotURL = try RepoRootLocator.fileURL(for: "docs/constitution/errorcodes_snapshot.json")
        
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw XCTSkip("Snapshot not yet created")
        }
        
        let data = try Data(contentsOf: snapshotURL)
        
        struct Snapshot: Codable {
            struct Code: Codable { let stableName: String }
            let errorCodes: [Code]
        }
        
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        
        XCTAssertEqual(
            SSOTRegistry.allErrorCodes.count,
            snapshot.errorCodes.count,
            "Error code count mismatch - run snapshot update if intentional"
        )
    }
    
    func test_snapshot_stableNamesMatch() throws {
        let snapshotURL = try RepoRootLocator.fileURL(for: "docs/constitution/errorcodes_snapshot.json")
        
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw XCTSkip("Snapshot not yet created")
        }
        
        let data = try Data(contentsOf: snapshotURL)
        
        struct Snapshot: Codable {
            struct Code: Codable { let stableName: String }
            let errorCodes: [Code]
        }
        
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let snapshotNames = Set(snapshot.errorCodes.map { $0.stableName })
        let codeNames = Set(SSOTRegistry.allErrorCodes.map { $0.stableName })
        
        let missing = codeNames.subtracting(snapshotNames)
        let extra = snapshotNames.subtracting(codeNames)
        
        XCTAssertTrue(missing.isEmpty, "Missing from snapshot: \(missing)")
        XCTAssertTrue(extra.isEmpty, "Extra in snapshot: \(extra)")
    }
    
    func test_snapshot_globalIdsUnique() throws {
        let snapshotURL = try RepoRootLocator.fileURL(for: "docs/constitution/errorcodes_snapshot.json")
        
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw XCTSkip("Snapshot not yet created")
        }
        
        let data = try Data(contentsOf: snapshotURL)
        
        struct Snapshot: Codable {
            struct Code: Codable { let globalId: String }
            let errorCodes: [Code]
        }
        
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let ids = snapshot.errorCodes.map { $0.globalId }
        let uniqueIds = Set(ids)
        
        XCTAssertEqual(ids.count, uniqueIds.count, "Duplicate globalIds in snapshot")
    }
}

