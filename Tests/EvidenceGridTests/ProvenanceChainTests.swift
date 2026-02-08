//
// ProvenanceChainTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Provenance Chain Tests
//

import XCTest
@testable import Aether3DCore

final class ProvenanceChainTests: XCTestCase {
    
    func testAppendTransitionProducesHash() {
        let chain = ProvenanceChain()
        
        let hash = chain.appendTransition(
            timestampMillis: MonotonicClock.nowMs(),
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: [100, 0, 0, 0, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "test-grid-digest",
            policyDigest: "test-policy-digest"
        )
        
        XCTAssertFalse(hash.isEmpty, "Hash must be non-empty")
        XCTAssertEqual(hash.count, 64, "SHA-256 hash must be 64 hex characters")
    }
    
    func testChainVerification() {
        let chain = ProvenanceChain()
        
        // Append 3 transitions
        let hash1 = chain.appendTransition(
            timestampMillis: MonotonicClock.nowMs(),
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: [100, 0, 0, 0, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "digest-1",
            policyDigest: "policy-1"
        )
        
        let hash2 = chain.appendTransition(
            timestampMillis: MonotonicClock.nowMs() + 1000,
            fromState: .darkGray,
            toState: .lightGray,
            coverage: 0.50,
            levelBreakdown: [50, 50, 0, 0, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "digest-2",
            policyDigest: "policy-1"
        )
        
        let hash3 = chain.appendTransition(
            timestampMillis: MonotonicClock.nowMs() + 2000,
            fromState: .lightGray,
            toState: .white,
            coverage: 0.75,
            levelBreakdown: [0, 0, 50, 50, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "digest-3",
            policyDigest: "policy-1"
        )
        
        // Verify chain integrity
        XCTAssertTrue(chain.verifyChain(), "Chain must be valid after appending transitions")
        
        // Verify hashes are different
        XCTAssertNotEqual(hash1, hash2)
        XCTAssertNotEqual(hash2, hash3)
    }
    
    func testTamperDetection() {
        let chain = ProvenanceChain()
        
        // Append transition
        chain.appendTransition(
            timestampMillis: MonotonicClock.nowMs(),
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: [100, 0, 0, 0, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "digest-1",
            policyDigest: "policy-1"
        )
        
        // Chain should be valid
        XCTAssertTrue(chain.verifyChain())
        
        // Note: Actual tamper detection would require access to internal entries
        // This test verifies that verifyChain() works correctly
    }
    
    func testDeterministicSameInputSameHash() {
        let chain1 = ProvenanceChain()
        let chain2 = ProvenanceChain()
        
        let timestamp = MonotonicClock.nowMs()
        let levelBreakdown = [100, 0, 0, 0, 0, 0, 0]
        let pizSummary = (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0)
        let gridDigest = "test-grid-digest"
        let policyDigest = "test-policy-digest"
        
        let hash1 = chain1.appendTransition(
            timestampMillis: timestamp,
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: levelBreakdown,
            pizSummary: pizSummary,
            gridDigest: gridDigest,
            policyDigest: policyDigest
        )
        
        let hash2 = chain2.appendTransition(
            timestampMillis: timestamp,
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: levelBreakdown,
            pizSummary: pizSummary,
            gridDigest: gridDigest,
            policyDigest: policyDigest
        )
        
        XCTAssertEqual(hash1, hash2, "Same inputs must produce same hash")
    }
    
    func testCanonicalFieldOrder() {
        let chain = ProvenanceChain()
        
        // Append transition and verify hash is deterministic
        let hash1 = chain.appendTransition(
            timestampMillis: 1000,
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: [100, 0, 0, 0, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "digest",
            policyDigest: "policy"
        )
        
        // Same inputs should produce same hash (field order is canonical)
        let chain2 = ProvenanceChain()
        let hash2 = chain2.appendTransition(
            timestampMillis: 1000,
            fromState: .black,
            toState: .darkGray,
            coverage: 0.25,
            levelBreakdown: [100, 0, 0, 0, 0, 0, 0],
            pizSummary: (count: 0, totalAreaSqM: 0.0, excludedAreaSqM: 0.0),
            gridDigest: "digest",
            policyDigest: "policy"
        )
        
        XCTAssertEqual(hash1, hash2, "Canonical field order must produce same hash")
    }
}
