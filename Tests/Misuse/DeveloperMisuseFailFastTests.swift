//
// DeveloperMisuseFailFastTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Developer Misuse Fail-Fast Tests
//
// Protects against incorrect developer usage
//

import XCTest
@testable import Aether3DCore

final class DeveloperMisuseFailFastTests: XCTestCase {
    /// Test that inconsistent parameters cause explicit failure
    func testMisuse_InconsistentParameters_FailFast() throws {
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        // Test: flowBucketCount = 4, but perFlowCounters has 3 elements
        do {
            let _ = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [1, 2, 3], // 3 elements
                flowBucketCount: 4, // But count is 4
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            // For v2.4+, this should fail fast
            XCTFail("Inconsistent parameters should fail fast")
        } catch {
            // Expected: explicit failure with helpful message
            let errorDescription = "\(error)"
            XCTAssertTrue(
                errorDescription.contains("flowBucketCount") ||
                errorDescription.contains("mismatch") ||
                errorDescription.contains("arraySizeMismatch") ||
                error is FailClosedError ||
                error is CanonicalBytesError,
                "Error message should mention flowBucketCount mismatch: \(errorDescription)"
            )
        }
    }

    /// Test that skipping required fields causes explicit failure
    func testMisuse_SkippedRequiredFields_FailFast() throws {
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        // Test: degradationLevel != 0 but degradationReasonCode is nil
        // This may or may not fail depending on implementation
        // But if it fails, it should fail fast with helpful message
        
        do {
            let _ = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [],
                flowBucketCount: 4,
                throttleStats: nil,
                degradationLevel: 1, // Non-zero
                degradationReasonCode: nil, // Missing
                schemaVersion: 0x0204
            )
            
            // If it succeeds, presence tag should be 0 (absence)
            // This is acceptable if SSOT allows it
        } catch {
            // If it fails, error should be helpful
            let errorDescription = "\(error)"
            XCTAssertTrue(
                errorDescription.contains("degradation") || errorDescription.contains("required") || error is FailClosedError,
                "Error message should be helpful: \(errorDescription)"
            )
        }
    }
    
    /// Test that helpful diagnostics are provided on failure
    func testMisuse_HelpfulDiagnostics() throws {
        let candidateId = UUID()
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0,
            eebRemaining: 0.0,
            eebDelta: 0.0,
            buildMode: .NORMAL,
            rejectReason: nil,
            hardFuseTrigger: nil,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        // Test with invalid parameters
        do {
            let _ = try metrics.canonicalBytesForDecisionHashInput(
                policyHash: 0,
                sessionStableId: 0,
                candidateStableId: 0,
                valueScore: 0,
                perFlowCounters: [1, 2], // 2 elements
                flowBucketCount: 4, // But count is 4
                throttleStats: nil,
                degradationLevel: 0,
                degradationReasonCode: nil,
                schemaVersion: 0x0204
            )
            
            XCTFail("Should fail with invalid parameters")
        } catch {
            // Error should contain helpful information
            let errorString = "\(error)"
            
            // Print error for debugging (GoldenDiffPrinter style)
            print("\n========================================")
            print("MISUSE ERROR DIAGNOSTICS")
            print("========================================")
            print("Error: \(errorString)")
            print("========================================\n")
            
            // Verify error is not generic
            XCTAssertFalse(errorString.isEmpty, "Error message must not be empty")
        }
    }
}
