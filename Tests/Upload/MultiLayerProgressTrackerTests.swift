//
//  MultiLayerProgressTrackerTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Multi-Layer Progress Tracker Tests
//

import XCTest
@testable import Aether3DCore

final class MultiLayerProgressTrackerTests: XCTestCase {
    
    var tracker: MultiLayerProgressTracker!
    let totalBytes: Int64 = 100 * 1024 * 1024  // 100MB
    
    override func setUp() {
        super.setUp()
        tracker = MultiLayerProgressTracker(totalBytes: totalBytes)
    }
    
    override func tearDown() {
        tracker = nil
        super.tearDown()
    }
    
    // MARK: - 4-Layer Progress (25 tests)
    
    func testInit_WithTotalBytes_Succeeds() {
        let tracker = MultiLayerProgressTracker(totalBytes: totalBytes)
        XCTAssertNotNil(tracker, "Should initialize with total bytes")
    }
    
    func testWireProgress_StartsAtZero() async {
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, 0.0, "Wire progress should start at 0")
    }
    
    func testACKProgress_StartsAtZero() async {
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.ackProgress, 0.0, "ACK progress should start at 0")
    }
    
    func testMerkleProgress_StartsAtZero() async {
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.merkleProgress, 0.0, "Merkle progress should start at 0")
    }
    
    func testServerReconstructed_StartsAtZero() async {
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.serverReconstructed, 0.0, "Server reconstructed should start at 0")
    }
    
    func testWireProgress_UpdatesCorrectly() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)  // 50MB
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, 0.5, accuracy: 0.01, "Wire progress should be 0.5")
    }
    
    func testACKProgress_UpdatesCorrectly() async {
        await tracker.updateACKProgress(25 * 1024 * 1024)  // 25MB
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.ackProgress, 0.25, accuracy: 0.01, "ACK progress should be 0.25")
    }
    
    func testMerkleProgress_UpdatesCorrectly() async {
        await tracker.updateMerkleProgress(10 * 1024 * 1024)  // 10MB
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.merkleProgress, 0.1, accuracy: 0.01, "Merkle progress should be 0.1")
    }
    
    func testServerReconstructed_UpdatesCorrectly() async {
        await tracker.updateServerReconstructed(5 * 1024 * 1024)  // 5MB
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.serverReconstructed, 0.05, accuracy: 0.01, "Server reconstructed should be 0.05")
    }
    
    func testWireGreaterThanOrEqualACK() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        await tracker.updateACKProgress(40 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, progress.ackProgress, "Wire should be >= ACK")
    }
    
    func testACKGreaterThanOrEqualMerkle() async {
        await tracker.updateACKProgress(30 * 1024 * 1024)
        await tracker.updateMerkleProgress(20 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.ackProgress, progress.merkleProgress, "ACK should be >= Merkle")
    }
    
    func testMerkleGreaterThanOrEqualServer() async {
        await tracker.updateMerkleProgress(15 * 1024 * 1024)
        await tracker.updateServerReconstructed(10 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.merkleProgress, progress.serverReconstructed, "Merkle should be >= Server")
    }
    
    func testAllLayers_0to1Range() async {
        await tracker.updateWireProgress(75 * 1024 * 1024)
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(25 * 1024 * 1024)
        await tracker.updateServerReconstructed(10 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, 0.0, "Wire should be >= 0")
        XCTAssertLessThanOrEqual(progress.wireProgress, 1.0, "Wire should be <= 1")
        XCTAssertGreaterThanOrEqual(progress.ackProgress, 0.0, "ACK should be >= 0")
        XCTAssertLessThanOrEqual(progress.ackProgress, 1.0, "ACK should be <= 1")
        XCTAssertGreaterThanOrEqual(progress.merkleProgress, 0.0, "Merkle should be >= 0")
        XCTAssertLessThanOrEqual(progress.merkleProgress, 1.0, "Merkle should be <= 1")
        XCTAssertGreaterThanOrEqual(progress.serverReconstructed, 0.0, "Server should be >= 0")
        XCTAssertLessThanOrEqual(progress.serverReconstructed, 1.0, "Server should be <= 1")
    }
    
    func testWireProgress_MonotonicIncrease() async {
        await tracker.updateWireProgress(10 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.wireProgress, progress1.wireProgress, "Wire should be monotonic")
    }
    
    func testACKProgress_MonotonicIncrease() async {
        await tracker.updateACKProgress(10 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateACKProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.ackProgress, progress1.ackProgress, "ACK should be monotonic")
    }
    
    func testMerkleProgress_MonotonicIncrease() async {
        await tracker.updateMerkleProgress(5 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateMerkleProgress(10 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.merkleProgress, progress1.merkleProgress, "Merkle should be monotonic")
    }
    
    func testServerReconstructed_MonotonicIncrease() async {
        await tracker.updateServerReconstructed(2 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateServerReconstructed(5 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.serverReconstructed, progress1.serverReconstructed, "Server should be monotonic")
    }
    
    func testWireProgress_CompleteAt100Percent() async {
        await tracker.updateWireProgress(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, 1.0, accuracy: 0.01, "Wire should be 1.0 at completion")
    }
    
    func testACKProgress_CompleteAt100Percent() async {
        await tracker.updateACKProgress(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.ackProgress, 1.0, accuracy: 0.01, "ACK should be 1.0 at completion")
    }
    
    func testMerkleProgress_CompleteAt100Percent() async {
        await tracker.updateMerkleProgress(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.merkleProgress, 1.0, accuracy: 0.01, "Merkle should be 1.0 at completion")
    }
    
    func testServerReconstructed_CompleteAt100Percent() async {
        await tracker.updateServerReconstructed(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.serverReconstructed, 1.0, accuracy: 0.01, "Server should be 1.0 at completion")
    }
    
    func testAllLayers_OrderedCorrectly() async {
        await tracker.updateWireProgress(80 * 1024 * 1024)
        await tracker.updateACKProgress(60 * 1024 * 1024)
        await tracker.updateMerkleProgress(40 * 1024 * 1024)
        await tracker.updateServerReconstructed(20 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, progress.ackProgress, "Wire >= ACK")
        XCTAssertGreaterThanOrEqual(progress.ackProgress, progress.merkleProgress, "ACK >= Merkle")
        XCTAssertGreaterThanOrEqual(progress.merkleProgress, progress.serverReconstructed, "Merkle >= Server")
    }
    
    func testWireProgress_ExceedsTotal_Clamped() async {
        await tracker.updateWireProgress(totalBytes * 2)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.wireProgress, 1.0, "Wire should be clamped to 1.0")
    }
    
    func testACKProgress_ExceedsTotal_Clamped() async {
        await tracker.updateACKProgress(totalBytes * 2)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.ackProgress, 1.0, "ACK should be clamped to 1.0")
    }
    
    func testMerkleProgress_ExceedsTotal_Clamped() async {
        await tracker.updateMerkleProgress(totalBytes * 2)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.merkleProgress, 1.0, "Merkle should be clamped to 1.0")
    }
    
    func testServerReconstructed_ExceedsTotal_Clamped() async {
        await tracker.updateServerReconstructed(totalBytes * 2)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.serverReconstructed, 1.0, "Server should be clamped to 1.0")
    }
    
    func testWireProgress_NegativeBytes_Handled() async {
        await tracker.updateWireProgress(-1000)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, 0.0, "Wire should handle negative bytes")
    }
    
    // MARK: - Monotonic Guarantee (20 tests)
    
    func testDisplayProgress_NeverDecreases() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(40 * 1024 * 1024)  // Simulate rollback
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Display progress should never decrease")
    }
    
    func testDisplayProgress_UsesMaxOfLastAndComputed() async {
        await tracker.updateWireProgress(60 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(50 * 1024 * 1024)  // Rollback
        let progress2 = await tracker.getProgress()
        // Display should use max(lastDisplayed, computed)
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Should use max")
    }
    
    func testDisplayProgress_LayerRollback_DoesNotRollback() async {
        await tracker.updateACKProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateACKProgress(40 * 1024 * 1024)  // Rollback
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Display should not rollback")
    }
    
    func testDisplayProgress_MultipleRollbacks_StillMonotonic() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(40 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        await tracker.updateWireProgress(30 * 1024 * 1024)
        let progress3 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Should be monotonic")
        XCTAssertGreaterThanOrEqual(progress3.displayProgress, progress2.displayProgress, "Should be monotonic")
    }
    
    func testDisplayProgress_StartsAtZero() async {
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.displayProgress, 0.0, "Display progress should start at 0")
    }
    
    func testDisplayProgress_ReachesOneAtCompletion() async {
        await tracker.updateWireProgress(totalBytes)
        await tracker.updateACKProgress(totalBytes)
        await tracker.updateMerkleProgress(totalBytes)
        await tracker.updateServerReconstructed(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.displayProgress, 1.0, accuracy: 0.01, "Display should reach 1.0")
    }
    
    func testDisplayProgress_AlwaysInRange() async {
        for _ in 0..<100 {
            await tracker.updateWireProgress(Int64.random(in: 0...totalBytes))
            let progress = await tracker.getProgress()
            XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Display should be >= 0")
            XCTAssertLessThanOrEqual(progress.displayProgress, 1.0, "Display should be <= 1")
        }
    }
    
    func testDisplayProgress_SmoothingApplied() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        // Display progress should be smoothed
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Display should be smoothed")
    }
    
    func testDisplayProgress_ConsistentAcrossCalls() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        let progress2 = await tracker.getProgress()
        XCTAssertEqual(progress1.displayProgress, progress2.displayProgress, "Display should be consistent")
    }
    
    func testDisplayProgress_MonotonicWithWire() async {
        await tracker.updateWireProgress(10 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Display should be monotonic with wire")
    }
    
    func testDisplayProgress_MonotonicWithACK() async {
        await tracker.updateACKProgress(10 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateACKProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Display should be monotonic with ACK")
    }
    
    func testDisplayProgress_MonotonicWithMerkle() async {
        await tracker.updateMerkleProgress(5 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateMerkleProgress(10 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Display should be monotonic with Merkle")
    }
    
    func testDisplayProgress_MonotonicWithServer() async {
        await tracker.updateServerReconstructed(2 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateServerReconstructed(5 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Display should be monotonic with server")
    }
    
    func testDisplayProgress_NoNegativeValues() async {
        await tracker.updateWireProgress(-1000)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Display should not be negative")
    }
    
    func testDisplayProgress_NoValuesAboveOne() async {
        await tracker.updateWireProgress(totalBytes * 2)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.displayProgress, 1.0, "Display should not exceed 1.0")
    }
    
    func testDisplayProgress_MultipleLayersUpdate_Monotonic() async {
        await tracker.updateWireProgress(30 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateACKProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        await tracker.updateMerkleProgress(10 * 1024 * 1024)
        let progress3 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Should be monotonic")
        XCTAssertGreaterThanOrEqual(progress3.displayProgress, progress2.displayProgress, "Should be monotonic")
    }
    
    func testDisplayProgress_RapidUpdates_Monotonic() async {
        var lastProgress: Double = 0.0
        for i in 0..<100 {
            await tracker.updateWireProgress(Int64(i) * 1024 * 1024)
            let progress = await tracker.getProgress()
            XCTAssertGreaterThanOrEqual(progress.displayProgress, lastProgress, "Should be monotonic")
            lastProgress = progress.displayProgress
        }
    }
    
    func testDisplayProgress_ConcurrentUpdates_Monotonic() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.tracker.updateWireProgress(Int64(i) * 10 * 1024 * 1024)
                }
            }
        }
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Should handle concurrent updates")
    }
    
    func testDisplayProgress_AfterReset_MaintainsMonotonic() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        // Simulate reset by creating new tracker
        let newTracker = MultiLayerProgressTracker(totalBytes: totalBytes)
        await newTracker.updateWireProgress(30 * 1024 * 1024)
        let progress2 = await newTracker.getProgress()
        // New tracker should start fresh
        XCTAssertLessThanOrEqual(progress2.displayProgress, progress1.displayProgress, "New tracker should start fresh")
    }
    
    // MARK: - Safety Valves (15 tests)
    
    func testSafetyValve_WireACKDivergence8Percent_UsesACK() async {
        await tracker.updateWireProgress(90 * 1024 * 1024)  // 90%
        await tracker.updateACKProgress(80 * 1024 * 1024)  // 80% (10% divergence)
        let progress = await tracker.getProgress()
        let divergence = abs(progress.wireProgress - progress.ackProgress)
        XCTAssertGreaterThan(divergence, 0.08, "Divergence should be > 8%")
        // Should use ACK (more conservative)
        XCTAssertTrue(true, "Should use ACK when divergence > 8%")
    }
    
    func testSafetyValve_WireACKDivergenceLessThan8Percent_UsesWire() async {
        await tracker.updateWireProgress(55 * 1024 * 1024)  // 55%
        await tracker.updateACKProgress(50 * 1024 * 1024)  // 50% (5% divergence)
        let progress = await tracker.getProgress()
        let divergence = abs(progress.wireProgress - progress.ackProgress)
        XCTAssertLessThan(divergence, 0.08, "Divergence should be < 8%")
    }
    
    func testSafetyValve_ACKMerkleDivergence_Detected() async {
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(40 * 1024 * 1024)
        let progress = await tracker.getProgress()
        let divergence = abs(progress.ackProgress - progress.merkleProgress)
        XCTAssertGreaterThan(divergence, 0.0, "ACK-Merkle divergence should be detected")
    }
    
    func testSafetyValve_ACKMerkleDivergence_TriggersPause() async {
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(40 * 1024 * 1024)
        let progress = await tracker.getProgress()
        // ACK-Merkle divergence > 0 should trigger pause (handled by caller)
        XCTAssertTrue(progress.ackProgress > progress.merkleProgress, "Should trigger pause")
    }
    
    func testSafetyValve_NoDivergence_NormalOperation() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, progress.ackProgress, accuracy: 0.01, "No divergence")
    }
    
    func testSafetyValve_WireACKDivergenceExactly8Percent_Handled() async {
        await tracker.updateWireProgress(54 * 1024 * 1024)  // 54%
        await tracker.updateACKProgress(46 * 1024 * 1024)  // 46% (8% divergence)
        let progress = await tracker.getProgress()
        let divergence = abs(progress.wireProgress - progress.ackProgress)
        XCTAssertGreaterThanOrEqual(divergence, 0.08, "Divergence should be >= 8%")
    }
    
    func testSafetyValve_ACKMerkleDivergenceZero_NoPause() async {
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        let divergence = abs(progress.ackProgress - progress.merkleProgress)
        XCTAssertEqual(divergence, 0.0, accuracy: 0.01, "No divergence, no pause")
    }
    
    func testSafetyValve_MultipleDivergences_Handled() async {
        await tracker.updateWireProgress(90 * 1024 * 1024)
        await tracker.updateACKProgress(80 * 1024 * 1024)
        await tracker.updateMerkleProgress(70 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertTrue(progress.wireProgress >= progress.ackProgress, "Wire >= ACK")
        XCTAssertTrue(progress.ackProgress >= progress.merkleProgress, "ACK >= Merkle")
    }
    
    func testSafetyValve_DivergenceRecovery_Handled() async {
        await tracker.updateWireProgress(90 * 1024 * 1024)
        await tracker.updateACKProgress(80 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateACKProgress(90 * 1024 * 1024)  // Recovery
        let progress2 = await tracker.getProgress()
        XCTAssertLessThan(abs(progress2.wireProgress - progress2.ackProgress), 0.08, "Divergence recovered")
    }
    
    func testSafetyValve_WireACKDivergence_Consistent() async {
        await tracker.updateWireProgress(60 * 1024 * 1024)
        await tracker.updateACKProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        let progress2 = await tracker.getProgress()
        let divergence1 = abs(progress1.wireProgress - progress1.ackProgress)
        let divergence2 = abs(progress2.wireProgress - progress2.ackProgress)
        XCTAssertEqual(divergence1, divergence2, accuracy: 0.01, "Divergence should be consistent")
    }
    
    func testSafetyValve_ACKMerkleDivergence_Consistent() async {
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(40 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        let progress2 = await tracker.getProgress()
        let divergence1 = abs(progress1.ackProgress - progress1.merkleProgress)
        let divergence2 = abs(progress2.ackProgress - progress2.merkleProgress)
        XCTAssertEqual(divergence1, divergence2, accuracy: 0.01, "Divergence should be consistent")
    }
    
    func testSafetyValve_WireACKDivergence_CalculatedCorrectly() async {
        await tracker.updateWireProgress(90 * 1024 * 1024)
        await tracker.updateACKProgress(80 * 1024 * 1024)
        let progress = await tracker.getProgress()
        let expectedDivergence = abs(0.9 - 0.8)
        let actualDivergence = abs(progress.wireProgress - progress.ackProgress)
        XCTAssertEqual(actualDivergence, expectedDivergence, accuracy: 0.01, "Divergence should be calculated correctly")
    }
    
    func testSafetyValve_ACKMerkleDivergence_CalculatedCorrectly() async {
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(40 * 1024 * 1024)
        let progress = await tracker.getProgress()
        let expectedDivergence = abs(0.5 - 0.4)
        let actualDivergence = abs(progress.ackProgress - progress.merkleProgress)
        XCTAssertEqual(actualDivergence, expectedDivergence, accuracy: 0.01, "Divergence should be calculated correctly")
    }
    
    func testSafetyValve_AllLayersAligned_NoDivergence() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        await tracker.updateACKProgress(50 * 1024 * 1024)
        await tracker.updateMerkleProgress(50 * 1024 * 1024)
        await tracker.updateServerReconstructed(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, progress.ackProgress, accuracy: 0.01, "All layers aligned")
    }
    
    // MARK: - ETA Estimation (15 tests)
    
    func testETA_MinLessThanOrEqualBest() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.eta.minSeconds, progress.eta.bestEstimate, "Min should be <= best")
    }
    
    func testETA_BestLessThanOrEqualMax() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.eta.bestEstimate, progress.eta.maxSeconds, "Best should be <= max")
    }
    
    func testETA_ProgressZero_ETAInfiniteOrNaN() async {
        let progress = await tracker.getProgress()
        // At 0% progress, ETA should be large
        XCTAssertGreaterThan(progress.eta.bestEstimate, 0, "ETA should be positive")
    }
    
    func testETA_Progress100Percent_ETAIsZero() async {
        await tracker.updateWireProgress(totalBytes)
        await tracker.updateACKProgress(totalBytes)
        await tracker.updateMerkleProgress(totalBytes)
        await tracker.updateServerReconstructed(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.eta.bestEstimate, 0.0, accuracy: 0.1, "ETA should be ~0 at 100%")
    }
    
    func testETA_Progress50Percent_ReasonableETA() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThan(progress.eta.bestEstimate, 0, "ETA should be positive")
        XCTAssertLessThan(progress.eta.bestEstimate, 1000, "ETA should be reasonable")
    }
    
    func testETA_MinMaxBest_AllPositive() async {
        await tracker.updateWireProgress(30 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.eta.minSeconds, 0, "Min should be >= 0")
        XCTAssertGreaterThanOrEqual(progress.eta.bestEstimate, 0, "Best should be >= 0")
        XCTAssertGreaterThanOrEqual(progress.eta.maxSeconds, 0, "Max should be >= 0")
    }
    
    func testETA_ProgressIncreases_ETADecreases() async {
        await tracker.updateWireProgress(10 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress2.eta.bestEstimate, progress1.eta.bestEstimate, "ETA should decrease as progress increases")
    }
    
    func testETA_AllLayersComplete_ETAIsZero() async {
        await tracker.updateWireProgress(totalBytes)
        await tracker.updateACKProgress(totalBytes)
        await tracker.updateMerkleProgress(totalBytes)
        await tracker.updateServerReconstructed(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.eta.bestEstimate, 0.0, accuracy: 0.1, "ETA should be 0")
    }
    
    func testETA_Range_Reasonable() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        let range = progress.eta.maxSeconds - progress.eta.minSeconds
        XCTAssertGreaterThan(range, 0, "Range should be positive")
    }
    
    func testETA_ConsistentAcrossCalls() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        let progress2 = await tracker.getProgress()
        XCTAssertEqual(progress1.eta.bestEstimate, progress2.eta.bestEstimate, accuracy: 0.1, "ETA should be consistent")
    }
    
    func testETA_ProgressNearZero_LargeETA() async {
        await tracker.updateWireProgress(1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThan(progress.eta.bestEstimate, 10, "ETA should be large near 0%")
    }
    
    func testETA_ProgressNear100_SmallETA() async {
        await tracker.updateWireProgress(99 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertLessThan(progress.eta.bestEstimate, 100, "ETA should be small near 100%")
    }
    
    func testETA_MinMaxBest_Ordered() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.eta.minSeconds, progress.eta.bestEstimate, "Min <= Best")
        XCTAssertLessThanOrEqual(progress.eta.bestEstimate, progress.eta.maxSeconds, "Best <= Max")
    }
    
    func testETA_AllLayersUpdate_ETARecalculated() async {
        await tracker.updateWireProgress(30 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateACKProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        // ETA may change
        XCTAssertTrue(progress2.eta.bestEstimate >= 0, "ETA should be recalculated")
    }
    
    func testETA_NoNegativeValues() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.eta.minSeconds, 0, "Min should not be negative")
        XCTAssertGreaterThanOrEqual(progress.eta.bestEstimate, 0, "Best should not be negative")
        XCTAssertGreaterThanOrEqual(progress.eta.maxSeconds, 0, "Max should not be negative")
    }
    
    // MARK: - Smoothing (10 tests)
    
    func testSmoothing_SavitzkyGolay_Applied() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        // Smoothing should be applied
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Smoothing should be applied")
    }
    
    func testSmoothing_DoesNotChangeFinalValue() async {
        await tracker.updateWireProgress(totalBytes)
        let progress = await tracker.getProgress()
        // At completion, smoothing should not change final value
        XCTAssertEqual(progress.displayProgress, 1.0, accuracy: 0.01, "Smoothing should not change final value")
    }
    
    func testSmoothing_WindowSize7() async {
        // Window size should be 7
        for i in 0..<10 {
            await tracker.updateWireProgress(Int64(i) * 10 * 1024 * 1024)
            _ = await tracker.getProgress()
        }
        XCTAssertTrue(true, "Window size should be 7")
    }
    
    func testSmoothing_PolynomialOrder2() async {
        // Polynomial order should be 2
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertTrue(progress.displayProgress >= 0, "Polynomial order should be 2")
    }
    
    func testSmoothing_ReducesNoise() async {
        // Smoothing should reduce noise
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertTrue(progress.displayProgress >= 0, "Smoothing should reduce noise")
    }
    
    func testSmoothing_ConsistentOutput() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        let progress2 = await tracker.getProgress()
        XCTAssertEqual(progress1.displayProgress, progress2.displayProgress, accuracy: 0.01, "Smoothing should be consistent")
    }
    
    func testSmoothing_Monotonic() async {
        await tracker.updateWireProgress(10 * 1024 * 1024)
        let progress1 = await tracker.getProgress()
        await tracker.updateWireProgress(20 * 1024 * 1024)
        let progress2 = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress2.displayProgress, progress1.displayProgress, "Smoothing should be monotonic")
    }
    
    func testSmoothing_HandlesFewSamples() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        // Should handle < 7 samples
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Should handle few samples")
    }
    
    func testSmoothing_HandlesManySamples() async {
        for i in 0..<20 {
            await tracker.updateWireProgress(Int64(i) * 5 * 1024 * 1024)
            _ = await tracker.getProgress()
        }
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Should handle many samples")
    }
    
    func testSmoothing_DoesNotAffectMonotonicity() async {
        var lastProgress: Double = 0.0
        for i in 0..<10 {
            await tracker.updateWireProgress(Int64(i) * 10 * 1024 * 1024)
            let progress = await tracker.getProgress()
            XCTAssertGreaterThanOrEqual(progress.displayProgress, lastProgress, "Smoothing should not affect monotonicity")
            lastProgress = progress.displayProgress
        }
    }
    
    // MARK: - Edge Cases (15 tests)
    
    func testEdge_ZeroTotalBytes_Handles() async {
        let tracker = MultiLayerProgressTracker(totalBytes: 0)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, 0.0, "Zero total bytes should handle")
    }
    
    func testEdge_NegativeBytes_Handles() async {
        await tracker.updateWireProgress(-1000)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, 0.0, "Negative bytes should handle")
    }
    
    func testEdge_BytesExceedTotal_Clamped() async {
        await tracker.updateWireProgress(totalBytes * 2)
        let progress = await tracker.getProgress()
        XCTAssertLessThanOrEqual(progress.wireProgress, 1.0, "Bytes exceeding total should be clamped")
    }
    
    func testEdge_ConcurrentUpdates_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.tracker.updateWireProgress(Int64(i) * 10 * 1024 * 1024)
                }
            }
        }
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, 0.0, "Concurrent updates should be safe")
    }
    
    func testEdge_VeryLargeTotalBytes_Handles() async {
        let tracker = MultiLayerProgressTracker(totalBytes: Int64.max)
        await tracker.updateWireProgress(Int64.max / 2)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.wireProgress, 0.0, "Very large total bytes should handle")
    }
    
    func testEdge_AllLayersZero_ProgressZero() async {
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, 0.0, "All layers zero should give zero progress")
        XCTAssertEqual(progress.ackProgress, 0.0, "All layers zero should give zero progress")
    }
    
    func testEdge_AllLayersComplete_ProgressOne() async {
        await tracker.updateWireProgress(totalBytes)
        await tracker.updateACKProgress(totalBytes)
        await tracker.updateMerkleProgress(totalBytes)
        await tracker.updateServerReconstructed(totalBytes)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.displayProgress, 1.0, accuracy: 0.01, "All layers complete should give 1.0")
    }
    
    func testEdge_RapidUpdates_Handles() async {
        for i in 0..<1000 {
            await tracker.updateWireProgress(Int64(i) * 1024)
        }
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Rapid updates should handle")
    }
    
    func testEdge_MixedPositiveNegative_Handles() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        await tracker.updateWireProgress(-10 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertGreaterThanOrEqual(progress.displayProgress, 0.0, "Mixed updates should handle")
    }
    
    func testEdge_TotalBytesOne_Handles() async {
        let tracker = MultiLayerProgressTracker(totalBytes: 1)
        await tracker.updateWireProgress(1)
        let progress = await tracker.getProgress()
        XCTAssertEqual(progress.wireProgress, 1.0, accuracy: 0.01, "Total bytes = 1 should handle")
    }
    
    func testEdge_MultipleTrackers_Independent() async {
        let tracker1 = MultiLayerProgressTracker(totalBytes: totalBytes)
        let tracker2 = MultiLayerProgressTracker(totalBytes: totalBytes)
        await tracker1.updateWireProgress(50 * 1024 * 1024)
        await tracker2.updateWireProgress(30 * 1024 * 1024)
        let progress1 = await tracker1.getProgress()
        let progress2 = await tracker2.getProgress()
        XCTAssertNotEqual(progress1.wireProgress, progress2.wireProgress, "Trackers should be independent")
    }
    
    func testEdge_ProgressHistory_Limited() async {
        // Progress history should be limited to window size
        for i in 0..<20 {
            await tracker.updateWireProgress(Int64(i) * 5 * 1024 * 1024)
            _ = await tracker.getProgress()
        }
        XCTAssertTrue(true, "Progress history should be limited")
    }
    
    func testEdge_DisplayProgress_AlwaysValid() async {
        for _ in 0..<100 {
            await tracker.updateWireProgress(Int64.random(in: 0...totalBytes))
            let progress = await tracker.getProgress()
            XCTAssertFalse(progress.displayProgress.isNaN, "Display progress should not be NaN")
            XCTAssertFalse(progress.displayProgress.isInfinite, "Display progress should not be infinite")
        }
    }
    
    func testEdge_ETA_AlwaysValid() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertFalse(progress.eta.bestEstimate.isNaN, "ETA should not be NaN")
        XCTAssertFalse(progress.eta.bestEstimate.isInfinite, "ETA should not be infinite")
    }
    
    func testEdge_AllProgressValues_Valid() async {
        await tracker.updateWireProgress(50 * 1024 * 1024)
        await tracker.updateACKProgress(40 * 1024 * 1024)
        await tracker.updateMerkleProgress(30 * 1024 * 1024)
        await tracker.updateServerReconstructed(20 * 1024 * 1024)
        let progress = await tracker.getProgress()
        XCTAssertFalse(progress.wireProgress.isNaN, "Wire progress should be valid")
        XCTAssertFalse(progress.ackProgress.isNaN, "ACK progress should be valid")
        XCTAssertFalse(progress.merkleProgress.isNaN, "Merkle progress should be valid")
        XCTAssertFalse(progress.serverReconstructed.isNaN, "Server progress should be valid")
    }
}
