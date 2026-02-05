//
// PolicyProofTests.swift
// PR5CaptureTests
//
// Tests for PolicyProof
//

import XCTest
@testable import PR5Capture

@MainActor
final class PolicyProofTests: XCTestCase {
    
    var proofGenerator: PolicyProof!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        proofGenerator = PolicyProof(config: config)
    }
    
    override func tearDown() async throws {
        proofGenerator = nil
        config = nil
    }
    
    func testProofGeneration() async {
        let proof = await proofGenerator.generateProof(
            decision: .accept,
            reason: "Quality above threshold",
            inputs: ["quality": "0.8", "threshold": "0.7"]
        )
        
        XCTAssertEqual(proof.decision, .accept)
        XCTAssertEqual(proof.reason, "Quality above threshold")
    }
    
    func testProofRetrieval() async {
        let proof = await proofGenerator.generateProof(
            decision: .reject,
            reason: "Quality below threshold",
            inputs: ["quality": "0.5"]
        )
        
        let retrieved = await proofGenerator.getProof(proof.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, proof.id)
    }
    
    func testProofFiltering() async {
        // Generate multiple proofs
        _ = await proofGenerator.generateProof(
            decision: .accept,
            reason: "Test 1",
            inputs: [:]
        )
        _ = await proofGenerator.generateProof(
            decision: .reject,
            reason: "Test 2",
            inputs: [:]
        )
        _ = await proofGenerator.generateProof(
            decision: .accept,
            reason: "Test 3",
            inputs: [:]
        )
        
        let acceptProofs = await proofGenerator.getProofs(for: .accept)
        XCTAssertEqual(acceptProofs.count, 2)
    }
}
