//
// MonotonicityStressTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Monotonicity Stress Tests
//

import XCTest
@testable import Aether3DCore

final class MonotonicityStressTests: XCTestCase {
    
    func testDisplayNeverDecreases() {
        // Test that PatchDisplayMap.display never decreases
        // This is a critical invariant for PR7
        
        let map = PatchDisplayMap()
        let patchId = "test-patch-monotonicity"
        let timestampMs = MonotonicClock.nowMs()
        
        // Start with display = 0
        var previousDisplay = 0.0
        
        // Perform 1000 random updates
        for i in 0..<1000 {
            // Random target between 0 and 1
            let randomTarget = Double.random(in: 0.0...1.0)
            
            let entry = map.update(
                patchId: patchId,
                target: randomTarget,
                timestampMs: timestampMs + Int64(i * 1000), // 1 second apart
                isLocked: false
            )
            
            // Verify display never decreases
            XCTAssertGreaterThanOrEqual(
                entry.display,
                previousDisplay,
                "Display should never decrease (iteration \(i), previous: \(previousDisplay), current: \(entry.display))"
            )
            
            previousDisplay = entry.display
        }
    }
    
    func testMultiplePatchesMonotonicity() {
        // Test monotonicity across multiple patches
        let map = PatchDisplayMap()
        let timestampMs = MonotonicClock.nowMs()
        
        let patchIds = ["patch-1", "patch-2", "patch-3", "patch-4", "patch-5"]
        var previousDisplays: [String: Double] = [:]
        
        // Initialize all patches
        for patchId in patchIds {
            let entry = map.update(
                patchId: patchId,
                target: 0.0,
                timestampMs: timestampMs,
                isLocked: false
            )
            previousDisplays[patchId] = entry.display
        }
        
        // Perform random updates
        for i in 0..<500 {
            let randomPatchId = patchIds.randomElement()!
            let randomTarget = Double.random(in: 0.0...1.0)
            
            let entry = map.update(
                patchId: randomPatchId,
                target: randomTarget,
                timestampMs: timestampMs + Int64(i * 1000),
                isLocked: false
            )
            
            let previousDisplay = previousDisplays[randomPatchId] ?? 0.0
            XCTAssertGreaterThanOrEqual(
                entry.display,
                previousDisplay,
                "Display should never decrease for patch \(randomPatchId)"
            )
            
            previousDisplays[randomPatchId] = entry.display
        }
    }
    
    func testSnapshotSortedConsistency() {
        // Test that snapshotSorted() returns consistent results
        let map = PatchDisplayMap()
        let timestampMs = MonotonicClock.nowMs()
        
        // Add multiple patches
        for i in 0..<100 {
            let patchId = "patch-\(i)"
            map.update(
                patchId: patchId,
                target: Double.random(in: 0.0...1.0),
                timestampMs: timestampMs + Int64(i * 1000),
                isLocked: false
            )
        }
        
        // Get snapshot
        let snapshot = map.snapshotSorted()
        
        // Verify snapshot is sorted by patchId (not by display value)
        let patchIds = snapshot.map { $0.patchId }
        let sortedPatchIds = patchIds.sorted()
        XCTAssertEqual(patchIds, sortedPatchIds, "Snapshot should be sorted by patchId")
        
        // Verify each patch's display is monotonic across multiple updates
        // (This is tested in testDisplayNeverDecreases, not here)
        for entry in snapshot {
            XCTAssertGreaterThanOrEqual(entry.display, 0.0)
            XCTAssertLessThanOrEqual(entry.display, 1.0)
        }
    }
    
    func testLockedAccelerationStillMonotonic() {
        // Test that locked acceleration doesn't break monotonicity
        let map = PatchDisplayMap()
        let timestampMs = MonotonicClock.nowMs()
        let patchId = "locked-patch"
        
        var previousDisplay = 0.0
        
        // Update with locked=true
        for i in 0..<100 {
            let randomTarget = Double.random(in: 0.0...1.0)
            
            let entry = map.update(
                patchId: patchId,
                target: randomTarget,
                timestampMs: timestampMs + Int64(i * 1000),
                isLocked: true  // Locked acceleration
            )
            
            // Verify monotonicity even with acceleration
            XCTAssertGreaterThanOrEqual(
                entry.display,
                previousDisplay,
                "Display should never decrease even with locked acceleration"
            )
            
            previousDisplay = entry.display
        }
    }
    
    func testDisplayClamping() {
        // Test that display values are clamped to [0, 1]
        let map = PatchDisplayMap()
        let timestampMs = MonotonicClock.nowMs()
        let patchId = "clamp-test"
        
        // Try to set target > 1.0
        let entry1 = map.update(
            patchId: patchId,
            target: 2.0,
            timestampMs: timestampMs,
            isLocked: false
        )
        XCTAssertLessThanOrEqual(entry1.display, 1.0, "Display should be clamped to 1.0")
        
        // Try to set target < 0.0
        let entry2 = map.update(
            patchId: patchId,
            target: -1.0,
            timestampMs: timestampMs + 1000,
            isLocked: false
        )
        XCTAssertGreaterThanOrEqual(entry2.display, 0.0, "Display should be clamped to 0.0")
        XCTAssertGreaterThanOrEqual(entry2.display, entry1.display, "Display should still be monotonic")
    }
}
