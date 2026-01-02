import XCTest
import Foundation
import CryptoKit
@testable import Aether3DCore

final class PolicyHashGateTests: XCTestCase {
    func testPolicyHashConsistency() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        
        guard let jsonData = try? encoder.encode(INVARIANT_POLICIES) else {
            XCTFail("Failed to encode INVARIANT_POLICIES")
            return
        }
        
        let computedHash = SHA256.hash(data: jsonData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        
        XCTAssertEqual(computedHash, GOLDEN_POLICY_HASH, "Computed hash must match GOLDEN_POLICY_HASH")
    }
    
    func testGoldenPolicyHashNotPlaceholder() {
        XCTAssertNotEqual(GOLDEN_POLICY_HASH, "PLACEHOLDER", "GOLDEN_POLICY_HASH must not be PLACEHOLDER")
    }
    
    func testPolicyHashMismatchFails() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        
        let modifiedPolicies = [
            InvariantViolationPolicy(
                invariantName: "modified_policy",
                severity: .fatal,
                responseAction: .halt
            )
        ]
        
        guard let jsonData = try? encoder.encode(modifiedPolicies) else {
            XCTFail("Failed to encode modified policies")
            return
        }
        
        let modifiedHash = SHA256.hash(data: jsonData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        
        XCTAssertNotEqual(modifiedHash, GOLDEN_POLICY_HASH, "Modified policies must produce different hash")
    }
}

