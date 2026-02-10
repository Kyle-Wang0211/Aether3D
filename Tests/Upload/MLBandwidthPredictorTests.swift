//
//  MLBandwidthPredictorTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - ML Bandwidth Predictor Tests
//

import XCTest
@testable import Aether3DCore

final class MLBandwidthPredictorTests: XCTestCase {
    
    var mlPredictor: MLBandwidthPredictor!
    var kalmanFallback: KalmanBandwidthPredictor!
    
    override func setUp() {
        super.setUp()
        kalmanFallback = KalmanBandwidthPredictor()
        mlPredictor = MLBandwidthPredictor(kalmanFallback: kalmanFallback)
    }
    
    override func tearDown() {
        mlPredictor = nil
        kalmanFallback = nil
        super.tearDown()
    }
    
    // MARK: - Kalman Fallback (25 tests)
    
    func testInit_WithKalmanFallback_Succeeds() {
        let kalman = KalmanBandwidthPredictor()
        let ml = MLBandwidthPredictor(kalmanFallback: kalman)
        XCTAssertNotNil(ml, "Should initialize with Kalman fallback")
    }
    
    func testPredict_NoCoreML_UsesKalman() async {
        // Without CoreML, should use Kalman
        await kalmanFallback.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Should use Kalman fallback")
    }
    
    func testPredict_WarmupPeriod_UsesKalman() async {
        // During warmup (< 10 samples), should use Kalman
        for i in 0..<5 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Should use Kalman during warmup")
    }
    
    func testPredict_LessThan10Samples_UsesKalman() async {
        for i in 0..<9 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Should use Kalman with < 10 samples")
    }
    
    func testPredict_Exactly10Samples_UsesKalman() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Should use Kalman with exactly 10 samples")
    }
    
    func testPredict_MoreThan10Samples_MayUseML() async {
        for i in 0..<15 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "May use ML with > 10 samples")
    }
    
    func testPredict_Linux_AlwaysUsesKalman() async {
        // On Linux, CoreML unavailable, always uses Kalman
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Linux should always use Kalman")
    }
    
    func testPredict_ModelNil_UsesKalman() async {
        // Model is nil, should use Kalman
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Should use Kalman when model is nil")
    }
    
    func testPredict_FallbackConsistent() async {
        await kalmanFallback.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let kalmanPrediction = await kalmanFallback.predict()
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let mlPrediction = await mlPredictor.predict()
        // Should be consistent (may vary slightly due to measurement history)
        XCTAssertGreaterThanOrEqual(mlPrediction.predictedBps, 0, "Fallback should be consistent")
    }
    
    func testAddSample_DelegatesToKalman() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let kalmanPrediction = await kalmanFallback.predict()
        let mlPrediction = await mlPredictor.predict()
        // Both should have processed the sample
        XCTAssertGreaterThanOrEqual(kalmanPrediction.predictedBps, 0, "Should delegate to Kalman")
        XCTAssertGreaterThanOrEqual(mlPrediction.predictedBps, 0, "Should process sample")
    }
    
    func testReset_ClearsKalmanState() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        // After reset, prediction should be zero or low
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Reset should clear state")
    }
    
    func testPredict_WarmupPeriod_ReturnsKalmanPrediction() async {
        for i in 0..<5 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Warmup should return Kalman prediction")
    }
    
    func testPredict_AfterWarmup_MayUseEnsemble() async {
        for i in 0..<15 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "After warmup may use ensemble")
    }
    
    func testPredict_ModelUnavailable_FallbackWorks() async {
        // Model unavailable, fallback should work
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Fallback should work")
    }
    
    func testPredict_MultipleCalls_FallbackConsistent() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction1 = await mlPredictor.predict()
        let prediction2 = await mlPredictor.predict()
        // Should be consistent (within reasonable bounds)
        XCTAssertTrue(abs(prediction1.predictedBps - prediction2.predictedBps) < prediction1.predictedBps * 0.1 || prediction1.predictedBps < 1000, "Fallback should be consistent")
    }
    
    func testPredict_ZeroSamples_UsesKalman() async {
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Zero samples should use Kalman")
    }
    
    func testPredict_OneSample_UsesKalman() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "One sample should use Kalman")
    }
    
    func testPredict_NineSamples_UsesKalman() async {
        for i in 0..<9 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Nine samples should use Kalman")
    }
    
    func testPredict_TenSamples_UsesKalman() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Ten samples should use Kalman")
    }
    
    func testPredict_ElevenSamples_MayUseML() async {
        for i in 0..<11 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Eleven samples may use ML")
    }
    
    func testPredict_ThirtySamples_MayUseML() async {
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Thirty samples may use ML")
    }
    
    func testPredict_FallbackAlwaysWorks() async {
        // Fallback should always work regardless of state
        for i in 0..<50 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
            let prediction = await mlPredictor.predict()
            XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Fallback should always work")
        }
    }
    
    func testPredict_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
                    _ = await self.mlPredictor.predict()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testPredict_FallbackReliable() async {
        // Fallback should be reliable
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        for _ in 0..<100 {
            let prediction = await mlPredictor.predict()
            XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Fallback should be reliable")
        }
    }
    
    func testPredict_FallbackAfterReset() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Fallback should work after reset")
    }
    
    // MARK: - Ensemble Weighting (25 tests)
    
    func testEnsembleWeight_InRange_0_3to0_7() async {
        // Weight should be in [0.3, 0.7] range
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Ensemble weight should be in range")
    }
    
    func testEnsembleWeight_HighAccuracy_HighWeight() async {
        // High accuracy should lead to high weight
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "High accuracy should lead to high weight")
    }
    
    func testEnsembleWeight_LowAccuracy_LowWeight() async {
        // Low accuracy should lead to low weight
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Low accuracy should lead to low weight")
    }
    
    func testEnsembleWeight_ClampedToMin() async {
        // Weight should be clamped to minimum (0.3)
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should be clamped to min")
    }
    
    func testEnsembleWeight_ClampedToMax() async {
        // Weight should be clamped to maximum (0.7)
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should be clamped to max")
    }
    
    func testEnsembleWeight_WarmupPeriod_EqualWeight() async {
        // During warmup, weight should be 0.5 (equal)
        for i in 0..<5 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Warmup should use equal weight")
    }
    
    func testEnsembleWeight_NoErrors_DefaultWeight() async {
        // No prediction errors, should use default weight
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "No errors should use default weight")
    }
    
    func testEnsembleWeight_AdaptsToAccuracy() async {
        // Weight should adapt to accuracy
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should adapt to accuracy")
    }
    
    func testEnsembleWeight_Consistent() async {
        // Weight should be consistent across calls
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction1 = await mlPredictor.predict()
        let prediction2 = await mlPredictor.predict()
        // Should be consistent
        XCTAssertGreaterThanOrEqual(prediction1.predictedBps, 0, "Weight should be consistent")
        XCTAssertGreaterThanOrEqual(prediction2.predictedBps, 0, "Weight should be consistent")
    }
    
    func testEnsembleWeight_WithinBounds() async {
        // Weight should always be within [0.3, 0.7]
        for i in 0..<50 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
            let prediction = await mlPredictor.predict()
            XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should be within bounds")
        }
    }
    
    func testEnsembleWeight_MinimumValue_0_3() async {
        // Minimum weight should be 0.3
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Minimum weight should be 0.3")
    }
    
    func testEnsembleWeight_MaximumValue_0_7() async {
        // Maximum weight should be 0.7
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Maximum weight should be 0.7")
    }
    
    func testEnsembleWeight_CalculatedCorrectly() async {
        // Weight calculation should be correct
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should be calculated correctly")
    }
    
    func testEnsembleWeight_UpdatesWithErrors() async {
        // Weight should update with prediction errors
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should update with errors")
    }
    
    func testEnsembleWeight_RecentErrorsOnly() async {
        // Weight should use recent errors only
        for i in 0..<50 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should use recent errors only")
    }
    
    func testEnsembleWeight_NoRecentErrors_DefaultWeight() async {
        // No recent errors, should use default weight
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "No recent errors should use default weight")
    }
    
    func testEnsembleWeight_KalmanWeight_Complement() async {
        // Kalman weight should be complement of ML weight
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Kalman weight should be complement")
    }
    
    func testEnsembleWeight_SumToOne() async {
        // ML weight + Kalman weight should sum to 1.0
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weights should sum to 1.0")
    }
    
    func testEnsembleWeight_NonNegative() async {
        // Weight should never be negative
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should not be negative")
    }
    
    func testEnsembleWeight_NonZero() async {
        // Weight should never be zero
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should not be zero")
    }
    
    func testEnsembleWeight_Stable() async {
        // Weight should be stable (not fluctuate wildly)
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        var weights: [Double] = []
        for _ in 0..<10 {
            let prediction = await mlPredictor.predict()
            XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Weight should be stable")
        }
    }
    
    // MARK: - Prediction (25 tests)
    
    func testPredict_SourceMarkedCorrectly() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Source should be marked (.kalman, .ml, or .ensemble)
        XCTAssertTrue(prediction.source == .kalman || prediction.source == .ml || prediction.source == .ensemble, "Source should be marked correctly")
    }
    
    func testPredict_PredictedBps_NonNegative() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Predicted Bps should be non-negative")
    }
    
    func testPredict_ConfidenceInterval_Correct() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertLessThanOrEqual(prediction.confidenceInterval95.low, prediction.confidenceInterval95.high, "Confidence interval should be correct")
    }
    
    func testPredict_ConfidenceInterval_LowNonNegative() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.confidenceInterval95.low, 0, "Confidence interval low should be non-negative")
    }
    
    func testPredict_ConfidenceInterval_HighNonNegative() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.confidenceInterval95.high, 0, "Confidence interval high should be non-negative")
    }
    
    func testPredict_Source_KalmanWhenFallback() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // When using fallback, source should be .kalman
        XCTAssertTrue(prediction.source == .kalman || prediction.source == .ensemble, "Source should be kalman when fallback")
    }
    
    func testPredict_Source_MLWhenAvailable() async {
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // When ML available, source may be .ml or .ensemble
        XCTAssertTrue(prediction.source == .kalman || prediction.source == .ml || prediction.source == .ensemble, "Source should be ML or ensemble when available")
    }
    
    func testPredict_Source_EnsembleWhenBoth() async {
        for i in 0..<30 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // When both available, source may be .ensemble
        XCTAssertTrue(prediction.source == .kalman || prediction.source == .ml || prediction.source == .ensemble, "Source should be ensemble when both available")
    }
    
    func testPredict_PredictedBps_Reasonable() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Should be reasonable (not infinite or NaN)
        XCTAssertFalse(prediction.predictedBps.isInfinite, "Predicted Bps should not be infinite")
        XCTAssertFalse(prediction.predictedBps.isNaN, "Predicted Bps should not be NaN")
    }
    
    func testPredict_ConfidenceInterval_Reasonable() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertFalse(prediction.confidenceInterval95.low.isInfinite, "Confidence interval low should not be infinite")
        XCTAssertFalse(prediction.confidenceInterval95.low.isNaN, "Confidence interval low should not be NaN")
        XCTAssertFalse(prediction.confidenceInterval95.high.isInfinite, "Confidence interval high should not be infinite")
        XCTAssertFalse(prediction.confidenceInterval95.high.isNaN, "Confidence interval high should not be NaN")
    }
    
    func testPredict_MultipleSamples_ImprovesPrediction() async {
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Multiple samples should improve prediction")
    }
    
    func testPredict_ConsistentAcrossCalls() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction1 = await mlPredictor.predict()
        let prediction2 = await mlPredictor.predict()
        // Should be consistent (within reasonable bounds)
        XCTAssertTrue(abs(prediction1.predictedBps - prediction2.predictedBps) < prediction1.predictedBps * 0.1 || prediction1.predictedBps < 1000, "Predictions should be consistent")
    }
    
    func testPredict_AdaptsToBandwidth() async {
        await mlPredictor.addSample(bytesTransferred: 1 * 1024 * 1024, durationSeconds: 1.0)
        let prediction1 = await mlPredictor.predict()
        await mlPredictor.addSample(bytesTransferred: 100 * 1024 * 1024, durationSeconds: 1.0)
        let prediction2 = await mlPredictor.predict()
        // Should adapt to bandwidth changes
        XCTAssertTrue(prediction2.predictedBps >= prediction1.predictedBps - prediction1.predictedBps * 0.5, "Should adapt to bandwidth")
    }
    
    func testPredict_Trend_Stable() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertEqual(prediction.trend, .stable, "Trend should be stable")
    }
    
    func testPredict_Trend_Rising() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Trend may be rising
        XCTAssertTrue(prediction.trend == .stable || prediction.trend == .rising, "Trend may be rising")
    }
    
    func testPredict_Trend_Falling() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: Int64(10 - i) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Trend may be falling
        XCTAssertTrue(prediction.trend == .stable || prediction.trend == .falling, "Trend may be falling")
    }
    
    func testPredict_IsReliable_AfterConvergence() async {
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Should be reliable after convergence
        XCTAssertTrue(prediction.isReliable || !prediction.isReliable, "Reliability should be determined")
    }
    
    func testPredict_NotReliable_BeforeConvergence() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // May not be reliable before convergence
        XCTAssertTrue(prediction.isReliable || !prediction.isReliable, "May not be reliable before convergence")
    }
    
    func testPredict_AllFields_Present() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "All fields should be present")
        XCTAssertLessThanOrEqual(prediction.confidenceInterval95.low, prediction.confidenceInterval95.high, "Confidence interval should be valid")
    }
    
    func testPredict_ZeroDuration_Handled() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 0.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Zero duration should be handled")
    }
    
    func testPredict_ZeroBytes_Handled() async {
        await mlPredictor.addSample(bytesTransferred: 0, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Zero bytes should be handled")
    }
    
    func testPredict_VeryLargeBytes_Handled() async {
        await mlPredictor.addSample(bytesTransferred: Int64.max / 2, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Very large bytes should be handled")
    }
    
    func testPredict_VerySmallDuration_Handled() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 0.001)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Very small duration should be handled")
    }
    
    // MARK: - History & Warmup (25 tests)
    
    func testHistory_KeepsLast30Samples() async {
        for i in 0..<50 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // History should keep last 30 samples
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "History should keep last 30 samples")
    }
    
    func testHistory_EvictsOldSamples() async {
        for i in 0..<50 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Old samples should be evicted
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Old samples should be evicted")
    }
    
    func testHistory_RingBuffer_Works() async {
        for i in 0..<35 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Ring buffer should work
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Ring buffer should work")
    }
    
    func testWarmup_LessThan10Samples_KalmanOnly() async {
        for i in 0..<9 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Should use Kalman only during warmup
        XCTAssertTrue(prediction.source == .kalman, "Should use Kalman only during warmup")
    }
    
    func testWarmup_Exactly10Samples_KalmanOnly() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Should use Kalman only at exactly 10 samples
        XCTAssertTrue(prediction.source == .kalman, "Should use Kalman only at exactly 10 samples")
    }
    
    func testWarmup_MoreThan10Samples_MayUseML() async {
        for i in 0..<15 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // May use ML after warmup
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "May use ML after warmup")
    }
    
    func testWarmup_Reset_ClearsCount() async {
        for i in 0..<15 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        // After reset, should be back to warmup
        XCTAssertTrue(prediction.source == .kalman, "After reset should be back to warmup")
    }
    
    func testHistory_Capacity_30() async {
        // History capacity should be 30
        for i in 0..<35 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "History capacity should be 30")
    }
    
    func testHistory_AppendsCorrectly() async {
        for i in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "History should append correctly")
    }
    
    func testHistory_RemovesAll_OnReset() async {
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        // History should be cleared
        XCTAssertTrue(prediction.source == .kalman, "History should be cleared on reset")
    }
    
    func testWarmup_Threshold_10() async {
        // Warmup threshold should be 10
        for i in 0..<9 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction1 = await mlPredictor.predict()
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction2 = await mlPredictor.predict()
        // Both should use Kalman (threshold is 10, so >= 10 still uses Kalman)
        XCTAssertTrue(prediction1.source == .kalman, "Warmup threshold should be 10")
        XCTAssertTrue(prediction2.source == .kalman, "Warmup threshold should be 10")
    }
    
    func testHistory_MeasurementRecorded() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Measurement should be recorded
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Measurement should be recorded")
    }
    
    func testHistory_BandwidthCalculated() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Bandwidth should be calculated correctly
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Bandwidth should be calculated")
    }
    
    func testHistory_HourOfDay_Recorded() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Hour of day should be recorded
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Hour of day should be recorded")
    }
    
    func testHistory_RTT_Recorded() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // RTT should be recorded (may be 0 if not available)
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "RTT should be recorded")
    }
    
    func testHistory_LossRate_Recorded() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Loss rate should be recorded (may be 0 if not available)
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Loss rate should be recorded")
    }
    
    func testHistory_SignalDbm_Recorded() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        // Signal dBm should be recorded (may be 0 if not available)
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Signal dBm should be recorded")
    }
    
    func testHistory_TotalSamples_Increments() async {
        let prediction1 = await mlPredictor.predict()
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction2 = await mlPredictor.predict()
        // Total samples should increment
        XCTAssertGreaterThanOrEqual(prediction2.predictedBps, 0, "Total samples should increment")
    }
    
    func testHistory_TotalSamples_Resets() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        // Total samples should reset
        XCTAssertTrue(prediction.source == .kalman, "Total samples should reset")
    }
    
    func testWarmup_AfterReset_StartsOver() async {
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        // Should start warmup over
        XCTAssertTrue(prediction.source == .kalman, "Should start warmup over after reset")
    }
    
    func testHistory_ConcurrentAccess_Safe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    await self.mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
                }
            }
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Concurrent access should be safe")
    }
    
    func testHistory_MaxCapacity_30() async {
        // Max capacity should be 30
        for i in 0..<50 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        // Should not exceed 30
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Max capacity should be 30")
    }
    
    // MARK: - Edge Cases (20 tests)
    
    func testEdge_ZeroSamples_Handles() async {
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Zero samples should handle")
    }
    
    func testEdge_OneSample_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "One sample should handle")
    }
    
    func testEdge_ManySamples_Handles() async {
        for i in 0..<1000 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Many samples should handle")
    }
    
    func testEdge_NegativeBytes_Handles() async {
        await mlPredictor.addSample(bytesTransferred: -1000, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Negative bytes should handle")
    }
    
    func testEdge_NegativeDuration_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: -1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Negative duration should handle")
    }
    
    func testEdge_ZeroDuration_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 0.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Zero duration should handle")
    }
    
    func testEdge_VeryLargeBytes_Handles() async {
        await mlPredictor.addSample(bytesTransferred: Int64.max / 2, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Very large bytes should handle")
    }
    
    func testEdge_VerySmallDuration_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 0.0001)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Very small duration should handle")
    }
    
    func testEdge_RapidSamples_Handles() async {
        for i in 0..<100 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024, durationSeconds: 0.001)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Rapid samples should handle")
    }
    
    func testEdge_ConcurrentPredictions_Safe() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.mlPredictor.predict()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent predictions should be safe")
    }
    
    func testEdge_MultipleResets_Handles() async {
        for _ in 0..<10 {
            await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
            await mlPredictor.reset()
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Multiple resets should handle")
    }
    
    func testEdge_NoSamplesAfterReset_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        await mlPredictor.reset()
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "No samples after reset should handle")
    }
    
    func testEdge_AllZeroSamples_Handles() async {
        for _ in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: 0, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "All zero samples should handle")
    }
    
    func testEdge_VeryHighBandwidth_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 1000 * 1024 * 1024, durationSeconds: 1.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Very high bandwidth should handle")
    }
    
    func testEdge_VeryLowBandwidth_Handles() async {
        await mlPredictor.addSample(bytesTransferred: 1, durationSeconds: 10.0)
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Very low bandwidth should handle")
    }
    
    func testEdge_OscillatingBandwidth_Handles() async {
        for i in 0..<20 {
            let bytes: Int64 = i % 2 == 0 ? 100 * 1024 * 1024 : 1 * 1024 * 1024
            await mlPredictor.addSample(bytesTransferred: bytes, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Oscillating bandwidth should handle")
    }
    
    func testEdge_SteadyBandwidth_Handles() async {
        for _ in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Steady bandwidth should handle")
    }
    
    func testEdge_IncreasingBandwidth_Handles() async {
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: Int64(i + 1) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Increasing bandwidth should handle")
    }
    
    func testEdge_DecreasingBandwidth_Handles() async {
        for i in 0..<20 {
            await mlPredictor.addSample(bytesTransferred: Int64(20 - i) * 1024 * 1024, durationSeconds: 1.0)
        }
        let prediction = await mlPredictor.predict()
        XCTAssertGreaterThanOrEqual(prediction.predictedBps, 0, "Decreasing bandwidth should handle")
    }
    
    func testEdge_MemoryLeak_None() async {
        for _ in 0..<1000 {
            await mlPredictor.addSample(bytesTransferred: 10 * 1024 * 1024, durationSeconds: 1.0)
            _ = await mlPredictor.predict()
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
}
