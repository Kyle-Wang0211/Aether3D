//
// DynamicWeightsTests.swift
// Aether3D
//
// PR2 Patch V4 - Dynamic Weights Tests
//

import XCTest
@testable import Aether3DCore

final class DynamicWeightsTests: XCTestCase {
    
    let epsilon = EvidenceConstants.dynamicWeightsEpsilon
    
    // MARK: - Bounds Tests
    
    func testWeightsWithinBounds() {
        let testProgresses: [Double] = [0.0, 0.2, 0.5, 0.8, 1.0]
        
        for progress in testProgresses {
            let (gate, soft) = DynamicWeights.weights(progress: progress)
            
            // Both must be in [0, 1]
            XCTAssertGreaterThanOrEqual(gate, 0.0, "Gate weight must be >= 0 at progress \(progress)")
            XCTAssertLessThanOrEqual(gate, 1.0, "Gate weight must be <= 1 at progress \(progress)")
            XCTAssertGreaterThanOrEqual(soft, 0.0, "Soft weight must be >= 0 at progress \(progress)")
            XCTAssertLessThanOrEqual(soft, 1.0, "Soft weight must be <= 1 at progress \(progress)")
            
            // Sum must be ≈ 1.0
            let sum = gate + soft
            XCTAssertEqual(sum, 1.0, accuracy: epsilon, "Gate + Soft must sum to 1.0 at progress \(progress)")
        }
    }
    
    // MARK: - Endpoint Tests
    
    func testEndpointsMatchSSOT() {
        // Progress = 0 => early weights
        let (gateEarly, softEarly) = DynamicWeights.weights(progress: 0.0)
        XCTAssertEqual(gateEarly, EvidenceConstants.dynamicWeightsGateEarly, accuracy: epsilon, "Progress 0 should use early gate weight")
        XCTAssertEqual(softEarly, 1.0 - EvidenceConstants.dynamicWeightsGateEarly, accuracy: epsilon, "Progress 0 should use early soft weight")
        
        // Progress = 1 => late weights
        let (gateLate, softLate) = DynamicWeights.weights(progress: 1.0)
        XCTAssertEqual(gateLate, EvidenceConstants.dynamicWeightsGateLate, accuracy: epsilon, "Progress 1 should use late gate weight")
        XCTAssertEqual(softLate, 1.0 - EvidenceConstants.dynamicWeightsGateLate, accuracy: epsilon, "Progress 1 should use late soft weight")
    }
    
    // MARK: - Monotonicity Tests
    
    func testTransitionMonotonic() {
        // Sample 101 points across [0, 1]
        var previousGate: Double? = nil
        var previousSoft: Double? = nil
        
        for i in 0...100 {
            let progress = Double(i) / 100.0
            let (gate, soft) = DynamicWeights.weights(progress: progress)
            
            // Gate must be non-increasing
            if let prevGate = previousGate {
                XCTAssertLessThanOrEqual(gate, prevGate, "Gate weight must be non-increasing at progress \(progress)")
            }
            
            // Soft must be non-decreasing
            if let prevSoft = previousSoft {
                XCTAssertGreaterThanOrEqual(soft, prevSoft, "Soft weight must be non-decreasing at progress \(progress)")
            }
            
            previousGate = gate
            previousSoft = soft
        }
    }
    
    // MARK: - Determinism Tests
    
    func testDeterminism() {
        let testProgress: Double = 0.623
        var results: Set<String> = []
        
        // Call 1000 times
        for _ in 0..<1000 {
            let (gate, soft) = DynamicWeights.weights(progress: testProgress)
            let result = "\(gate),\(soft)"
            results.insert(result)
        }
        
        // All results must be identical
        XCTAssertEqual(results.count, 1, "Weights must be deterministic (identical results across 1000 calls)")
        
        // Verify the result is reasonable
        let (gate, soft) = DynamicWeights.weights(progress: testProgress)
        XCTAssertGreaterThan(gate, 0.0)
        XCTAssertLessThan(gate, 1.0)
        XCTAssertGreaterThan(soft, 0.0)
        XCTAssertLessThan(soft, 1.0)
        XCTAssertEqual(gate + soft, 1.0, accuracy: epsilon)
    }
    
    // MARK: - Convenience Method Tests
    
    func testWeightsFromCurrentTotal() {
        // Test convenience method that uses currentTotal as progress
        let testTotals: [Double] = [0.0, 0.3, 0.6, 0.9, 1.0, 1.5]
        
        for total in testTotals {
            let (gate, soft) = DynamicWeights.weights(currentTotal: total)
            
            // Should still satisfy bounds and sum
            XCTAssertGreaterThanOrEqual(gate, 0.0)
            XCTAssertLessThanOrEqual(gate, 1.0)
            XCTAssertGreaterThanOrEqual(soft, 0.0)
            XCTAssertLessThanOrEqual(soft, 1.0)
            XCTAssertEqual(gate + soft, 1.0, accuracy: epsilon)
        }
    }
}
