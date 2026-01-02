import XCTest
@testable import Aether3DCore

final class InvariantPolicyTests: XCTestCase {
    func testDefaultPoliciesExist() {
        let policies = InvariantPolicies.default
        XCTAssertEqual(policies.version, "1.3.10")
        XCTAssertEqual(policies.buildMode.enterTimeoutMs, 2000)
        XCTAssertEqual(policies.buildMode.publishTimeoutMs, 30000)
        XCTAssertTrue(policies.buildMode.failSoftEnabled)
    }
    
    func testPoliciesAreCodable() throws {
        let policies = InvariantPolicies.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(policies)
        let decoded = try JSONDecoder().decode(InvariantPolicies.self, from: data)
        XCTAssertEqual(policies, decoded)
    }
    
    func testSnapshotFileExists() {
        let snapshotPath = "docs/constitution/POLICY_SNAPSHOT.json"
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let fullPath = "\(currentDir)/\(snapshotPath)"
        
        XCTAssertTrue(
            fileManager.fileExists(atPath: fullPath),
            "POLICY_SNAPSHOT.json must exist at \(snapshotPath)"
        )
    }
    
    func testSnapshotMatchesDefaultPolicies() throws {
        let snapshotPath = "docs/constitution/POLICY_SNAPSHOT.json"
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let fullPath = "\(currentDir)/\(snapshotPath)"
        
        guard let snapshotData = fileManager.contents(atPath: fullPath) else {
            XCTFail("Failed to read POLICY_SNAPSHOT.json")
            return
        }
        
        let snapshotPolicies = try JSONDecoder().decode(InvariantPolicies.self, from: snapshotData)
        let defaultPolicies = InvariantPolicies.default
        
        XCTAssertEqual(snapshotPolicies, defaultPolicies, "Snapshot must match default policies")
    }
    
    func testStableJSONEncoding() throws {
        let policies = InvariantPolicies.default
        let jsonString = try StableJSONEncoder.encode(policies)
        
        // Verify it's valid JSON
        let jsonData = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(InvariantPolicies.self, from: jsonData)
        XCTAssertEqual(policies, decoded)
        
        // Verify keys are sorted (first key should be "buildMode")
        XCTAssertTrue(jsonString.contains("\"buildMode\""))
        XCTAssertTrue(jsonString.contains("\"version\""))
    }
}

