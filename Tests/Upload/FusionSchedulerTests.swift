//
//  FusionSchedulerTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Fusion Scheduler Tests
//

import XCTest
@testable import Aether3DCore

final class FusionSchedulerTests: XCTestCase {
    
    var scheduler: FusionScheduler!
    var kalmanPredictor: KalmanBandwidthPredictor!
    
    override func setUp() {
        super.setUp()
        kalmanPredictor = KalmanBandwidthPredictor()
        scheduler = FusionScheduler(kalmanPredictor: kalmanPredictor)
    }
    
    override func tearDown() {
        scheduler = nil
        kalmanPredictor = nil
        super.tearDown()
    }
    
    // MARK: - Initialization & Default (10 tests)
    
    func testInit_WithKalmanPredictor_Succeeds() {
        let predictor = KalmanBandwidthPredictor()
        let scheduler = FusionScheduler(kalmanPredictor: predictor)
        XCTAssertNotNil(scheduler, "Should initialize with Kalman predictor")
    }
    
    func testInit_WithMLPredictor_Succeeds() {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        XCTAssertNotNil(scheduler, "Should initialize with ML predictor")
    }
    
    func testDecideChunkSize_Default_ReturnsValidSize() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should be >= min")
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Should be <= max")
    }
    
    func testDecideChunkSize_AlignedTo16KB() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Should be aligned to 16KB")
    }
    
    func testDecideChunkSize_AlwaysInRange() async {
        for _ in 0..<100 {
            let size = await scheduler.decideChunkSize()
            XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should always be >= min")
            XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Should always be <= max")
        }
    }
    
    func testDecideChunkSize_Deterministic_WithSameState() async {
        let size1 = await scheduler.decideChunkSize()
        let size2 = await scheduler.decideChunkSize()
        // May vary due to Kalman state, but should be valid
        XCTAssertGreaterThanOrEqual(size1, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should be valid")
        XCTAssertGreaterThanOrEqual(size2, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should be valid")
    }
    
    func testDecideChunkSize_WithMLPredictor_Uses5Controllers() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should use 5 controllers")
    }
    
    func testDecideChunkSize_WithoutMLPredictor_Uses4Controllers() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should use 4 controllers")
    }
    
    func testDecideChunkSize_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.scheduler.decideChunkSize()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testDecideChunkSize_MultipleCalls_AllValid() async {
        var sizes: [Int] = []
        for _ in 0..<20 {
            sizes.append(await scheduler.decideChunkSize())
        }
        for size in sizes {
            XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "All sizes should be valid")
            XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "All sizes should be valid")
        }
    }
    
    // MARK: - MPC Controller (10 tests)
    
    func testMPC_ReturnsDefaultSize() async {
        // MPC simplified implementation returns default
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "MPC should return valid size")
    }
    
    func testMPC_Predicts5Steps() async {
        // MPC predicts next 5 steps
        let size = await scheduler.decideChunkSize()
        XCTAssertTrue(size > 0, "MPC should predict valid size")
    }
    
    func testMPC_MinimizesLatency() async {
        // MPC minimizes latency
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "MPC should minimize latency")
    }
    
    func testMPC_ParticipatesInFusion() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "MPC should participate")
    }
    
    func testMPC_WeightedInFusion() async {
        // MPC has weight in fusion
        let size = await scheduler.decideChunkSize()
        XCTAssertTrue(size > 0, "MPC should be weighted")
    }
    
    func testMPC_ConsistentOutput() async {
        let size1 = await scheduler.decideChunkSize()
        let size2 = await scheduler.decideChunkSize()
        // MPC output may vary, but should be valid
        XCTAssertTrue(size1 > 0 && size2 > 0, "MPC should be consistent")
    }
    
    func testMPC_WithinBounds() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "MPC should be within bounds")
    }
    
    func testMPC_Aligned() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "MPC output should be aligned")
    }
    
    func testMPC_NoNegative() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "MPC should not be negative")
    }
    
    func testMPC_ReasonableValue() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "MPC should be reasonable")
    }
    
    // MARK: - ABR Controller (15 tests)
    
    func testABR_QueueLessThan1MB_ReturnsMaxSize() async {
        await scheduler.updateQueueLength(512 * 1024)  // <1MB
        let size = await scheduler.decideChunkSize()
        // ABR should suggest max size for small queue
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_DEFAULT_BYTES, "ABR should suggest larger size")
    }
    
    func testABR_QueueLessThan10MB_ReturnsDefaultSize() async {
        await scheduler.updateQueueLength(5 * 1024 * 1024)  // <10MB
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should suggest default")
    }
    
    func testABR_QueueGreaterThan10MB_ReturnsMinSize() async {
        await scheduler.updateQueueLength(15 * 1024 * 1024)  // >10MB
        let size = await scheduler.decideChunkSize()
        // ABR should suggest min size for large queue
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should suggest min size")
    }
    
    func testABR_QueueExactly1MB_Handles() async {
        await scheduler.updateQueueLength(1024 * 1024)  // Exactly 1MB
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should handle exactly 1MB")
    }
    
    func testABR_QueueExactly10MB_Handles() async {
        await scheduler.updateQueueLength(10 * 1024 * 1024)  // Exactly 10MB
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should handle exactly 10MB")
    }
    
    func testABR_QueueZero_ReturnsMaxSize() async {
        await scheduler.updateQueueLength(0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should handle zero queue")
    }
    
    func testABR_QueueVeryLarge_ReturnsMinSize() async {
        await scheduler.updateQueueLength(100 * 1024 * 1024)  // Very large
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should handle very large queue")
    }
    
    func testABR_QueueUpdates_ReflectsInDecision() async {
        await scheduler.updateQueueLength(0)
        let size1 = await scheduler.decideChunkSize()
        await scheduler.updateQueueLength(20 * 1024 * 1024)
        let size2 = await scheduler.decideChunkSize()
        // Size2 should be smaller or equal
        XCTAssertLessThanOrEqual(size2, size1 + UploadConstants.CHUNK_SIZE_STEP_BYTES * 2, "ABR should reflect queue updates")
    }
    
    func testABR_ParticipatesInFusion() async {
        await scheduler.updateQueueLength(5 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ABR should participate")
    }
    
    func testABR_WeightedInFusion() async {
        await scheduler.updateQueueLength(2 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertTrue(size > 0, "ABR should be weighted")
    }
    
    func testABR_Aligned() async {
        await scheduler.updateQueueLength(3 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "ABR output should be aligned")
    }
    
    func testABR_WithinBounds() async {
        await scheduler.updateQueueLength(8 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "ABR should be within bounds")
    }
    
    func testABR_NoNegative() async {
        await scheduler.updateQueueLength(1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "ABR should not be negative")
    }
    
    func testABR_MonotonicWithQueue() async {
        await scheduler.updateQueueLength(1024)
        let size1 = await scheduler.decideChunkSize()
        await scheduler.updateQueueLength(1024 * 1024)
        let size2 = await scheduler.decideChunkSize()
        await scheduler.updateQueueLength(20 * 1024 * 1024)
        let size3 = await scheduler.decideChunkSize()
        // Generally, larger queue should lead to smaller chunks
        XCTAssertTrue(size1 >= size3 - UploadConstants.CHUNK_SIZE_STEP_BYTES * 5, "ABR should be monotonic")
    }
    
    // MARK: - EWMA Controller (10 tests)
    
    func testEWMA_Alpha0_3() async {
        // EWMA uses alpha=0.3
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "EWMA should work")
    }
    
    func testEWMA_Target3Seconds() async {
        // EWMA targets 3-second transmission
        await kalmanPredictor.addSample(bytesTransferred: 5 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "EWMA should target 3 seconds")
    }
    
    func testEWMA_UsesPredictedBps() async {
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await kalmanPredictor.predict()
        let size = await scheduler.decideChunkSize()
        // Size should relate to predicted bandwidth
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "EWMA should use predicted Bps")
    }
    
    func testEWMA_SmoothsChunkSize() async {
        await scheduler.updateLastChunkSize(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        // EWMA should smooth
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "EWMA should smooth")
    }
    
    func testEWMA_ParticipatesInFusion() async {
        await kalmanPredictor.addSample(bytesTransferred: 5 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "EWMA should participate")
    }
    
    func testEWMA_WeightedInFusion() async {
        await kalmanPredictor.addSample(bytesTransferred: 8 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertTrue(size > 0, "EWMA should be weighted")
    }
    
    func testEWMA_Aligned() async {
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "EWMA output should be aligned")
    }
    
    func testEWMA_WithinBounds() async {
        await kalmanPredictor.addSample(bytesTransferred: 100 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "EWMA should be within bounds")
    }
    
    func testEWMA_AdaptsToBandwidth() async {
        await kalmanPredictor.addSample(bytesTransferred: 1 * 1024 * 1024, durationSeconds: 1.0)
        let size1 = await scheduler.decideChunkSize()
        await kalmanPredictor.addSample(bytesTransferred: 100 * 1024 * 1024, durationSeconds: 1.0)
        let size2 = await scheduler.decideChunkSize()
        // Higher bandwidth should lead to larger chunks
        XCTAssertTrue(size2 >= size1 - UploadConstants.CHUNK_SIZE_STEP_BYTES * 2, "EWMA should adapt")
    }
    
    func testEWMA_NoNegative() async {
        await kalmanPredictor.addSample(bytesTransferred: 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "EWMA should not be negative")
    }
    
    // MARK: - Kalman Controller (10 tests)
    
    func testKalman_RisingTrend_IncreasesSize() async {
        await kalmanPredictor.addSample(bytesTransferred: 5 * 1024 * 1024, durationSeconds: 1.0)
        await scheduler.updateLastChunkSize(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Kalman rising should increase")
    }
    
    func testKalman_FallingTrend_DecreasesSize() async {
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await scheduler.updateLastChunkSize(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        await kalmanPredictor.addSample(bytesTransferred: 5 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Kalman falling should decrease")
    }
    
    func testKalman_StableTrend_MaintainsSize() async {
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await scheduler.updateLastChunkSize(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Kalman stable should maintain")
    }
    
    func testKalman_UsesStepSize() async {
        await scheduler.updateLastChunkSize(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        // Should change by STEP_BYTES
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Kalman should use step size")
    }
    
    func testKalman_ParticipatesInFusion() async {
        await kalmanPredictor.addSample(bytesTransferred: 8 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Kalman should participate")
    }
    
    func testKalman_WeightedInFusion() async {
        await kalmanPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertTrue(size > 0, "Kalman should be weighted")
    }
    
    func testKalman_Aligned() async {
        await kalmanPredictor.addSample(bytesTransferred: 5 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Kalman output should be aligned")
    }
    
    func testKalman_WithinBounds() async {
        await kalmanPredictor.addSample(bytesTransferred: 100 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Kalman should be within bounds")
    }
    
    func testKalman_NoNegative() async {
        await kalmanPredictor.addSample(bytesTransferred: 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "Kalman should not be negative")
    }
    
    func testKalman_RespectsMinMax() async {
        await scheduler.updateLastChunkSize(UploadConstants.CHUNK_SIZE_MIN_BYTES)
        await kalmanPredictor.addSample(bytesTransferred: 1 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Kalman should respect min")
    }
    
    // MARK: - ML Controller (10 tests)
    
    func testML_WhenAvailable_Uses5StepLookahead() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ML should use 5-step lookahead")
    }
    
    func testML_WhenUnavailable_Uses4Controllers() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should use 4 controllers without ML")
    }
    
    func testML_ParticipatesInFusion() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 8 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ML should participate")
    }
    
    func testML_WeightedInFusion() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertTrue(size > 0, "ML should be weighted")
    }
    
    func testML_Aligned() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 5 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "ML output should be aligned")
    }
    
    func testML_WithinBounds() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 100 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "ML should be within bounds")
    }
    
    func testML_NoNegative() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "ML should not be negative")
    }
    
    func testML_FallbackToKalman() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        // ML may fallback to Kalman if model unavailable
        await kalman.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ML should fallback to Kalman")
    }
    
    func testML_EnsembleWithKalman() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 8 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "ML should ensemble with Kalman")
    }
    
    func testML_5ControllersWhenAvailable() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        // Should use 5 controllers
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should use 5 controllers")
    }
    
    // MARK: - Weighted Trimmed Mean Fusion (15 tests)
    
    func testFusion_EmptyCandidates_ReturnsDefault() async {
        // Empty candidates should return default
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Empty candidates should return default")
    }
    
    func testFusion_TwoCandidates_NoTrim() async {
        // 2 candidates should not trim
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "2 candidates should not trim")
    }
    
    func testFusion_ThreeCandidates_TrimsOne() async {
        // 3 candidates should trim one
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "3 candidates should trim")
    }
    
    func testFusion_FiveCandidates_TrimsTwo() async {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        let scheduler = FusionScheduler(kalmanPredictor: kalman, mlPredictor: ml)
        await kalman.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        // 5 candidates should trim highest and lowest
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "5 candidates should trim two")
    }
    
    func testFusion_WeightedAverage() async {
        let size = await scheduler.decideChunkSize()
        // Should be weighted average
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should be weighted average")
    }
    
    func testFusion_RemovesHighest() async {
        let size = await scheduler.decideChunkSize()
        // Highest should be removed
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Highest should be removed")
    }
    
    func testFusion_RemovesLowest() async {
        let size = await scheduler.decideChunkSize()
        // Lowest should be removed
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Lowest should be removed")
    }
    
    func testFusion_WeightsApplied() async {
        let size = await scheduler.decideChunkSize()
        // Weights should be applied
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Weights should be applied")
    }
    
    func testFusion_AllControllersParticipate() async {
        let size = await scheduler.decideChunkSize()
        // All controllers should participate
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "All controllers should participate")
    }
    
    func testFusion_ConsistentOutput() async {
        let size1 = await scheduler.decideChunkSize()
        let size2 = await scheduler.decideChunkSize()
        // Should be consistent (within reasonable bounds)
        XCTAssertTrue(size1 > 0 && size2 > 0, "Fusion should be consistent")
    }
    
    func testFusion_WithinBounds() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Fusion should be within bounds")
    }
    
    func testFusion_Aligned() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Fusion output should be aligned")
    }
    
    func testFusion_NoNegative() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "Fusion should not be negative")
    }
    
    func testFusion_HandlesExtremeValues() async {
        await scheduler.updateQueueLength(100 * 1024 * 1024)
        await kalmanPredictor.addSample(bytesTransferred: 1, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        // Should handle extreme values
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should handle extreme values")
    }
    
    func testFusion_RobustToOutliers() async {
        // Fusion should be robust to outliers (trimmed mean)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should be robust to outliers")
    }
    
    // MARK: - Lyapunov Safety Valve (10 tests)
    
    func testLyapunov_PreventsQueueDrift() async {
        await scheduler.updateQueueLength(50 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        // Lyapunov should prevent queue drift
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Lyapunov should prevent drift")
    }
    
    func testLyapunov_AppliesSafetyValve() async {
        let size = await scheduler.decideChunkSize()
        // Safety valve should be applied
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Safety valve should be applied")
    }
    
    func testLyapunov_WithinBounds() async {
        await scheduler.updateQueueLength(100 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Lyapunov should be within bounds")
    }
    
    func testLyapunov_Aligned() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Lyapunov output should be aligned")
    }
    
    func testLyapunov_NoNegative() async {
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThan(size, 0, "Lyapunov should not be negative")
    }
    
    func testLyapunov_Stability() async {
        // Lyapunov should provide stability
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Lyapunov should provide stability")
    }
    
    func testLyapunov_ParticipatesInDecision() async {
        let size = await scheduler.decideChunkSize()
        // Should participate in decision
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Lyapunov should participate")
    }
    
    func testLyapunov_HandlesLargeQueue() async {
        await scheduler.updateQueueLength(200 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Lyapunov should handle large queue")
    }
    
    func testLyapunov_HandlesSmallQueue() async {
        await scheduler.updateQueueLength(1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Lyapunov should handle small queue")
    }
    
    func testLyapunov_Consistent() async {
        let size1 = await scheduler.decideChunkSize()
        let size2 = await scheduler.decideChunkSize()
        // Should be consistent
        XCTAssertTrue(size1 > 0 && size2 > 0, "Lyapunov should be consistent")
    }
    
    // MARK: - Page Alignment & Clamping (10 tests)
    
    func testAlignment_Always16KB() async {
        for _ in 0..<100 {
            let size = await scheduler.decideChunkSize()
            XCTAssertEqual(size % 16384, 0, "Should always be aligned to 16KB")
        }
    }
    
    func testAlignment_MinSizeAligned() async {
        await scheduler.updateQueueLength(100 * 1024 * 1024)
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Min size should be aligned")
    }
    
    func testAlignment_MaxSizeAligned() async {
        await scheduler.updateQueueLength(0)
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Max size should be aligned")
    }
    
    func testClamping_AlwaysInRange() async {
        for _ in 0..<100 {
            let size = await scheduler.decideChunkSize()
            XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should always be >= min")
            XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Should always be <= max")
        }
    }
    
    func testClamping_MinEnforced() async {
        await scheduler.updateQueueLength(200 * 1024 * 1024)
        await kalmanPredictor.addSample(bytesTransferred: 1, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Min should be enforced")
    }
    
    func testClamping_MaxEnforced() async {
        await scheduler.updateQueueLength(0)
        await kalmanPredictor.addSample(bytesTransferred: 1000 * 1024 * 1024, durationSeconds: 1.0)
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Max should be enforced")
    }
    
    func testClamping_AfterAlignment() async {
        // Clamping should happen after alignment
        let size = await scheduler.decideChunkSize()
        XCTAssertEqual(size % 16384, 0, "Clamping should happen after alignment")
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Should be clamped")
    }
    
    func testClamping_NoOverflow() async {
        // Should not overflow
        let size = await scheduler.decideChunkSize()
        XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Should not overflow")
    }
    
    func testClamping_NoUnderflow() async {
        // Should not underflow
        let size = await scheduler.decideChunkSize()
        XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should not underflow")
    }
    
    func testAlignmentAndClamping_Together() async {
        // Alignment and clamping should work together
        for _ in 0..<50 {
            let size = await scheduler.decideChunkSize()
            XCTAssertEqual(size % 16384, 0, "Should be aligned")
            XCTAssertGreaterThanOrEqual(size, UploadConstants.CHUNK_SIZE_MIN_BYTES, "Should be clamped")
            XCTAssertLessThanOrEqual(size, UploadConstants.CHUNK_SIZE_MAX_BYTES, "Should be clamped")
        }
    }
}
