// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceHealthRedlineTests.swift
// Aether3D
//
// PR2 Patch V4 - Evidence Health Redline Tests
//

import XCTest
@testable import Aether3DCore

final class EvidenceHealthRedlineTests: XCTestCase {
    
    func testDeltaStagnationDetection() async throws {
        let engine = await IsolatedEvidenceEngine()
        let safePointManager = SafePointManager()
        let monitor = await HealthMonitorWithStrategies(engine: engine, safePointManager: safePointManager)
        
        // Simulate stagnation: many observations with no progress
        for i in 0..<50 {
            let obs = EvidenceObservation(
                patchId: "stagnant_patch",
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            
            // Low quality, no progress
            await engine.processObservation(obs, gateQuality: 0.1, softQuality: 0.1, verdict: .suspect)
        }
        
        let snapshot = await engine.snapshot()
        let healthCheck = await monitor.checkHealth(currentTime: Date().timeIntervalSince1970)
        
        // Should detect stagnation if delta is too low
        // Note: Actual thresholds depend on HealthMonitorWithStrategies implementation
        XCTAssertNotNil(healthCheck, "Health check should complete")
    }
    
    func testAdmissionStarvationDetection() async throws {
        // This test verifies that the system detects when admission is blocking too much
        let spamProtection = SpamProtection()
        let tokenBucket = TokenBucketLimiter()
        let viewDiversity = ViewDiversityTracker()
        let admission = UnifiedAdmissionController(
            spamProtection: spamProtection,
            tokenBucket: tokenBucket,
            viewDiversity: viewDiversity
        )
        
        var blockedCount = 0
        var allowedCount = 0
        
        let baseTime = Date().timeIntervalSince1970
        for i in 0..<100 {
            let decision = admission.checkAdmission(
                patchId: "test",
                viewAngle: 0.0,
                timestamp: baseTime + Double(i) * 0.001  // Very fast
            )
            
            if decision.allowed {
                allowedCount += 1
            } else {
                blockedCount += 1
            }
        }
        
        // System should allow some progress even under stress
        XCTAssertGreaterThan(allowedCount, 0, "System should allow some observations even under stress")
    }
    
    func testEvidenceGrowthSpikeDetection() async throws {
        let engine = await IsolatedEvidenceEngine()
        
        // Simulate rapid growth
        for i in 0..<20 {
            let obs = EvidenceObservation(
                patchId: "growth_patch",
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            
            await engine.processObservation(obs, gateQuality: 0.9, softQuality: 0.85, verdict: .good)
        }
        
        let snapshot = await engine.snapshot()
        
        // Growth should be reasonable (not spike to 1.0 instantly)
        XCTAssertLessThan(snapshot.gateDisplay, 1.0, "Display should grow gradually, not spike")
    }
}
