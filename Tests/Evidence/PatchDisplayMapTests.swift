//
// PatchDisplayMapTests.swift
// Aether3D
//
// PR2 Patch V4 - Patch Display Map Tests
//

import XCTest
@testable import Aether3DCore

final class PatchDisplayMapTests: XCTestCase {
    
    var map: PatchDisplayMap!
    var currentTimeMs: Int64!
    
    override func setUp() {
        super.setUp()
        map = PatchDisplayMap()
        currentTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
    }
    
    // MARK: - Monotonicity Tests
    
    func testPatchDisplayNeverDecreases() {
        // Update with decreasing targets
        _ = map.update(
            patchId: "test_patch",
            target: 0.8,
            timestampMs: currentTimeMs,
            isLocked: false
        )
        
        let display1 = map.display(for: "test_patch")
        
        // Update with lower target
        _ = map.update(
            patchId: "test_patch",
            target: 0.3,
            timestampMs: currentTimeMs + 1000,
            isLocked: false
        )
        
        let display2 = map.display(for: "test_patch")
        
        // Display should NOT decrease
        XCTAssertGreaterThanOrEqual(
            display2,
            display1,
            "Display must never decrease even when target decreases"
        )
    }
    
    // MARK: - EMA Tests
    
    func testEMASmoothingMonotonic() {
        // Start with low target
        _ = map.update(
            patchId: "ema_test",
            target: 0.2,
            timestampMs: currentTimeMs,
            isLocked: false
        )
        
        let entry1 = map.snapshotSorted().first { $0.patchId == "ema_test" }
        let ema1 = entry1?.ema ?? 0.0
        let display1 = entry1?.display ?? 0.0
        
        // Update with higher target
        _ = map.update(
            patchId: "ema_test",
            target: 0.9,
            timestampMs: currentTimeMs + 1000,
            isLocked: false
        )
        
        let entry2 = map.snapshotSorted().first { $0.patchId == "ema_test" }
        let ema2 = entry2?.ema ?? 0.0
        let display2 = entry2?.display ?? 0.0
        
        // EMA should increase
        XCTAssertGreaterThan(ema2, ema1, "EMA should increase when target increases")
        
        // Display should increase (monotonic)
        XCTAssertGreaterThanOrEqual(display2, display1, "Display should increase (monotonic)")
        
        // Display should be max(prev, ema)
        XCTAssertGreaterThanOrEqual(display2, ema2, "Display should be >= EMA")
    }
    
    // MARK: - Locked Acceleration Tests
    
    func testLockedAccelerationIncreasesFasterButClamped() {
        // Create two patches: one locked, one unlocked
        let lockedPatchId = "locked_patch"
        let unlockedPatchId = "unlocked_patch"
        
        // Initialize both to same state
        _ = map.update(
            patchId: lockedPatchId,
            target: 0.3,
            timestampMs: currentTimeMs,
            isLocked: true
        )
        
        _ = map.update(
            patchId: unlockedPatchId,
            target: 0.3,
            timestampMs: currentTimeMs,
            isLocked: false
        )
        
        // Apply same target sequence
        for i in 1...10 {
            let target = 0.3 + Double(i) * 0.05
            
            _ = map.update(
                patchId: lockedPatchId,
                target: target,
                timestampMs: currentTimeMs + Int64(i * 100),
                isLocked: true
            )
            
            _ = map.update(
                patchId: unlockedPatchId,
                target: target,
                timestampMs: currentTimeMs + Int64(i * 100),
                isLocked: false
            )
        }
        
        let lockedDisplay = map.display(for: lockedPatchId)
        let unlockedDisplay = map.display(for: unlockedPatchId)
        
        // Locked should be >= unlocked (accelerated growth)
        XCTAssertGreaterThanOrEqual(
            lockedDisplay,
            unlockedDisplay,
            "Locked patch should grow faster than unlocked"
        )
        
        // Both should be <= 1.0 (clamped)
        XCTAssertLessThanOrEqual(lockedDisplay, 1.0, "Locked display must be clamped to 1.0")
        XCTAssertLessThanOrEqual(unlockedDisplay, 1.0, "Unlocked display must be clamped to 1.0")
    }
    
    // MARK: - Color Evidence Tests
    
    func testColorEvidenceHybridFormula() {
        // Set up patch with known display
        _ = map.update(
            patchId: "color_test",
            target: 0.6,
            timestampMs: currentTimeMs,
            isLocked: false
        )
        
        let localDisplay = map.display(for: "color_test")
        let globalDisplay = 0.4
        
        // Compute color evidence
        let color = map.colorEvidence(for: "color_test", globalDisplay: globalDisplay)
        
        // Expected: local * 0.7 + global * 0.3
        let expected = localDisplay * EvidenceConstants.colorEvidenceLocalWeight +
                      globalDisplay * EvidenceConstants.colorEvidenceGlobalWeight
        
        XCTAssertEqual(
            color,
            expected,
            accuracy: 1e-9,
            "Color evidence should follow hybrid formula"
        )
        
        // Should be clamped to [0, 1]
        XCTAssertGreaterThanOrEqual(color, 0.0)
        XCTAssertLessThanOrEqual(color, 1.0)
    }
    
    // MARK: - Deterministic Sorting Tests
    
    func testSnapshotSortedDeterministic() {
        // Add patches in non-deterministic order
        let patchIds = ["zebra", "apple", "banana"]
        
        for (index, patchId) in patchIds.enumerated() {
            _ = map.update(
                patchId: patchId,
                target: 0.5 + Double(index) * 0.1,
                timestampMs: currentTimeMs + Int64(index * 100),
                isLocked: false
            )
        }
        
        let sorted = map.snapshotSorted()
        let sortedIds = sorted.map { $0.patchId }
        
        // Should be sorted alphabetically
        let expectedOrder = ["apple", "banana", "zebra"]
        XCTAssertEqual(sortedIds, expectedOrder, "Entries should be sorted deterministically")
    }
}
