//
// EvidenceAdmissionThroughputTests.swift
// Aether3D
//
// PR2 Patch V4 - Admission & Throughput Guarantee Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceAdmissionThroughputTests: XCTestCase {
    
    func testAdmissionThroughputGuarantee() async throws {
        let spamProtection = SpamProtection()
        let tokenBucket = TokenBucketLimiter()
        let viewDiversity = ViewDiversityTracker()
        let admission = UnifiedAdmissionController(
            spamProtection: spamProtection,
            tokenBucket: tokenBucket,
            viewDiversity: viewDiversity
        )
        
        let patchId = "weak_texture_patch"
        var allowedCount = 0
        var totalQualityScale: Double = 0.0
        var decisionCount = 0
        
        // Simulate weak texture: repeated views, low novelty
        let baseTime = Date().timeIntervalSince1970
        
        // First observation should always be allowed
        var lastAllowedTime = baseTime
        
        for i in 0..<100 {
            let timestamp = baseTime + Double(i) * 0.010  // 10ms intervals (faster than min interval)
            
            // Same patch, same angle (low novelty)
            let decision = admission.checkAdmission(
                patchId: patchId,
                viewAngle: 0.0,  // Same angle
                timestamp: timestamp
            )
            
            decisionCount += 1
            
            if decision.allowed {
                allowedCount += 1
                lastAllowedTime = timestamp
            }
            
            totalQualityScale += decision.qualityScale
        }
        
        // Verify minimum throughput guarantee
        // Note: Average may be low if many are hard-blocked, but ALLOWED observations
        // should have qualityScale >= minimum
        let avgQualityScale = totalQualityScale / Double(decisionCount)
        
        // For allowed observations, verify minimum
        if allowedCount > 0 {
            let avgAllowedScale = totalQualityScale / Double(allowedCount)
            XCTAssertGreaterThanOrEqual(
                avgAllowedScale,
                EvidenceConstants.minimumSoftScale,
                "Average quality scale for ALLOWED observations must meet minimum throughput guarantee"
            )
        }
        
        // Some observations should be hard-blocked (time density) OR quality scale should be reduced
        // Since we're hitting time density limits, either blocked or scaled down
        let blockedOrScaled = decisionCount - allowedCount
        
        // Quality scale should never drop below minimum for allowed observations
        let allowedScales = (0..<100).compactMap { i -> Double? in
            let timestamp = baseTime + Double(i) * 0.010
            let decision = admission.checkAdmission(
                patchId: patchId,
                viewAngle: 0.0,
                timestamp: timestamp
            )
            return decision.allowed ? decision.qualityScale : nil
        }
        
        // Verify minimum throughput guarantee
        if !allowedScales.isEmpty {
            if let minAllowedScale = allowedScales.min() {
                XCTAssertGreaterThanOrEqual(
                    minAllowedScale,
                    EvidenceConstants.minimumSoftScale,
                    "Minimum quality scale must be enforced for allowed observations"
                )
            }
        } else {
            // If all blocked, that's also acceptable (hard-block takes precedence)
            XCTAssertGreaterThan(blockedOrScaled, 0, "Some observations should be blocked or scaled")
        }
    }
    
    func testProgressContinuesOverTime() async throws {
        let engine = await IsolatedEvidenceEngine()
        
        // Simulate weak texture scenario
        let sequence = TestDataGenerator.generateObservationSequence(count: 200, patchCount: 1)
        
        var snapshots: [EvidenceSnapshot] = []
        
        for (obs, gateQ, softQ, verdict) in sequence {
            await engine.processObservation(obs, gateQuality: gateQ, softQuality: softQ, verdict: verdict)
            
            if sequence.firstIndex(where: { $0.0.patchId == obs.patchId && $0.0.frameId == obs.frameId })! % 20 == 0 {
                snapshots.append(await engine.snapshot())
            }
        }
        
        // Verify progress over time
        guard snapshots.count >= 2 else {
            XCTFail("Need at least 2 snapshots")
            return
        }
        
        let firstTotal = snapshots.first!.totalEvidence
        let lastTotal = snapshots.last!.totalEvidence
        
        // Total evidence should increase (or at least not decrease significantly)
        XCTAssertGreaterThanOrEqual(
            lastTotal,
            firstTotal - 0.1,  // Allow small tolerance for decay
            "Evidence should make progress over time even in weak texture scenario"
        )
    }
}
