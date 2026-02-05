//
// CanonicalBytesLengthTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Bytes Length Tests
//
// Verifies canonical layout length invariants (fail-closed on mismatch)
//

import XCTest
@testable import Aether3DCore

final class CanonicalBytesLengthTests: XCTestCase {
    /// Test DecisionHashInputBytesLayout_v1 length validation
    func testDecisionHashInput_LengthValidation() throws {
        let flowBucketCount: UInt8 = 4
        let hasThrottleStats = true
        let hasRejectReason = true
        let hasDegradationReasonCode = true
        
        let expectedLength = try CanonicalLayoutLengthValidator.expectedLengthForDecisionHashInput(
            flowBucketCount: flowBucketCount,
            hasThrottleStats: hasThrottleStats,
            hasRejectReason: hasRejectReason,
            hasDegradationReasonCode: hasDegradationReasonCode
        )
        
        // Create actual canonical bytes
        let metrics = CapacityMetrics(
            candidateId: UUID(),
            patchCountShadow: 0,
            eebRemaining: 0,
            eebDelta: 0,
            buildMode: .NORMAL,
            rejectReason: .HARD_CAP,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        let actualBytes = try metrics.canonicalBytesForDecisionHashInput(
            policyHash: 0x123456789ABCDEF0,
            sessionStableId: 0x123456789ABCDEF0,
            candidateStableId: 0x123456789ABCDEF0,
            valueScore: 1000,
            perFlowCounters: [1, 2, 3, 4],
            flowBucketCount: Int(flowBucketCount),
            throttleStats: (windowStartTick: 1000, windowDurationTicks: 100, attemptsInWindow: 5),
            degradationLevel: 1,
            degradationReasonCode: 1,
            schemaVersion: 0x0204
        )
        
        XCTAssertEqual(actualBytes.count, expectedLength, "DecisionHashInputBytesLayout_v1 length must match expected")
    }
    
    /// Test length validation fails on mismatch (v2.4+)
    func testDecisionHashInput_LengthMismatch_FailsClosed() throws {
        // This test verifies that length validation is enforced
        // We can't easily create a mismatch without modifying the encoder,
        // but we can verify the validator throws on explicit mismatch
        let expectedLength = try CanonicalLayoutLengthValidator.expectedLengthForDecisionHashInput(
            flowBucketCount: 4,
            hasThrottleStats: true,
            hasRejectReason: true,
            hasDegradationReasonCode: true
        )
        
        // Verify validator throws on mismatch
        XCTAssertThrowsError(
            try CanonicalLayoutLengthValidator.assertExactLength(
                actual: expectedLength + 1,
                expected: expectedLength,
                layoutName: "DecisionHashInputBytesLayout_v1"
            )
        ) { error in
            guard let failClosedError = error as? FailClosedError else {
                XCTFail("Expected FailClosedError")
                return
            }
            XCTAssertEqual(failClosedError.code, FailClosedErrorCode.canonicalLengthMismatch.rawValue)
        }
    }
    
    /// Test CandidateStableIdOpaqueBytesLayout_v1 length
    func testCandidateStableId_Length() {
        let expectedLength = CanonicalLayoutLengthValidator.expectedLengthForCandidateStableId()
        XCTAssertEqual(expectedLength, 45, "CandidateStableIdOpaqueBytesLayout_v1 must be exactly 45 bytes")
    }
    
    /// Test ExtensionRequestIdempotencySnapshotBytesLayout_v1 length
    func testExtensionSnapshot_Length() {
        let lengthWithReason = CanonicalLayoutLengthValidator.expectedLengthForExtensionSnapshot(hasDenialReason: true)
        let lengthWithoutReason = CanonicalLayoutLengthValidator.expectedLengthForExtensionSnapshot(hasDenialReason: false)
        
        XCTAssertEqual(lengthWithReason, 62, "ExtensionSnapshot with denial reason must be exactly 62 bytes")
        XCTAssertEqual(lengthWithoutReason, 61, "ExtensionSnapshot without denial reason must be exactly 61 bytes")
    }
    
    /// Test PolicyHashCanonicalBytesLayout_v1 length
    func testPolicyHash_Length() {
        let flowBucketCount: UInt8 = 4
        let expectedLength = CanonicalLayoutLengthValidator.expectedLengthForPolicyHash(flowBucketCount: flowBucketCount)
        
        // Verify length formula: sum(fixed fields) + flowBucketCount * 2
        // Fixed fields = 2+2+1+4+4+4+4+8+8+8+8+1+8+8+8+1+1+8+4+1+8+8+8+8+8+1+1+8+8+8+1+2+8+8+8+8+8+8 = 210
        // flowWeights = 4 * 2 = 8
        // Total = 210 + 8 = 218
        XCTAssertEqual(expectedLength, 218, "PolicyHashCanonicalBytesLayout_v1 length must match expected")
    }
}
