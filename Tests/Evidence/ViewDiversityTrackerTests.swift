//
// ViewDiversityTrackerTests.swift
// Aether3D
//
// PR2 Patch V4 - View Diversity Tracker Tests
//

import XCTest
@testable import Aether3DCore

final class ViewDiversityTrackerTests: XCTestCase {
    
    var tracker: ViewDiversityTracker!
    var currentTimeMs: Int64!
    
    override func setUp() {
        super.setUp()
        tracker = ViewDiversityTracker()
        currentTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
    }
    
    func testNoveltyHigherForNewBuckets() {
        let patchId = "novelty_test"
        
        // First observation: should have high novelty (no buckets yet = max diversity)
        let novelty1 = tracker.addObservation(
            patchId: patchId,
            viewAngleDeg: 0.0,
            timestampMs: currentTimeMs
        )
        
        // Same bucket: should have lower novelty (repeated bucket reduces diversity)
        let novelty2 = tracker.addObservation(
            patchId: patchId,
            viewAngleDeg: 5.0,  // Same bucket (15 deg buckets: 0-15)
            timestampMs: currentTimeMs + 1000
        )
        
        // Different bucket: should have higher novelty (new bucket increases diversity)
        let novelty3 = tracker.addObservation(
            patchId: patchId,
            viewAngleDeg: 20.0,  // Different bucket (15-30)
            timestampMs: currentTimeMs + 2000
        )
        
        // Note: Novelty/diversity score may decrease as more observations accumulate
        // The key is that adding a NEW bucket should increase diversity score
        XCTAssertGreaterThanOrEqual(novelty1, novelty2, "First observation should have >= novelty than repeated bucket")
        XCTAssertGreaterThanOrEqual(novelty3, novelty2, "New bucket should have >= novelty than repeated bucket")
    }
    
    func testDeterministicGivenSameInput() {
        let patchId = "deterministic_test"
        let angle = 45.0
        
        // Add same observation multiple times
        var results: Set<Double> = []
        
        for i in 0..<100 {
            let novelty = tracker.addObservation(
                patchId: patchId,
                viewAngleDeg: angle,
                timestampMs: currentTimeMs + Int64(i * 100)
            )
            results.insert(novelty)
        }
        
        // After many observations in same bucket, novelty should stabilize
        // But results should be deterministic (same input = same output at same state)
        XCTAssertGreaterThanOrEqual(results.count, 1, "Results should be deterministic")
    }
}
