// ============================================================================
// TraceMetrics CapacityMetrics Contract Tests
// PR1 C-Class: Ensures TraceMetrics.capacityMetrics serialization is stable
// ============================================================================

import XCTest
@testable import Aether3DCore

/// Contract tests for TraceMetrics.capacityMetrics serialization
/// 
/// These tests ensure that TraceMetrics with optional capacityMetrics field
/// encodes/decodes correctly and that the field remains optional and stable.
final class TraceMetricsCapacityMetricsContractTests: XCTestCase {
    
    // MARK: - Optional Field Tests (nil capacityMetrics)
    
    func testTraceMetricsWithoutCapacityMetricsEncodes() throws {
        let metrics = TraceMetrics(
            elapsedMs: 1000,
            success: true,
            qualityScore: 0.85,
            errorCode: nil,
            capacityMetrics: nil
        )
        
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(metrics)
        
        // Should encode without error
        XCTAssertGreaterThan(encoded.count, 0, "TraceMetrics without capacityMetrics must encode")
    }
    
    func testTraceMetricsWithoutCapacityMetricsRoundtrip() throws {
        let original = TraceMetrics(
            elapsedMs: 1000,
            success: true,
            qualityScore: 0.85,
            errorCode: nil,
            capacityMetrics: nil
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(TraceMetrics.self, from: encoded)
        
        XCTAssertEqual(decoded.elapsedMs, original.elapsedMs)
        XCTAssertEqual(decoded.success, original.success)
        XCTAssertEqual(decoded.qualityScore, original.qualityScore)
        XCTAssertEqual(decoded.errorCode, original.errorCode)
        XCTAssertNil(decoded.capacityMetrics, "capacityMetrics must remain nil after roundtrip")
    }
    
    // MARK: - With CapacityMetrics Tests
    
    func testTraceMetricsWithCapacityMetricsRoundtrip() throws {
        // Create minimal CapacityMetrics fixture
        let capacityMetrics = CapacityMetrics(
            candidateId: UUID(),
            patchCountShadow: 100,
            eebRemaining: 5000.0,
            eebDelta: 10.0,
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
        
        let original = TraceMetrics(
            elapsedMs: 2000,
            success: true,
            qualityScore: 0.9,
            errorCode: nil,
            capacityMetrics: capacityMetrics
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(TraceMetrics.self, from: encoded)
        
        XCTAssertEqual(decoded.elapsedMs, original.elapsedMs)
        XCTAssertEqual(decoded.success, original.success)
        XCTAssertEqual(decoded.qualityScore, original.qualityScore)
        
        // Verify capacityMetrics survived roundtrip
        XCTAssertNotNil(decoded.capacityMetrics, "capacityMetrics must survive roundtrip")
        
        if let decodedCapacity = decoded.capacityMetrics {
            XCTAssertEqual(decodedCapacity.patchCountShadow, capacityMetrics.patchCountShadow)
            XCTAssertEqual(decodedCapacity.eebRemaining, capacityMetrics.eebRemaining, accuracy: 0.001)
            XCTAssertEqual(decodedCapacity.eebDelta, capacityMetrics.eebDelta, accuracy: 0.001)
            XCTAssertEqual(decodedCapacity.buildMode, capacityMetrics.buildMode)
            XCTAssertEqual(decodedCapacity.capacityInvariantViolation, capacityMetrics.capacityInvariantViolation)
        }
    }
    
    func testTraceMetricsWithCapacityMetricsFieldsSurvive() throws {
        let candidateId = UUID()
        let timestamp = Date()
        
        let capacityMetrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 5000,
            eebRemaining: 2000.0,
            eebDelta: 5.0,
            buildMode: .DAMPING,
            rejectReason: .LOW_GAIN_SOFT,
            hardFuseTrigger: nil,
            rejectReasonDistribution: ["LOW_GAIN_SOFT": 10],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: timestamp,
            flushFailure: false,
            decisionHash: "abc123"
        )
        
        let original = TraceMetrics(
            elapsedMs: 3000,
            success: false,
            qualityScore: nil,
            errorCode: "TEST_ERROR",
            capacityMetrics: capacityMetrics
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(TraceMetrics.self, from: encoded)
        
        guard let decodedCapacity = decoded.capacityMetrics else {
            XCTFail("capacityMetrics must survive roundtrip")
            return
        }
        
        // Verify all fields survived
        XCTAssertEqual(decodedCapacity.candidateId, candidateId)
        XCTAssertEqual(decodedCapacity.patchCountShadow, 5000)
        XCTAssertEqual(decodedCapacity.eebRemaining, 2000.0, accuracy: 0.001)
        XCTAssertEqual(decodedCapacity.eebDelta, 5.0, accuracy: 0.001)
        XCTAssertEqual(decodedCapacity.buildMode, .DAMPING)
        XCTAssertEqual(decodedCapacity.rejectReason, .LOW_GAIN_SOFT)
        XCTAssertEqual(decodedCapacity.rejectReasonDistribution["LOW_GAIN_SOFT"], 10)
        XCTAssertEqual(decodedCapacity.decisionHash, "abc123")
    }
}
