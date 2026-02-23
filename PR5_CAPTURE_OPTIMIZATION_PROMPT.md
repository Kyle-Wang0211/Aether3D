# PR5: Capture Optimization & End-to-End Validation - Ultra-Detailed Implementation Prompt

**Version:** 1.0.0
**Scope:** iOS + Linux Cross-Platform | Mobile Stability | Extreme Numerical Precision
**Dependencies:** PR2 (Evidence System), PR3 (Gate System), PR4 (Soft System)
**Research Basis:** State-of-the-art 2025 techniques in mobile ML, depth estimation, frame quality assessment, and video stabilization

---

## PART 0: ARCHITECTURAL CONSTRAINTS (IMMUTABLE)

### 0.1 Three Iron Laws (From Master Plan v5.0)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    INVIOLABLE ARCHITECTURAL CONSTRAINTS                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  LAW 1: All inference, debugging, open-source algorithms → DEVICE-SIDE      │
│         Cloud only handles: Training + Rendering + Storage                   │
│                                                                              │
│  LAW 2: Cross-platform consistency: iOS / Android / Web UX must be IDENTICAL│
│         All device-side code MUST consider cross-platform abstraction layer  │
│                                                                              │
│  LAW 3: Dual-path frame architecture:                                        │
│         • rawFrame → Training/Rendering ledger (IMMUTABLE, tamper-proof)     │
│         • assistFrame → Matching/Pose only (enhanceable, NOT in ledger)      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 0.2 Cross-Platform Compilation Matrix

| Component | iOS (Apple Silicon) | Linux (x86_64/ARM64) | Shared Protocol |
|-----------|---------------------|----------------------|-----------------|
| Exposure Control | AVFoundation + Metal | N/A (server) | `ExposureProtocol` |
| Frame Quality | CoreML + Accelerate | pure Swift + SIMD | `FrameQualityProtocol` |
| Texture Analysis | Vision + CoreML | OpenCV-swift bindings | `TextureProtocol` |
| Depth Fusion | ARKit + CoreML | TensorFlow-Swift | `DepthProtocol` |
| Information Gain | Metal Compute | pure Swift parallel | `InformationGainProtocol` |
| E2E Tests | XCTest + Simulator | swift test + Docker | `TestProtocol` |

### 0.3 Swift Cross-Platform Compilation Guards

```swift
// MANDATORY: All PR5 files must use these guards
#if canImport(AVFoundation)
import AVFoundation  // iOS only
#endif

#if canImport(ARKit)
import ARKit  // iOS only
#endif

#if canImport(CoreML)
import CoreML  // Apple platforms
#endif

#if canImport(Accelerate)
import Accelerate  // Apple platforms
#else
// Linux fallback: pure Swift SIMD or swift-numerics
import Foundation
#endif

#if os(Linux)
import Glibc
#elseif os(macOS) || os(iOS)
import Darwin
#endif
```

---

## PART 1: EXPOSURE CONTROL SYSTEM

### 1.1 Core Requirements

**Objective:** Lock exposure baseline during capture session; provide intelligent low-light assistance without introducing temporal inconsistency.

**Research Basis:**
- [Learning to Control Camera Exposure via Reinforcement Learning](https://arxiv.org/html/2404.01636v1)
- [Android Low Light Boost (2025)](https://android-developers.googleblog.com/2025/12/brighten-your-real-time-camera-feeds.html)
- [Auto-Exposure for Enhanced Mobile Robot Localization](https://www.mdpi.com/1424-8220/22/3/835)

### 1.2 Exposure Controller Specification

```swift
// File: Core/Capture/ExposureController.swift

import Foundation

/// ExposureControlMode - exposure control strategy
public enum ExposureControlMode: String, Codable {
    case locked      // Baseline locked, no adjustment
    case adaptive    // Slow adaptation (for gradual light changes)
    case lowLight    // Low-light assistance active
}

/// ExposureMeteringStrategy - how to compute target exposure
public enum ExposureMeteringStrategy: String, Codable {
    case centerWeighted  // 2x weight on center region
    case evaluative      // Scene-based multi-zone
    case gradient        // Maximize gradient information (research-based)
}

/// ExposureConstants - all magic numbers centralized
public enum ExposureConstants {
    // MARK: - Thresholds (Tuned for 3DGS training quality)

    /// Minimum scene luminance before low-light mode activates (lux)
    /// Reference: Google Night Sight activates at ~0.3 lux
    public static let LOW_LIGHT_THRESHOLD_LUX: Double = 5.0

    /// Critical low-light threshold requiring torch assistance (lux)
    public static let CRITICAL_LOW_LIGHT_LUX: Double = 1.0

    /// Maximum allowed EV change per frame (prevents flicker)
    /// Research: SensorFlow (WACV 2025) uses ±0.1 EV max change rate
    public static let MAX_EV_CHANGE_PER_FRAME: Double = 0.05

    /// Exposure lock hysteresis (ms) - prevent oscillation
    public static let EXPOSURE_LOCK_HYSTERESIS_MS: Int64 = 500

    /// Low-light adaptation window (ms)
    public static let LOW_LIGHT_ADAPTATION_WINDOW_MS: Int64 = 2000

    // MARK: - Histogram Thresholds

    /// Overexposure detection: % pixels > 250 (8-bit)
    public static let OVEREXPOSURE_HISTOGRAM_THRESHOLD: Double = 0.05  // 5%

    /// Underexposure detection: % pixels < 10 (8-bit)
    public static let UNDEREXPOSURE_HISTOGRAM_THRESHOLD: Double = 0.15  // 15%

    /// Large blown region threshold (connected component)
    public static let LARGE_BLOWN_REGION_THRESHOLD: Double = 0.02  // 2% of frame

    // MARK: - Torch Control

    /// Torch brightness levels (0.0 = off, 1.0 = max)
    public static let TORCH_LEVEL_OFF: Float = 0.0
    public static let TORCH_LEVEL_LOW: Float = 0.3   // Gentle fill
    public static let TORCH_LEVEL_MEDIUM: Float = 0.6
    public static let TORCH_LEVEL_HIGH: Float = 0.9  // Emergency

    /// Torch warmup time before capture (ms)
    /// Critical: LED needs time to stabilize color temperature
    public static let TORCH_WARMUP_MS: Int64 = 200

    /// Torch cool-down period between sessions (ms)
    public static let TORCH_COOLDOWN_MS: Int64 = 5000

    // MARK: - Temporal Consistency

    /// EMA alpha for exposure smoothing (lower = more stable)
    public static let EXPOSURE_EMA_ALPHA: Double = 0.1

    /// Minimum frames at stable exposure before accepting
    public static let MIN_STABLE_EXPOSURE_FRAMES: Int = 5

    /// Flicker detection window size (frames)
    public static let FLICKER_DETECTION_WINDOW: Int = 10

    /// Maximum allowed brightness variance for stability
    public static let MAX_BRIGHTNESS_VARIANCE: Double = 0.03  // 3%
}

/// ExposureState - current exposure system state
public struct ExposureState: Codable {
    /// Current mode
    public var mode: ExposureControlMode

    /// Locked baseline ISO (if locked)
    public var baselineISO: Float?

    /// Locked baseline exposure duration (if locked)
    public var baselineExposureDuration: Double?

    /// Current torch level
    public var torchLevel: Float

    /// Frames since last mode change
    public var framesSinceChange: Int

    /// EMA-smoothed luminance
    public var smoothedLuminance: Double

    /// Stability confidence [0, 1]
    public var stabilityConfidence: Double

    public init() {
        self.mode = .locked
        self.baselineISO = nil
        self.baselineExposureDuration = nil
        self.torchLevel = ExposureConstants.TORCH_LEVEL_OFF
        self.framesSinceChange = 0
        self.smoothedLuminance = 0.5
        self.stabilityConfidence = 0.0
    }
}

/// ExposureDecision - output of exposure analysis
public struct ExposureDecision: Codable {
    /// Whether frame should be accepted
    public let shouldAcceptFrame: Bool

    /// Reason for rejection (if any)
    public let rejectionReason: ExposureRejectionReason?

    /// Suggested torch adjustment
    public let suggestedTorchLevel: Float?

    /// Current exposure quality score [0, 1]
    public let exposureQuality: Double

    /// Confidence in decision [0, 1]
    public let confidence: Double
}

/// ExposureRejectionReason - why frame was rejected
public enum ExposureRejectionReason: String, Codable {
    case overexposed           // Too many blown highlights
    case underexposed          // Too many crushed blacks
    case largeBlownRegion      // Connected overexposed region
    case exposureChanging      // Exposure still adapting
    case torchWarmingUp        // Torch not yet stable
    case flickerDetected       // Temporal instability
}

/// ExposureControllerProtocol - cross-platform interface
public protocol ExposureControllerProtocol {
    /// Process frame and return exposure decision
    func processFrame(
        luminanceHistogram: [Int],  // 256-bin histogram
        centerWeightedLuminance: Double,
        timestamp: Int64
    ) -> ExposureDecision

    /// Lock exposure at current values
    func lockExposure()

    /// Unlock and allow adaptation
    func unlockExposure()

    /// Set torch level (iOS only, no-op on Linux)
    func setTorchLevel(_ level: Float)

    /// Get current state (for serialization)
    var state: ExposureState { get }
}

/// ExposureController - iOS implementation
#if canImport(AVFoundation)
public final class ExposureController: ExposureControllerProtocol {

    // MARK: - Private State

    private var _state: ExposureState
    private let luminanceBuffer: RingBuffer<Double>
    private let clockProvider: ClockProvider
    private var lastModeChangeTimestamp: Int64

    // MARK: - Thread Safety

    private let stateLock = NSLock()

    public var state: ExposureState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    // MARK: - Initialization

    public init(clockProvider: ClockProvider = SystemClockProvider()) {
        self._state = ExposureState()
        self.luminanceBuffer = RingBuffer<Double>(capacity: ExposureConstants.FLICKER_DETECTION_WINDOW)
        self.clockProvider = clockProvider
        self.lastModeChangeTimestamp = clockProvider.currentTimeMillis()
    }

    // MARK: - ExposureControllerProtocol

    public func processFrame(
        luminanceHistogram: [Int],
        centerWeightedLuminance: Double,
        timestamp: Int64
    ) -> ExposureDecision {
        stateLock.lock()
        defer { stateLock.unlock() }

        // Step 1: Compute histogram metrics
        let histogramMetrics = computeHistogramMetrics(luminanceHistogram)

        // Step 2: Update EMA luminance
        let previousLuminance = _state.smoothedLuminance
        _state.smoothedLuminance = ExposureConstants.EXPOSURE_EMA_ALPHA * centerWeightedLuminance +
                                   (1.0 - ExposureConstants.EXPOSURE_EMA_ALPHA) * previousLuminance

        // Step 3: Detect flicker
        luminanceBuffer.push(centerWeightedLuminance)
        let flickerDetected = detectFlicker()

        // Step 4: Check rejection conditions
        if let reason = checkRejectionConditions(
            histogramMetrics: histogramMetrics,
            flickerDetected: flickerDetected,
            timestamp: timestamp
        ) {
            return ExposureDecision(
                shouldAcceptFrame: false,
                rejectionReason: reason,
                suggestedTorchLevel: computeSuggestedTorchLevel(histogramMetrics),
                exposureQuality: histogramMetrics.quality,
                confidence: 0.9
            )
        }

        // Step 5: Update frame counter and stability
        _state.framesSinceChange += 1
        _state.stabilityConfidence = computeStabilityConfidence()

        return ExposureDecision(
            shouldAcceptFrame: true,
            rejectionReason: nil,
            suggestedTorchLevel: computeSuggestedTorchLevel(histogramMetrics),
            exposureQuality: histogramMetrics.quality,
            confidence: _state.stabilityConfidence
        )
    }

    public func lockExposure() {
        stateLock.lock()
        defer { stateLock.unlock() }

        _state.mode = .locked
        _state.framesSinceChange = 0
        lastModeChangeTimestamp = clockProvider.currentTimeMillis()
    }

    public func unlockExposure() {
        stateLock.lock()
        defer { stateLock.unlock() }

        _state.mode = .adaptive
        _state.framesSinceChange = 0
        lastModeChangeTimestamp = clockProvider.currentTimeMillis()
    }

    public func setTorchLevel(_ level: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let clampedLevel = min(1.0, max(0.0, level))
        _state.torchLevel = clampedLevel

        // Apply to device (iOS-specific)
        applyTorchLevelToDevice(clampedLevel)
    }

    // MARK: - Private Helpers

    private struct HistogramMetrics {
        let overexposurePct: Double
        let underexposurePct: Double
        let hasLargeBlownRegion: Bool
        let meanLuminance: Double
        let quality: Double
    }

    private func computeHistogramMetrics(_ histogram: [Int]) -> HistogramMetrics {
        guard histogram.count == 256 else {
            return HistogramMetrics(
                overexposurePct: 0.0,
                underexposurePct: 0.0,
                hasLargeBlownRegion: false,
                meanLuminance: 0.5,
                quality: 0.0
            )
        }

        let total = Double(histogram.reduce(0, +))
        guard total > 0 else {
            return HistogramMetrics(
                overexposurePct: 0.0,
                underexposurePct: 0.0,
                hasLargeBlownRegion: false,
                meanLuminance: 0.5,
                quality: 0.0
            )
        }

        // Overexposure: pixels > 250
        let overexposedCount = histogram[250...255].reduce(0, +)
        let overexposurePct = Double(overexposedCount) / total

        // Underexposure: pixels < 10
        let underexposedCount = histogram[0..<10].reduce(0, +)
        let underexposurePct = Double(underexposedCount) / total

        // Mean luminance
        var sum: Double = 0
        for i in 0..<256 {
            sum += Double(i) * Double(histogram[i])
        }
        let meanLuminance = sum / (total * 255.0)

        // Quality score (higher = better exposure)
        let overPenalty = max(0, overexposurePct - ExposureConstants.OVEREXPOSURE_HISTOGRAM_THRESHOLD) * 5.0
        let underPenalty = max(0, underexposurePct - ExposureConstants.UNDEREXPOSURE_HISTOGRAM_THRESHOLD) * 3.0
        let quality = max(0.0, min(1.0, 1.0 - overPenalty - underPenalty))

        // TODO: Large blown region detection requires connected component analysis
        let hasLargeBlownRegion = overexposurePct > ExposureConstants.LARGE_BLOWN_REGION_THRESHOLD

        return HistogramMetrics(
            overexposurePct: overexposurePct,
            underexposurePct: underexposurePct,
            hasLargeBlownRegion: hasLargeBlownRegion,
            meanLuminance: meanLuminance,
            quality: quality
        )
    }

    private func detectFlicker() -> Bool {
        guard luminanceBuffer.count >= 3 else { return false }

        let values = luminanceBuffer.toArray()
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)

        return variance > ExposureConstants.MAX_BRIGHTNESS_VARIANCE
    }

    private func checkRejectionConditions(
        histogramMetrics: HistogramMetrics,
        flickerDetected: Bool,
        timestamp: Int64
    ) -> ExposureRejectionReason? {
        // Check exposure quality
        if histogramMetrics.overexposurePct > ExposureConstants.OVEREXPOSURE_HISTOGRAM_THRESHOLD * 2 {
            return .overexposed
        }

        if histogramMetrics.underexposurePct > ExposureConstants.UNDEREXPOSURE_HISTOGRAM_THRESHOLD * 2 {
            return .underexposed
        }

        if histogramMetrics.hasLargeBlownRegion {
            return .largeBlownRegion
        }

        // Check flicker
        if flickerDetected {
            return .flickerDetected
        }

        // Check mode transition stability
        let timeSinceModeChange = timestamp - lastModeChangeTimestamp
        if _state.mode == .adaptive && timeSinceModeChange < ExposureConstants.EXPOSURE_LOCK_HYSTERESIS_MS {
            return .exposureChanging
        }

        // Check torch warmup
        if _state.torchLevel > 0 && _state.framesSinceChange < 3 {
            return .torchWarmingUp
        }

        return nil
    }

    private func computeSuggestedTorchLevel(_ metrics: HistogramMetrics) -> Float? {
        // Only suggest torch in low-light conditions
        guard metrics.meanLuminance < 0.2 else { return nil }

        if metrics.meanLuminance < 0.05 {
            return ExposureConstants.TORCH_LEVEL_HIGH
        } else if metrics.meanLuminance < 0.1 {
            return ExposureConstants.TORCH_LEVEL_MEDIUM
        } else if metrics.meanLuminance < 0.2 {
            return ExposureConstants.TORCH_LEVEL_LOW
        }

        return nil
    }

    private func computeStabilityConfidence() -> Double {
        let framesFactor = min(1.0, Double(_state.framesSinceChange) / Double(ExposureConstants.MIN_STABLE_EXPOSURE_FRAMES))
        let flickerFactor = detectFlicker() ? 0.5 : 1.0
        return framesFactor * flickerFactor
    }

    private func applyTorchLevelToDevice(_ level: Float) {
        // iOS-specific torch control via AVCaptureDevice
        // Implementation deferred to camera session integration
    }
}
#endif

/// ExposureControllerStub - Linux/testing implementation
public final class ExposureControllerStub: ExposureControllerProtocol {
    private var _state: ExposureState

    public var state: ExposureState { _state }

    public init() {
        self._state = ExposureState()
    }

    public func processFrame(
        luminanceHistogram: [Int],
        centerWeightedLuminance: Double,
        timestamp: Int64
    ) -> ExposureDecision {
        // Stub: always accept
        return ExposureDecision(
            shouldAcceptFrame: true,
            rejectionReason: nil,
            suggestedTorchLevel: nil,
            exposureQuality: 0.8,
            confidence: 0.5
        )
    }

    public func lockExposure() {
        _state.mode = .locked
    }

    public func unlockExposure() {
        _state.mode = .adaptive
    }

    public func setTorchLevel(_ level: Float) {
        _state.torchLevel = level
        // No-op on Linux
    }
}
```

### 1.3 Exposure Controller Tests

```swift
// File: Tests/PR5CaptureTests/ExposureControllerTests.swift

import XCTest
@testable import Aether3DCore

final class ExposureControllerTests: XCTestCase {

    // MARK: - Test Constants Centralization

    func testAllConstantsAreCentralized() {
        // Verify no magic numbers in implementation
        XCTAssertEqual(ExposureConstants.LOW_LIGHT_THRESHOLD_LUX, 5.0)
        XCTAssertEqual(ExposureConstants.MAX_EV_CHANGE_PER_FRAME, 0.05)
        XCTAssertEqual(ExposureConstants.TORCH_WARMUP_MS, 200)
    }

    // MARK: - Test Histogram Analysis

    func testOverexposureDetection() {
        let controller = createController()

        // Create histogram with 10% overexposed pixels
        var histogram = [Int](repeating: 100, count: 256)
        histogram[255] = 1000  // 10% at max

        let decision = controller.processFrame(
            luminanceHistogram: histogram,
            centerWeightedLuminance: 0.8,
            timestamp: 1000
        )

        XCTAssertFalse(decision.shouldAcceptFrame)
        XCTAssertEqual(decision.rejectionReason, .overexposed)
    }

    func testUnderexposureDetection() {
        let controller = createController()

        // Create histogram with 35% underexposed pixels
        var histogram = [Int](repeating: 100, count: 256)
        histogram[0] = 3500

        let decision = controller.processFrame(
            luminanceHistogram: histogram,
            centerWeightedLuminance: 0.1,
            timestamp: 1000
        )

        XCTAssertFalse(decision.shouldAcceptFrame)
        XCTAssertEqual(decision.rejectionReason, .underexposed)
    }

    // MARK: - Test Stability

    func testStabilityAfterModeChange() {
        let controller = createController()

        controller.unlockExposure()  // Trigger mode change

        let histogram = createNormalHistogram()

        // First frame after mode change should be rejected
        let decision1 = controller.processFrame(
            luminanceHistogram: histogram,
            centerWeightedLuminance: 0.5,
            timestamp: 100  // Within hysteresis
        )

        XCTAssertFalse(decision1.shouldAcceptFrame)
        XCTAssertEqual(decision1.rejectionReason, .exposureChanging)

        // Frame after hysteresis should be accepted
        let decision2 = controller.processFrame(
            luminanceHistogram: histogram,
            centerWeightedLuminance: 0.5,
            timestamp: 1000  // After hysteresis
        )

        XCTAssertTrue(decision2.shouldAcceptFrame)
    }

    // MARK: - Test Flicker Detection

    func testFlickerDetection() {
        let controller = createController()
        let histogram = createNormalHistogram()

        // Simulate alternating luminance (flicker)
        for i in 0..<10 {
            let luminance = (i % 2 == 0) ? 0.3 : 0.7  // High variance
            let decision = controller.processFrame(
                luminanceHistogram: histogram,
                centerWeightedLuminance: luminance,
                timestamp: Int64(i * 33)
            )

            if i >= 3 {  // After buffer fills
                XCTAssertFalse(decision.shouldAcceptFrame)
                XCTAssertEqual(decision.rejectionReason, .flickerDetected)
            }
        }
    }

    // MARK: - Test Torch Suggestions

    func testTorchSuggestionInLowLight() {
        let controller = createController()

        // Create dark histogram
        var histogram = [Int](repeating: 0, count: 256)
        histogram[5] = 10000  // Very dark

        let decision = controller.processFrame(
            luminanceHistogram: histogram,
            centerWeightedLuminance: 0.02,
            timestamp: 1000
        )

        XCTAssertNotNil(decision.suggestedTorchLevel)
        XCTAssertEqual(decision.suggestedTorchLevel, ExposureConstants.TORCH_LEVEL_HIGH)
    }

    // MARK: - Test Cross-Platform Stub

    func testStubAlwaysAccepts() {
        let stub = ExposureControllerStub()

        let decision = stub.processFrame(
            luminanceHistogram: [],
            centerWeightedLuminance: 0.0,
            timestamp: 0
        )

        XCTAssertTrue(decision.shouldAcceptFrame)
    }

    // MARK: - Helpers

    private func createController() -> ExposureControllerProtocol {
        #if canImport(AVFoundation)
        return ExposureController()
        #else
        return ExposureControllerStub()
        #endif
    }

    private func createNormalHistogram() -> [Int] {
        // Bell curve centered at 128
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = Double(i - 128) / 40.0
            histogram[i] = Int(1000 * exp(-x * x / 2))
        }
        return histogram
    }
}
```

---

## PART 2: FRAME QUALITY DECISION SYSTEM

### 2.1 Core Requirements

**Objective:** Real-time frame quality assessment with discard vs. keep decision. Must be lightweight enough for 30fps operation while providing accurate quality signals.

**Research Basis:**
- [LAR-IQA: Lightweight No-Reference IQA (2024)](https://arxiv.org/abs/2408.17057)
- [MobileIQA via Knowledge Distillation (ECCV 2024)](https://link.springer.com/chapter/10.1007/978-3-031-91856-8_1)
- [Deep Learning NR-IQA Survey (2025)](https://www.scitepress.org/Papers/2025/135977/135977.pdf)

### 2.2 Frame Quality Detector Specification

```swift
// File: Core/Capture/FrameQualityDetector.swift

import Foundation

/// FrameQualityConstants - all thresholds centralized
public enum FrameQualityConstants {
    // MARK: - Sharpness Thresholds (Laplacian Variance)

    /// Minimum acceptable Laplacian variance for sharp frame
    /// Research: MobileIQA uses ~100-200 for acceptable sharpness
    public static let LAPLACIAN_SHARP_THRESHOLD: Double = 150.0

    /// Below this, frame is severely blurred
    public static let LAPLACIAN_BLUR_THRESHOLD: Double = 50.0

    /// Tenengrad sharpness threshold (gradient-based)
    public static let TENENGRAD_SHARP_THRESHOLD: Double = 25.0

    // MARK: - Motion Thresholds

    /// Maximum optical flow magnitude for "static" frame (pixels)
    /// Research: SensorFlow (WACV 2025) uses 2-3 pixels for stable
    public static let MAX_OPTICAL_FLOW_MAGNITUDE: Double = 3.0

    /// Maximum angular velocity for acceptable frame (rad/s)
    /// ARKit gyroscope threshold
    public static let MAX_ANGULAR_VELOCITY: Double = 0.5

    /// Maximum linear acceleration deviation from gravity (m/s²)
    public static let MAX_LINEAR_ACCELERATION: Double = 2.0

    // MARK: - Frame Similarity

    /// Minimum SSIM between consecutive frames for redundancy check
    public static let SSIM_REDUNDANCY_THRESHOLD: Double = 0.98

    /// Minimum information gain for frame acceptance
    public static let MIN_INFORMATION_GAIN: Double = 0.05

    // MARK: - Quality Weights (for composite score)

    public static let WEIGHT_SHARPNESS: Double = 0.35
    public static let WEIGHT_EXPOSURE: Double = 0.25
    public static let WEIGHT_MOTION: Double = 0.20
    public static let WEIGHT_INFORMATION: Double = 0.20

    // MARK: - Performance Budget

    /// Maximum latency for quality check (ms)
    public static let MAX_QUALITY_CHECK_LATENCY_MS: Double = 10.0

    /// Degraded mode latency budget (ms)
    public static let DEGRADED_QUALITY_CHECK_LATENCY_MS: Double = 5.0
}

/// FrameQualityLevel - multi-tier quality assessment
public enum FrameQualityLevel: String, Codable, Comparable {
    case excellent = "excellent"  // All metrics optimal
    case good = "good"            // Acceptable for training
    case marginal = "marginal"    // Keep only if coverage needed
    case poor = "poor"            // Discard unless critical
    case rejected = "rejected"    // Must discard

    public static func < (lhs: FrameQualityLevel, rhs: FrameQualityLevel) -> Bool {
        let order: [FrameQualityLevel] = [.rejected, .poor, .marginal, .good, .excellent]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// FrameQualityMetrics - detailed quality breakdown
public struct FrameQualityMetrics: Codable {
    /// Sharpness score [0, 1]
    public let sharpness: Double

    /// Exposure quality [0, 1]
    public let exposure: Double

    /// Motion stability [0, 1] (1 = no motion)
    public let motionStability: Double

    /// Information gain vs previous frame [0, 1]
    public let informationGain: Double

    /// Texture richness [0, 1]
    public let textureRichness: Double

    /// Depth quality (if available) [0, 1]
    public let depthQuality: Double?

    /// Composite quality score [0, 1]
    public var composite: Double {
        let base = FrameQualityConstants.WEIGHT_SHARPNESS * sharpness +
                   FrameQualityConstants.WEIGHT_EXPOSURE * exposure +
                   FrameQualityConstants.WEIGHT_MOTION * motionStability +
                   FrameQualityConstants.WEIGHT_INFORMATION * informationGain
        return min(1.0, max(0.0, base))
    }

    /// Confidence in metrics [0, 1]
    public let confidence: Double

    public init(
        sharpness: Double,
        exposure: Double,
        motionStability: Double,
        informationGain: Double,
        textureRichness: Double,
        depthQuality: Double?,
        confidence: Double
    ) {
        // H1: Defensive NaN/Inf checks
        self.sharpness = sharpness.isFinite ? min(1.0, max(0.0, sharpness)) : 0.0
        self.exposure = exposure.isFinite ? min(1.0, max(0.0, exposure)) : 0.0
        self.motionStability = motionStability.isFinite ? min(1.0, max(0.0, motionStability)) : 0.0
        self.informationGain = informationGain.isFinite ? min(1.0, max(0.0, informationGain)) : 0.0
        self.textureRichness = textureRichness.isFinite ? min(1.0, max(0.0, textureRichness)) : 0.0
        self.depthQuality = depthQuality.map { $0.isFinite ? min(1.0, max(0.0, $0)) : nil } ?? nil
        self.confidence = confidence.isFinite ? min(1.0, max(0.0, confidence)) : 0.0
    }
}

/// FrameQualityDecision - final decision output
public struct FrameQualityDecision: Codable {
    /// Overall quality level
    public let level: FrameQualityLevel

    /// Detailed metrics
    public let metrics: FrameQualityMetrics

    /// Should this frame be kept?
    public let shouldKeep: Bool

    /// Primary reason for decision
    public let primaryReason: FrameDecisionReason

    /// Processing latency (ms)
    public let processingLatencyMs: Double
}

/// FrameDecisionReason - why frame was kept/rejected
public enum FrameDecisionReason: String, Codable {
    case excellentQuality       // All metrics optimal
    case goodQuality            // Acceptable quality
    case neededForCoverage      // Low quality but needed
    case tooBlurry              // Sharpness failed
    case tooMuchMotion          // Motion blur/shake
    case poorExposure           // Over/under exposed
    case redundant              // Too similar to previous
    case noInformationGain      // Doesn't add value
    case depthFailed            // Depth quality too low
}

/// FrameQualityDetectorProtocol - cross-platform interface
public protocol FrameQualityDetectorProtocol {
    /// Analyze frame quality
    func analyzeFrame(
        laplacianVariance: Double,
        exposureQuality: Double,
        angularVelocity: SIMD3<Double>,
        linearAcceleration: SIMD3<Double>,
        opticalFlowMagnitude: Double?,
        previousFrameSSIM: Double?,
        textureFeatureCount: Int,
        depthConfidence: Double?,
        coverageNeedsFilling: Bool
    ) -> FrameQualityDecision

    /// Reset state (new capture session)
    func reset()
}

/// FrameQualityDetector - main implementation
public final class FrameQualityDetector: FrameQualityDetectorProtocol {

    // MARK: - Private State

    private var frameCount: Int = 0
    private var lastAnalysisTimestamp: Int64 = 0
    private let clockProvider: ClockProvider

    // MARK: - Thread Safety

    private let stateLock = NSLock()

    // MARK: - Initialization

    public init(clockProvider: ClockProvider = SystemClockProvider()) {
        self.clockProvider = clockProvider
    }

    // MARK: - FrameQualityDetectorProtocol

    public func analyzeFrame(
        laplacianVariance: Double,
        exposureQuality: Double,
        angularVelocity: SIMD3<Double>,
        linearAcceleration: SIMD3<Double>,
        opticalFlowMagnitude: Double?,
        previousFrameSSIM: Double?,
        textureFeatureCount: Int,
        depthConfidence: Double?,
        coverageNeedsFilling: Bool
    ) -> FrameQualityDecision {
        let startTime = clockProvider.currentTimeMillis()

        stateLock.lock()
        defer { stateLock.unlock() }

        frameCount += 1

        // Step 1: Compute individual metrics
        let sharpness = computeSharpnessScore(laplacianVariance)
        let motion = computeMotionStabilityScore(angularVelocity, linearAcceleration, opticalFlowMagnitude)
        let information = computeInformationGainScore(previousFrameSSIM, textureFeatureCount)
        let texture = computeTextureRichnessScore(textureFeatureCount)

        // Step 2: Build metrics
        let metrics = FrameQualityMetrics(
            sharpness: sharpness,
            exposure: exposureQuality,
            motionStability: motion,
            informationGain: information,
            textureRichness: texture,
            depthQuality: depthConfidence,
            confidence: computeOverallConfidence(exposureQuality, depthConfidence)
        )

        // Step 3: Determine quality level
        let level = determineQualityLevel(metrics)

        // Step 4: Make keep/reject decision
        let (shouldKeep, reason) = makeDecision(level, metrics, coverageNeedsFilling)

        // Step 5: Compute latency
        let endTime = clockProvider.currentTimeMillis()
        let latency = Double(endTime - startTime)

        return FrameQualityDecision(
            level: level,
            metrics: metrics,
            shouldKeep: shouldKeep,
            primaryReason: reason,
            processingLatencyMs: latency
        )
    }

    public func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        frameCount = 0
        lastAnalysisTimestamp = 0
    }

    // MARK: - Private Score Computation

    private func computeSharpnessScore(_ laplacianVariance: Double) -> Double {
        // Sigmoid mapping: smooth transition from blur to sharp
        let threshold = FrameQualityConstants.LAPLACIAN_SHARP_THRESHOLD
        let x = (laplacianVariance - threshold) / (threshold * 0.3)
        return 1.0 / (1.0 + exp(-x))
    }

    private func computeMotionStabilityScore(
        _ angularVelocity: SIMD3<Double>,
        _ linearAcceleration: SIMD3<Double>,
        _ opticalFlowMagnitude: Double?
    ) -> Double {
        // Angular velocity component
        let angularMagnitude = sqrt(
            angularVelocity.x * angularVelocity.x +
            angularVelocity.y * angularVelocity.y +
            angularVelocity.z * angularVelocity.z
        )
        let angularScore = max(0, 1.0 - angularMagnitude / FrameQualityConstants.MAX_ANGULAR_VELOCITY)

        // Linear acceleration component (deviation from gravity)
        let gravityMagnitude = 9.81
        let accelMagnitude = sqrt(
            linearAcceleration.x * linearAcceleration.x +
            linearAcceleration.y * linearAcceleration.y +
            linearAcceleration.z * linearAcceleration.z
        )
        let accelDeviation = abs(accelMagnitude - gravityMagnitude)
        let accelScore = max(0, 1.0 - accelDeviation / FrameQualityConstants.MAX_LINEAR_ACCELERATION)

        // Optical flow component (if available)
        var flowScore = 1.0
        if let flow = opticalFlowMagnitude {
            flowScore = max(0, 1.0 - flow / FrameQualityConstants.MAX_OPTICAL_FLOW_MAGNITUDE)
        }

        // Combined score (geometric mean for multiplicative effect)
        return pow(angularScore * accelScore * flowScore, 1.0/3.0)
    }

    private func computeInformationGainScore(_ ssim: Double?, _ featureCount: Int) -> Double {
        // High SSIM = low information gain (redundant frame)
        var ssimScore = 1.0
        if let ssim = ssim {
            if ssim > FrameQualityConstants.SSIM_REDUNDANCY_THRESHOLD {
                ssimScore = 0.1  // Very redundant
            } else {
                ssimScore = 1.0 - ssim  // Higher difference = more information
            }
        }

        // Feature count component
        let featureScore = min(1.0, Double(featureCount) / 500.0)

        return (ssimScore + featureScore) / 2.0
    }

    private func computeTextureRichnessScore(_ featureCount: Int) -> Double {
        // ORB feature count mapping
        // 0-100: poor, 100-300: acceptable, 300+: rich
        if featureCount < 50 { return 0.2 }
        if featureCount < 100 { return 0.4 }
        if featureCount < 200 { return 0.6 }
        if featureCount < 300 { return 0.8 }
        return 1.0
    }

    private func computeOverallConfidence(_ exposureQuality: Double, _ depthConfidence: Double?) -> Double {
        var confidence = exposureQuality
        if let depth = depthConfidence {
            confidence = (confidence + depth) / 2.0
        }
        return confidence
    }

    // MARK: - Private Decision Logic

    private func determineQualityLevel(_ metrics: FrameQualityMetrics) -> FrameQualityLevel {
        let composite = metrics.composite

        if composite >= 0.85 { return .excellent }
        if composite >= 0.70 { return .good }
        if composite >= 0.50 { return .marginal }
        if composite >= 0.30 { return .poor }
        return .rejected
    }

    private func makeDecision(
        _ level: FrameQualityLevel,
        _ metrics: FrameQualityMetrics,
        _ coverageNeedsFilling: Bool
    ) -> (Bool, FrameDecisionReason) {
        // Excellent/Good: always keep
        if level >= .good {
            return (true, level == .excellent ? .excellentQuality : .goodQuality)
        }

        // Check specific failure modes
        if metrics.sharpness < 0.3 {
            return coverageNeedsFilling ? (true, .neededForCoverage) : (false, .tooBlurry)
        }

        if metrics.motionStability < 0.3 {
            return coverageNeedsFilling ? (true, .neededForCoverage) : (false, .tooMuchMotion)
        }

        if metrics.exposure < 0.3 {
            return coverageNeedsFilling ? (true, .neededForCoverage) : (false, .poorExposure)
        }

        if metrics.informationGain < FrameQualityConstants.MIN_INFORMATION_GAIN {
            return (false, .redundant)
        }

        if let depth = metrics.depthQuality, depth < 0.3 {
            return coverageNeedsFilling ? (true, .neededForCoverage) : (false, .depthFailed)
        }

        // Marginal: keep if coverage needs filling
        if level == .marginal {
            return coverageNeedsFilling ? (true, .neededForCoverage) : (false, .noInformationGain)
        }

        // Poor/Rejected: keep only if critical coverage need
        return coverageNeedsFilling ? (true, .neededForCoverage) : (false, .noInformationGain)
    }
}
```

---

## PART 3: TEXTURE STRENGTH ANALYZER

### 3.1 Core Requirements

**Objective:** Determine if scene has sufficient texture for reliable feature matching. If texture is weak, trigger assistFrame enhancement pathway.

**Research Basis:**
- [Post-integration Point-Line SLAM for Low-Texture (Nature 2025)](https://www.nature.com/articles/s41598-025-97250-6)
- [SL-SLAM: Deep Feature Extraction for Weak Textures](https://arxiv.org/html/2405.03413v2)
- [PLFG-SLAM: Adaptive Threshold Feature Extraction (2025)](https://www.sciencedirect.com/science/article/abs/pii/S0263224125017944)

### 3.2 Texture Strength Analyzer Specification

```swift
// File: Core/Capture/TextureStrengthAnalyzer.swift

import Foundation

/// TextureStrengthConstants - all thresholds centralized
public enum TextureStrengthConstants {
    // MARK: - Feature Count Thresholds

    /// Minimum ORB features for "strong texture"
    /// Research: PLFG-SLAM considers 200+ features as strong
    public static let STRONG_TEXTURE_FEATURE_COUNT: Int = 200

    /// Below this, texture is "weak" and needs assistFrame
    public static let WEAK_TEXTURE_FEATURE_COUNT: Int = 80

    /// Below this, texture is "critical" - likely to fail
    public static let CRITICAL_TEXTURE_FEATURE_COUNT: Int = 30

    // MARK: - Gradient Thresholds

    /// Minimum mean gradient magnitude for texture detection
    public static let MIN_GRADIENT_MAGNITUDE: Double = 15.0

    /// Gradient standard deviation threshold
    public static let MIN_GRADIENT_STD: Double = 20.0

    // MARK: - Spatial Distribution

    /// Minimum spatial coverage (% of grid cells with features)
    public static let MIN_SPATIAL_COVERAGE: Double = 0.30  // 30%

    /// Grid size for spatial analysis
    public static let SPATIAL_GRID_SIZE: Int = 8  // 8x8 grid

    // MARK: - AssistFrame Enhancement Parameters

    /// Unsharp mask amount for weak texture
    public static let WEAK_TEXTURE_UNSHARP_AMOUNT: Float = 0.3

    /// Unsharp mask radius
    public static let WEAK_TEXTURE_UNSHARP_RADIUS: Float = 1.5

    /// Bilateral filter sigma for weak texture
    public static let WEAK_TEXTURE_BILATERAL_SIGMA: Float = 2.0

    /// CLAHE clip limit for low contrast
    public static let WEAK_TEXTURE_CLAHE_CLIP: Float = 2.0

    // MARK: - Adaptive Threshold Parameters

    /// ORB FAST threshold for normal texture
    public static let ORB_FAST_THRESHOLD_NORMAL: Int = 20

    /// ORB FAST threshold for weak texture (lower = more sensitive)
    public static let ORB_FAST_THRESHOLD_WEAK: Int = 10

    /// ORB FAST threshold for critical texture
    public static let ORB_FAST_THRESHOLD_CRITICAL: Int = 5
}

/// TextureStrengthLevel - classification output
public enum TextureStrengthLevel: String, Codable {
    case strong = "strong"      // Normal operation
    case moderate = "moderate"  // Some enhancement may help
    case weak = "weak"          // AssistFrame required
    case critical = "critical"  // May fail regardless
}

/// TextureAnalysisResult - detailed analysis output
public struct TextureAnalysisResult: Codable {
    /// Overall texture strength level
    public let level: TextureStrengthLevel

    /// Raw ORB feature count
    public let featureCount: Int

    /// Spatial coverage ratio [0, 1]
    public let spatialCoverage: Double

    /// Mean gradient magnitude
    public let meanGradient: Double

    /// Gradient standard deviation
    public let gradientStd: Double

    /// Whether assistFrame should be generated
    public let needsAssistFrame: Bool

    /// Suggested ORB threshold for this texture level
    public let suggestedORBThreshold: Int

    /// Enhancement parameters (if assistFrame needed)
    public let enhancementParams: TextureEnhancementParams?

    /// Confidence in analysis [0, 1]
    public let confidence: Double
}

/// TextureEnhancementParams - parameters for assistFrame generation
public struct TextureEnhancementParams: Codable {
    /// Unsharp mask amount
    public let unsharpAmount: Float

    /// Unsharp mask radius
    public let unsharpRadius: Float

    /// Bilateral filter sigma
    public let bilateralSigma: Float

    /// CLAHE clip limit
    public let claheClip: Float

    /// Whether to apply histogram equalization
    public let applyHistogramEqualization: Bool
}

/// TextureStrengthAnalyzerProtocol - cross-platform interface
public protocol TextureStrengthAnalyzerProtocol {
    /// Analyze texture strength
    func analyzeTexture(
        featureCount: Int,
        featureLocations: [(x: Int, y: Int)],
        imageWidth: Int,
        imageHeight: Int,
        gradientMagnitudes: [Float]?  // Optional gradient map
    ) -> TextureAnalysisResult

    /// Get adaptive ORB threshold based on recent texture history
    func getAdaptiveORBThreshold() -> Int

    /// Reset state
    func reset()
}

/// TextureStrengthAnalyzer - main implementation
public final class TextureStrengthAnalyzer: TextureStrengthAnalyzerProtocol {

    // MARK: - Private State

    private var recentTextureLevels: RingBuffer<TextureStrengthLevel>
    private var adaptiveThreshold: Int
    private let stateLock = NSLock()

    // MARK: - Initialization

    public init() {
        self.recentTextureLevels = RingBuffer<TextureStrengthLevel>(capacity: 10)
        self.adaptiveThreshold = TextureStrengthConstants.ORB_FAST_THRESHOLD_NORMAL
    }

    // MARK: - TextureStrengthAnalyzerProtocol

    public func analyzeTexture(
        featureCount: Int,
        featureLocations: [(x: Int, y: Int)],
        imageWidth: Int,
        imageHeight: Int,
        gradientMagnitudes: [Float]?
    ) -> TextureAnalysisResult {
        stateLock.lock()
        defer { stateLock.unlock() }

        // Step 1: Compute spatial coverage
        let spatialCoverage = computeSpatialCoverage(
            featureLocations: featureLocations,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        // Step 2: Compute gradient statistics (if available)
        let (meanGradient, gradientStd) = computeGradientStats(gradientMagnitudes)

        // Step 3: Determine texture level
        let level = classifyTextureLevel(
            featureCount: featureCount,
            spatialCoverage: spatialCoverage,
            meanGradient: meanGradient
        )

        // Step 4: Update history
        recentTextureLevels.push(level)
        updateAdaptiveThreshold()

        // Step 5: Build result
        let needsAssistFrame = level == .weak || level == .critical
        let enhancementParams = needsAssistFrame ? computeEnhancementParams(level, meanGradient) : nil
        let confidence = computeConfidence(featureCount, spatialCoverage)

        return TextureAnalysisResult(
            level: level,
            featureCount: featureCount,
            spatialCoverage: spatialCoverage,
            meanGradient: meanGradient,
            gradientStd: gradientStd,
            needsAssistFrame: needsAssistFrame,
            suggestedORBThreshold: adaptiveThreshold,
            enhancementParams: enhancementParams,
            confidence: confidence
        )
    }

    public func getAdaptiveORBThreshold() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return adaptiveThreshold
    }

    public func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        recentTextureLevels = RingBuffer<TextureStrengthLevel>(capacity: 10)
        adaptiveThreshold = TextureStrengthConstants.ORB_FAST_THRESHOLD_NORMAL
    }

    // MARK: - Private Helpers

    private func computeSpatialCoverage(
        featureLocations: [(x: Int, y: Int)],
        imageWidth: Int,
        imageHeight: Int
    ) -> Double {
        let gridSize = TextureStrengthConstants.SPATIAL_GRID_SIZE
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: gridSize), count: gridSize)

        let cellWidth = imageWidth / gridSize
        let cellHeight = imageHeight / gridSize

        for (x, y) in featureLocations {
            let gridX = min(gridSize - 1, x / cellWidth)
            let gridY = min(gridSize - 1, y / cellHeight)
            grid[gridY][gridX] = true
        }

        let filledCells = grid.flatMap { $0 }.filter { $0 }.count
        return Double(filledCells) / Double(gridSize * gridSize)
    }

    private func computeGradientStats(_ gradients: [Float]?) -> (mean: Double, std: Double) {
        guard let gradients = gradients, !gradients.isEmpty else {
            return (0.0, 0.0)
        }

        let sum = gradients.reduce(0.0) { $0 + Double($1) }
        let mean = sum / Double(gradients.count)

        let variance = gradients.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(gradients.count)
        let std = sqrt(variance)

        return (mean, std)
    }

    private func classifyTextureLevel(
        featureCount: Int,
        spatialCoverage: Double,
        meanGradient: Double
    ) -> TextureStrengthLevel {
        // Critical: very few features or very poor spatial distribution
        if featureCount < TextureStrengthConstants.CRITICAL_TEXTURE_FEATURE_COUNT ||
           spatialCoverage < 0.15 {
            return .critical
        }

        // Weak: below threshold or poor distribution
        if featureCount < TextureStrengthConstants.WEAK_TEXTURE_FEATURE_COUNT ||
           spatialCoverage < TextureStrengthConstants.MIN_SPATIAL_COVERAGE ||
           meanGradient < TextureStrengthConstants.MIN_GRADIENT_MAGNITUDE {
            return .weak
        }

        // Strong: above threshold with good distribution
        if featureCount >= TextureStrengthConstants.STRONG_TEXTURE_FEATURE_COUNT &&
           spatialCoverage >= 0.50 {
            return .strong
        }

        return .moderate
    }

    private func updateAdaptiveThreshold() {
        let levels = recentTextureLevels.toArray()
        guard !levels.isEmpty else { return }

        // Count weak/critical levels
        let weakCount = levels.filter { $0 == .weak || $0 == .critical }.count
        let weakRatio = Double(weakCount) / Double(levels.count)

        // Adapt threshold based on recent history
        if weakRatio > 0.7 {
            adaptiveThreshold = TextureStrengthConstants.ORB_FAST_THRESHOLD_CRITICAL
        } else if weakRatio > 0.3 {
            adaptiveThreshold = TextureStrengthConstants.ORB_FAST_THRESHOLD_WEAK
        } else {
            adaptiveThreshold = TextureStrengthConstants.ORB_FAST_THRESHOLD_NORMAL
        }
    }

    private func computeEnhancementParams(
        _ level: TextureStrengthLevel,
        _ meanGradient: Double
    ) -> TextureEnhancementParams {
        let intensity = level == .critical ? 1.5 : 1.0

        return TextureEnhancementParams(
            unsharpAmount: TextureStrengthConstants.WEAK_TEXTURE_UNSHARP_AMOUNT * Float(intensity),
            unsharpRadius: TextureStrengthConstants.WEAK_TEXTURE_UNSHARP_RADIUS,
            bilateralSigma: TextureStrengthConstants.WEAK_TEXTURE_BILATERAL_SIGMA,
            claheClip: TextureStrengthConstants.WEAK_TEXTURE_CLAHE_CLIP * Float(intensity),
            applyHistogramEqualization: meanGradient < 10.0
        )
    }

    private func computeConfidence(_ featureCount: Int, _ spatialCoverage: Double) -> Double {
        let featureConfidence = min(1.0, Double(featureCount) / Double(TextureStrengthConstants.STRONG_TEXTURE_FEATURE_COUNT))
        let coverageConfidence = spatialCoverage / 0.5
        return (featureConfidence + coverageConfidence) / 2.0
    }
}
```

---

## PART 4: INFORMATION GAIN CALCULATOR

### 4.1 Core Requirements

**Objective:** Quantify the marginal information value of a candidate frame relative to already-captured data. Used for keyframe selection and redundancy elimination.

**Research Basis:**
- [POp-GS: Next Best View with P-Optimality (2025)](https://arxiv.org/html/2503.07819)
- [Online 3DGS Modeling with Novel View Selection (2025)](https://arxiv.org/html/2508.14014)
- [FisherRF: Fisher Information for View Selection](https://arxiv.org/html/2503.07819)

### 4.2 Information Gain Calculator Specification

```swift
// File: Core/Selection/InformationGainCalculator.swift

import Foundation

/// InformationGainConstants - all thresholds centralized
public enum InformationGainConstants {
    // MARK: - Coverage Grid

    /// Grid resolution for spatial information tracking
    public static let COVERAGE_GRID_SIZE: Int = 32  // 32x32 = 1024 cells

    /// Minimum view angle difference for "new information" (degrees)
    public static let MIN_NOVEL_VIEW_ANGLE_DEG: Double = 15.0

    // MARK: - Information Thresholds

    /// Minimum information gain to accept frame
    public static let MIN_INFORMATION_GAIN: Double = 0.03

    /// High information gain threshold (prioritize these frames)
    public static let HIGH_INFORMATION_GAIN: Double = 0.15

    // MARK: - Frequency Domain Analysis

    /// Minimum median frequency for useful frame
    /// Research: frequency-based view selection uses median frequency as information proxy
    public static let MIN_MEDIAN_FREQUENCY: Double = 0.1

    // MARK: - Depth Coverage

    /// Depth range bins for coverage analysis
    public static let DEPTH_RANGE_BINS: Int = 10

    /// Minimum depth coverage ratio
    public static let MIN_DEPTH_COVERAGE_RATIO: Double = 0.20

    // MARK: - Feature Overlap

    /// Maximum feature overlap ratio for "redundant" frame
    public static let MAX_FEATURE_OVERLAP_RATIO: Double = 0.85

    /// Minimum new features to justify keeping frame
    public static let MIN_NEW_FEATURES: Int = 20

    // MARK: - Weighting

    public static let WEIGHT_SPATIAL_COVERAGE: Double = 0.30
    public static let WEIGHT_VIEW_NOVELTY: Double = 0.25
    public static let WEIGHT_DEPTH_COVERAGE: Double = 0.20
    public static let WEIGHT_FEATURE_NOVELTY: Double = 0.25
}

/// InformationGainResult - detailed analysis output
public struct InformationGainResult: Codable {
    /// Overall information gain [0, 1]
    public let totalGain: Double

    /// Spatial coverage gain [0, 1]
    public let spatialCoverageGain: Double

    /// View angle novelty [0, 1]
    public let viewNovelty: Double

    /// Depth range coverage gain [0, 1]
    public let depthCoverageGain: Double

    /// Feature novelty [0, 1]
    public let featureNovelty: Double

    /// Whether frame is recommended for keeping
    public let isRecommended: Bool

    /// Priority level (higher = more important to keep)
    public let priority: Int  // 0-10

    /// Confidence in calculation [0, 1]
    public let confidence: Double
}

/// CameraViewState - state of a captured view
public struct CameraViewState: Codable {
    /// View direction (normalized)
    public let viewDirection: SIMD3<Double>

    /// Camera position
    public let position: SIMD3<Double>

    /// Field of view (radians)
    public let fov: Double

    /// Depth range covered [min, max]
    public let depthRange: (min: Double, max: Double)

    /// Feature descriptors (for overlap calculation)
    public let featureCount: Int

    public init(
        viewDirection: SIMD3<Double>,
        position: SIMD3<Double>,
        fov: Double,
        depthRange: (min: Double, max: Double),
        featureCount: Int
    ) {
        self.viewDirection = viewDirection
        self.position = position
        self.fov = fov
        self.depthRange = depthRange
        self.featureCount = featureCount
    }
}

/// InformationGainCalculatorProtocol - cross-platform interface
public protocol InformationGainCalculatorProtocol {
    /// Calculate information gain for candidate frame
    func calculateGain(
        candidateView: CameraViewState,
        candidateFeatures: Set<UInt64>?,  // Feature hashes
        depthCoverage: [Bool]?  // Depth bin coverage
    ) -> InformationGainResult

    /// Register a frame as captured (updates internal state)
    func registerCapturedFrame(_ view: CameraViewState, features: Set<UInt64>?)

    /// Get current coverage statistics
    var coverageStats: CoverageStatistics { get }

    /// Reset state
    func reset()
}

/// CoverageStatistics - current capture coverage
public struct CoverageStatistics: Codable {
    /// Number of views captured
    public let viewCount: Int

    /// Spatial coverage ratio [0, 1]
    public let spatialCoverage: Double

    /// View angle coverage (degrees covered)
    public let viewAngleCoverage: Double

    /// Depth range coverage ratio [0, 1]
    public let depthCoverage: Double

    /// Total unique features tracked
    public let totalFeatures: Int
}

/// InformationGainCalculator - main implementation
public final class InformationGainCalculator: InformationGainCalculatorProtocol {

    // MARK: - Private State

    private var capturedViews: [CameraViewState] = []
    private var capturedFeatures: Set<UInt64> = []
    private var spatialCoverageGrid: [[Int]]  // Grid cell → view count
    private var depthBinCoverage: [Bool]
    private let stateLock = NSLock()

    // MARK: - Initialization

    public init() {
        let gridSize = InformationGainConstants.COVERAGE_GRID_SIZE
        self.spatialCoverageGrid = [[Int]](
            repeating: [Int](repeating: 0, count: gridSize),
            count: gridSize
        )
        self.depthBinCoverage = [Bool](
            repeating: false,
            count: InformationGainConstants.DEPTH_RANGE_BINS
        )
    }

    // MARK: - InformationGainCalculatorProtocol

    public func calculateGain(
        candidateView: CameraViewState,
        candidateFeatures: Set<UInt64>?,
        depthCoverage: [Bool]?
    ) -> InformationGainResult {
        stateLock.lock()
        defer { stateLock.unlock() }

        // Step 1: Spatial coverage gain
        let spatialGain = computeSpatialCoverageGain(candidateView)

        // Step 2: View novelty (angle from existing views)
        let viewNovelty = computeViewNovelty(candidateView)

        // Step 3: Depth coverage gain
        let depthGain = computeDepthCoverageGain(candidateView, depthCoverage)

        // Step 4: Feature novelty
        let featureNovelty = computeFeatureNovelty(candidateFeatures)

        // Step 5: Compute weighted total
        let totalGain =
            InformationGainConstants.WEIGHT_SPATIAL_COVERAGE * spatialGain +
            InformationGainConstants.WEIGHT_VIEW_NOVELTY * viewNovelty +
            InformationGainConstants.WEIGHT_DEPTH_COVERAGE * depthGain +
            InformationGainConstants.WEIGHT_FEATURE_NOVELTY * featureNovelty

        // Step 6: Determine recommendation and priority
        let isRecommended = totalGain >= InformationGainConstants.MIN_INFORMATION_GAIN
        let priority = computePriority(totalGain, viewNovelty)
        let confidence = computeConfidence()

        return InformationGainResult(
            totalGain: totalGain,
            spatialCoverageGain: spatialGain,
            viewNovelty: viewNovelty,
            depthCoverageGain: depthGain,
            featureNovelty: featureNovelty,
            isRecommended: isRecommended,
            priority: priority,
            confidence: confidence
        )
    }

    public func registerCapturedFrame(_ view: CameraViewState, features: Set<UInt64>?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        capturedViews.append(view)

        // Update spatial grid
        let (gridX, gridY) = viewToGridCell(view)
        spatialCoverageGrid[gridY][gridX] += 1

        // Update depth coverage
        updateDepthCoverage(view)

        // Update feature set
        if let features = features {
            capturedFeatures.formUnion(features)
        }
    }

    public var coverageStats: CoverageStatistics {
        stateLock.lock()
        defer { stateLock.unlock() }

        let gridSize = InformationGainConstants.COVERAGE_GRID_SIZE
        let filledCells = spatialCoverageGrid.flatMap { $0 }.filter { $0 > 0 }.count
        let spatialCoverage = Double(filledCells) / Double(gridSize * gridSize)

        let viewAngleCoverage = computeViewAngleCoverage()

        let depthCoveredBins = depthBinCoverage.filter { $0 }.count
        let depthCoverage = Double(depthCoveredBins) / Double(InformationGainConstants.DEPTH_RANGE_BINS)

        return CoverageStatistics(
            viewCount: capturedViews.count,
            spatialCoverage: spatialCoverage,
            viewAngleCoverage: viewAngleCoverage,
            depthCoverage: depthCoverage,
            totalFeatures: capturedFeatures.count
        )
    }

    public func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }

        capturedViews.removeAll()
        capturedFeatures.removeAll()

        let gridSize = InformationGainConstants.COVERAGE_GRID_SIZE
        spatialCoverageGrid = [[Int]](
            repeating: [Int](repeating: 0, count: gridSize),
            count: gridSize
        )
        depthBinCoverage = [Bool](
            repeating: false,
            count: InformationGainConstants.DEPTH_RANGE_BINS
        )
    }

    // MARK: - Private Helpers

    private func computeSpatialCoverageGain(_ view: CameraViewState) -> Double {
        let (gridX, gridY) = viewToGridCell(view)
        let currentCount = spatialCoverageGrid[gridY][gridX]

        // First view in cell = high gain, diminishing returns
        if currentCount == 0 { return 1.0 }
        if currentCount == 1 { return 0.5 }
        if currentCount == 2 { return 0.25 }
        return 0.1
    }

    private func computeViewNovelty(_ candidateView: CameraViewState) -> Double {
        guard !capturedViews.isEmpty else { return 1.0 }

        var minAngle = Double.infinity

        for existingView in capturedViews {
            let dot = simd_dot(candidateView.viewDirection, existingView.viewDirection)
            let angle = acos(min(1.0, max(-1.0, dot)))  // radians
            minAngle = min(minAngle, angle)
        }

        let minAngleDeg = minAngle * 180.0 / .pi
        let threshold = InformationGainConstants.MIN_NOVEL_VIEW_ANGLE_DEG

        // Sigmoid mapping around threshold
        return 1.0 / (1.0 + exp(-(minAngleDeg - threshold) / 5.0))
    }

    private func computeDepthCoverageGain(_ view: CameraViewState, _ coverage: [Bool]?) -> Double {
        guard let coverage = coverage else {
            // Estimate from view's depth range
            let bin1 = depthToBin(view.depthRange.min)
            let bin2 = depthToBin(view.depthRange.max)

            var newBins = 0
            for bin in min(bin1, bin2)...max(bin1, bin2) {
                if bin >= 0 && bin < depthBinCoverage.count && !depthBinCoverage[bin] {
                    newBins += 1
                }
            }

            return Double(newBins) / Double(InformationGainConstants.DEPTH_RANGE_BINS)
        }

        // Count new depth bins
        var newBins = 0
        for (i, covered) in coverage.enumerated() {
            if covered && i < depthBinCoverage.count && !depthBinCoverage[i] {
                newBins += 1
            }
        }

        return Double(newBins) / Double(InformationGainConstants.DEPTH_RANGE_BINS)
    }

    private func computeFeatureNovelty(_ candidateFeatures: Set<UInt64>?) -> Double {
        guard let features = candidateFeatures, !features.isEmpty else { return 0.5 }

        let newFeatures = features.subtracting(capturedFeatures)
        let overlapRatio = 1.0 - Double(newFeatures.count) / Double(features.count)

        if overlapRatio > InformationGainConstants.MAX_FEATURE_OVERLAP_RATIO {
            return 0.1  // Too redundant
        }

        if newFeatures.count >= InformationGainConstants.MIN_NEW_FEATURES {
            return min(1.0, Double(newFeatures.count) / 100.0)
        }

        return Double(newFeatures.count) / Double(InformationGainConstants.MIN_NEW_FEATURES) * 0.5
    }

    private func viewToGridCell(_ view: CameraViewState) -> (x: Int, y: Int) {
        // Map view direction to grid cell (spherical coordinates)
        let gridSize = InformationGainConstants.COVERAGE_GRID_SIZE

        // Azimuth: -π to π → 0 to gridSize
        let azimuth = atan2(view.viewDirection.y, view.viewDirection.x)
        let gridX = Int((azimuth + .pi) / (2 * .pi) * Double(gridSize)) % gridSize

        // Elevation: -π/2 to π/2 → 0 to gridSize
        let elevation = asin(min(1.0, max(-1.0, view.viewDirection.z)))
        let gridY = Int((elevation + .pi/2) / .pi * Double(gridSize)) % gridSize

        return (max(0, min(gridSize - 1, gridX)), max(0, min(gridSize - 1, gridY)))
    }

    private func updateDepthCoverage(_ view: CameraViewState) {
        let bin1 = depthToBin(view.depthRange.min)
        let bin2 = depthToBin(view.depthRange.max)

        for bin in min(bin1, bin2)...max(bin1, bin2) {
            if bin >= 0 && bin < depthBinCoverage.count {
                depthBinCoverage[bin] = true
            }
        }
    }

    private func depthToBin(_ depth: Double) -> Int {
        // Assume depth range 0.3m to 10m, logarithmic bins
        let minDepth = 0.3
        let maxDepth = 10.0
        let logMin = log(minDepth)
        let logMax = log(maxDepth)

        let clamped = min(maxDepth, max(minDepth, depth))
        let normalized = (log(clamped) - logMin) / (logMax - logMin)

        return Int(normalized * Double(InformationGainConstants.DEPTH_RANGE_BINS - 1))
    }

    private func computeViewAngleCoverage() -> Double {
        guard capturedViews.count >= 2 else { return 0.0 }

        // Compute convex hull of view directions (simplified: just max angle spread)
        var maxAngle: Double = 0
        for i in 0..<capturedViews.count {
            for j in (i+1)..<capturedViews.count {
                let dot = simd_dot(capturedViews[i].viewDirection, capturedViews[j].viewDirection)
                let angle = acos(min(1.0, max(-1.0, dot)))
                maxAngle = max(maxAngle, angle)
            }
        }

        return maxAngle * 180.0 / .pi  // Return degrees
    }

    private func computePriority(_ totalGain: Double, _ viewNovelty: Double) -> Int {
        if totalGain >= InformationGainConstants.HIGH_INFORMATION_GAIN && viewNovelty > 0.8 {
            return 10  // Critical frame
        }
        if totalGain >= InformationGainConstants.HIGH_INFORMATION_GAIN {
            return 8
        }
        if totalGain >= InformationGainConstants.MIN_INFORMATION_GAIN * 2 {
            return 6
        }
        if totalGain >= InformationGainConstants.MIN_INFORMATION_GAIN {
            return 4
        }
        return 2
    }

    private func computeConfidence() -> Double {
        // Higher confidence with more captured views
        let viewFactor = min(1.0, Double(capturedViews.count) / 20.0)
        return 0.5 + 0.5 * viewFactor
    }
}
```

---

## PART 5: END-TO-END TESTING FRAMEWORK

### 5.1 Core Requirements

**Objective:** Comprehensive validation of evidence curve behavior across diverse scenarios. Must verify:
1. Evidence monotonicity (UI display never decreases)
2. Ledger correctability (internal state can recover from errors)
3. Color mapping consistency
4. Performance under stress

**Research Basis:**
- [XCUITest Best Practices 2025](https://testgrid.io/blog/best-ios-testing-tools/)
- [iOS Visual Regression Testing](https://www.globalapptesting.com/blog/ios-testing-framework)
- [CI/CD Integration for Mobile Testing](https://www.headspin.io/blog/ios-automation-testing-top-frameworks)

### 5.2 Evidence Curve Test Specification

```swift
// File: Tests/E2E/EvidenceCurveTests.swift

import XCTest
@testable import Aether3DCore

/// EvidenceCurveTests - comprehensive evidence system validation
final class EvidenceCurveTests: XCTestCase {

    // MARK: - Test Constants

    private enum TestConstants {
        static let MONOTONICITY_VIOLATION_TOLERANCE: Double = 0.001
        static let MAX_LEDGER_RECOVERY_FRAMES: Int = 30
        static let STRESS_TEST_FRAME_COUNT: Int = 1000
        static let PERFORMANCE_TEST_ITERATIONS: Int = 100
    }

    // MARK: - Setup

    private var evidenceEngine: EvidenceEngineProtocol!
    private var clockProvider: MockClockProvider!

    override func setUp() {
        super.setUp()
        clockProvider = MockClockProvider()
        evidenceEngine = createEvidenceEngine(clockProvider: clockProvider)
    }

    override func tearDown() {
        evidenceEngine = nil
        clockProvider = nil
        super.tearDown()
    }

    // MARK: - Test 1: UI Evidence Monotonicity

    /// Verify that display evidence (UI-visible) NEVER decreases
    func testUIEvidenceMonotonicity() {
        var previousDisplay: Double = 0.0

        // Simulate 500 frames with varying quality
        for i in 0..<500 {
            let observation = generateRandomObservation(frameIndex: i)
            evidenceEngine.update(observation: observation)

            let currentDisplay = evidenceEngine.displayEvidence

            // H1: UI evidence must be monotonically non-decreasing
            XCTAssertGreaterThanOrEqual(
                currentDisplay,
                previousDisplay - TestConstants.MONOTONICITY_VIOLATION_TOLERANCE,
                "UI evidence decreased at frame \(i): \(previousDisplay) → \(currentDisplay)"
            )

            previousDisplay = currentDisplay
        }
    }

    /// Test monotonicity even with bad observations
    func testUIMonotonicityWithBadObservations() {
        var previousDisplay: Double = 0.0

        // First: build up some evidence
        for i in 0..<100 {
            let goodObservation = Observation(
                patchId: "patch_\(i % 20)",
                quality: 0.8,
                isErroneous: false,
                timestamp: Int64(i * 33)
            )
            evidenceEngine.update(observation: goodObservation)
        }

        previousDisplay = evidenceEngine.displayEvidence

        // Now: inject bad observations
        for i in 100..<200 {
            let badObservation = Observation(
                patchId: "patch_\(i % 20)",
                quality: 0.1,
                isErroneous: true,  // Erroneous flag
                timestamp: Int64(i * 33)
            )
            evidenceEngine.update(observation: badObservation)

            let currentDisplay = evidenceEngine.displayEvidence

            // H1: UI must still be monotonic even with bad data
            XCTAssertGreaterThanOrEqual(
                currentDisplay,
                previousDisplay - TestConstants.MONOTONICITY_VIOLATION_TOLERANCE,
                "UI evidence decreased with bad observation at frame \(i)"
            )

            previousDisplay = currentDisplay
        }
    }

    // MARK: - Test 2: Ledger Correctability

    /// Verify that ledger can correct errors without affecting UI monotonicity
    func testLedgerCorrectability() {
        // Step 1: Add some erroneous observations
        for i in 0..<50 {
            let observation = Observation(
                patchId: "patch_\(i % 10)",
                quality: 0.9,
                isErroneous: i % 5 == 0,  // 20% erroneous
                timestamp: Int64(i * 33)
            )
            evidenceEngine.update(observation: observation)
        }

        let ledgerBeforeCorrection = evidenceEngine.ledgerTotal
        let displayBeforeCorrection = evidenceEngine.displayEvidence

        // Step 2: Mark all erroneous observations explicitly
        for i in 0..<50 where i % 5 == 0 {
            let correctionObservation = Observation(
                patchId: "patch_\(i % 10)",
                quality: 0.0,
                isErroneous: true,
                timestamp: Int64(50 * 33 + i)
            )
            evidenceEngine.update(observation: correctionObservation)
        }

        let ledgerAfterCorrection = evidenceEngine.ledgerTotal
        let displayAfterCorrection = evidenceEngine.displayEvidence

        // H2: Ledger can decrease (internal correction)
        // This is allowed - ledger is not UI-visible

        // H1: Display must still be monotonic
        XCTAssertGreaterThanOrEqual(
            displayAfterCorrection,
            displayBeforeCorrection - TestConstants.MONOTONICITY_VIOLATION_TOLERANCE,
            "Display evidence decreased during ledger correction"
        )
    }

    // MARK: - Test 3: Color Mapping Consistency

    /// Verify color mapping thresholds produce expected transitions
    func testColorMappingTransitions() {
        let colorMapper = ColorMapper()

        // Test threshold boundaries
        let testCases: [(evidence: Double, expectedMinBrightness: Double)] = [
            (0.0, 0.0),    // Black
            (0.19, 0.0),   // Still black
            (0.21, 0.15),  // Dark gray
            (0.44, 0.15),  // Still dark gray
            (0.46, 0.35),  // Light gray
            (0.69, 0.35),  // Still light gray
            (0.71, 0.60),  // White
            (0.87, 0.60),  // Still white
            (0.89, 0.85),  // Original color
        ]

        for (evidence, expectedMinBrightness) in testCases {
            let color = colorMapper.colorFor(displayEvidence: evidence, softEvidence: evidence)
            let brightness = color.brightness

            XCTAssertGreaterThanOrEqual(
                brightness,
                expectedMinBrightness,
                "Color brightness too low for evidence \(evidence)"
            )
        }
    }

    /// Verify color never goes backwards (darker after being lighter)
    func testColorNeverReverses() {
        let colorMapper = ColorMapper()
        var previousBrightness: Double = 0.0

        // Increase evidence from 0 to 1
        for i in 0...100 {
            let evidence = Double(i) / 100.0
            let color = colorMapper.colorFor(displayEvidence: evidence, softEvidence: evidence)
            let brightness = color.brightness

            XCTAssertGreaterThanOrEqual(
                brightness,
                previousBrightness - 0.01,  // Small tolerance for floating point
                "Color reversed at evidence \(evidence)"
            )

            previousBrightness = brightness
        }
    }

    // MARK: - Test 4: Dynamic Weight Transitions

    /// Verify Gate/Soft weight transitions are smooth
    func testDynamicWeightTransitions() {
        var previousGateWeight: Double = 0.65  // Initial gate weight

        for i in 0...100 {
            let progress = Double(i) / 100.0
            let weights = DynamicWeights.weights(currentTotal: progress)

            // Weights must sum to 1.0
            XCTAssertEqual(
                weights.gate + weights.soft,
                1.0,
                accuracy: 0.001,
                "Weights don't sum to 1.0 at progress \(progress)"
            )

            // Gate weight should decrease smoothly
            XCTAssertLessThanOrEqual(
                abs(weights.gate - previousGateWeight),
                0.05,  // Max 5% change per step
                "Gate weight changed too abruptly at progress \(progress)"
            )

            previousGateWeight = weights.gate
        }
    }

    // MARK: - Test 5: Stress Test

    /// High-volume frame processing stress test
    func testStressFrameProcessing() {
        let startTime = CFAbsoluteTimeGetCurrent()

        for i in 0..<TestConstants.STRESS_TEST_FRAME_COUNT {
            let observation = generateRandomObservation(frameIndex: i)
            evidenceEngine.update(observation: observation)

            // Verify no crashes or NaN values
            XCTAssertFalse(evidenceEngine.displayEvidence.isNaN, "NaN at frame \(i)")
            XCTAssertFalse(evidenceEngine.displayEvidence.isInfinite, "Inf at frame \(i)")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let framesPerSecond = Double(TestConstants.STRESS_TEST_FRAME_COUNT) / elapsed

        // Must maintain 30fps capability
        XCTAssertGreaterThan(framesPerSecond, 30.0, "Stress test too slow: \(framesPerSecond) fps")
    }

    // MARK: - Test 6: Performance Benchmarks

    func testPerformanceSingleUpdate() {
        let observation = generateRandomObservation(frameIndex: 0)

        measure {
            for _ in 0..<TestConstants.PERFORMANCE_TEST_ITERATIONS {
                evidenceEngine.update(observation: observation)
            }
        }
    }

    func testPerformanceColorMapping() {
        let colorMapper = ColorMapper()

        measure {
            for i in 0..<TestConstants.PERFORMANCE_TEST_ITERATIONS {
                let evidence = Double(i % 100) / 100.0
                _ = colorMapper.colorFor(displayEvidence: evidence, softEvidence: evidence)
            }
        }
    }

    // MARK: - Test 7: Cross-Platform Determinism

    /// Verify same inputs produce same outputs on any platform
    func testDeterministicOutput() {
        let seed: UInt64 = 12345
        var rng = SeededRandomNumberGenerator(seed: seed)

        // Run test sequence
        for i in 0..<100 {
            let quality = Double.random(in: 0...1, using: &rng)
            let observation = Observation(
                patchId: "patch_\(i % 10)",
                quality: quality,
                isErroneous: false,
                timestamp: Int64(i * 33)
            )
            evidenceEngine.update(observation: observation)
        }

        let finalDisplay = evidenceEngine.displayEvidence

        // Reset and run again
        evidenceEngine = createEvidenceEngine(clockProvider: clockProvider)
        rng = SeededRandomNumberGenerator(seed: seed)

        for i in 0..<100 {
            let quality = Double.random(in: 0...1, using: &rng)
            let observation = Observation(
                patchId: "patch_\(i % 10)",
                quality: quality,
                isErroneous: false,
                timestamp: Int64(i * 33)
            )
            evidenceEngine.update(observation: observation)
        }

        let finalDisplay2 = evidenceEngine.displayEvidence

        // Must be exactly equal (deterministic)
        XCTAssertEqual(finalDisplay, finalDisplay2, accuracy: 1e-10)
    }

    // MARK: - Test 8: Edge Cases

    func testEmptyPatchId() {
        let observation = Observation(
            patchId: "",
            quality: 0.5,
            isErroneous: false,
            timestamp: 0
        )

        // Should not crash
        evidenceEngine.update(observation: observation)
        XCTAssertFalse(evidenceEngine.displayEvidence.isNaN)
    }

    func testNegativeQuality() {
        let observation = Observation(
            patchId: "patch_0",
            quality: -0.5,  // Invalid
            isErroneous: false,
            timestamp: 0
        )

        evidenceEngine.update(observation: observation)

        // Should clamp to 0, not crash
        XCTAssertGreaterThanOrEqual(evidenceEngine.displayEvidence, 0.0)
    }

    func testQualityAboveOne() {
        let observation = Observation(
            patchId: "patch_0",
            quality: 1.5,  // Invalid
            isErroneous: false,
            timestamp: 0
        )

        evidenceEngine.update(observation: observation)

        // Should clamp to 1, not crash
        XCTAssertLessThanOrEqual(evidenceEngine.displayEvidence, 1.0)
    }

    func testNaNQuality() {
        let observation = Observation(
            patchId: "patch_0",
            quality: Double.nan,
            isErroneous: false,
            timestamp: 0
        )

        evidenceEngine.update(observation: observation)

        // Should handle gracefully
        XCTAssertFalse(evidenceEngine.displayEvidence.isNaN)
    }

    // MARK: - Helpers

    private func createEvidenceEngine(clockProvider: ClockProvider) -> EvidenceEngineProtocol {
        // Factory method - implementation will be in PR2
        return MockEvidenceEngine()
    }

    private func generateRandomObservation(frameIndex: Int) -> Observation {
        let patchCount = 20
        let patchId = "patch_\(frameIndex % patchCount)"
        let quality = Double.random(in: 0.3...0.9)
        let isErroneous = Double.random(in: 0...1) < 0.05  // 5% error rate

        return Observation(
            patchId: patchId,
            quality: quality,
            isErroneous: isErroneous,
            timestamp: Int64(frameIndex * 33)
        )
    }
}

// MARK: - Mock Types for Testing

private struct Observation {
    let patchId: String
    let quality: Double
    let isErroneous: Bool
    let timestamp: Int64
}

private protocol EvidenceEngineProtocol {
    func update(observation: Observation)
    var displayEvidence: Double { get }
    var ledgerTotal: Double { get }
}

private class MockEvidenceEngine: EvidenceEngineProtocol {
    private var _display: Double = 0.0
    private var _ledger: [String: Double] = [:]

    var displayEvidence: Double { _display }
    var ledgerTotal: Double {
        guard !_ledger.isEmpty else { return 0.0 }
        return _ledger.values.reduce(0, +) / Double(_ledger.count)
    }

    func update(observation: Observation) {
        // Clamp quality to valid range
        var quality = observation.quality
        if quality.isNaN || quality.isInfinite {
            quality = 0.0
        }
        quality = min(1.0, max(0.0, quality))

        // Update ledger (can go down)
        if observation.isErroneous {
            _ledger[observation.patchId] = max(0, (_ledger[observation.patchId] ?? 0) - 0.2)
        } else if quality > (_ledger[observation.patchId] ?? 0) {
            _ledger[observation.patchId] = quality
        }

        // Update display (monotonic)
        let ledgerAvg = ledgerTotal
        let alpha = 0.1
        let smoothed = alpha * ledgerAvg + (1.0 - alpha) * _display
        _display = max(_display, smoothed)
    }
}

private class MockClockProvider: ClockProvider {
    var currentTime: Int64 = 0

    func currentTimeMillis() -> Int64 {
        return currentTime
    }

    func advance(by ms: Int64) {
        currentTime += ms
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // Simple LCG
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
```

### 5.3 Performance Test Specification

```swift
// File: Tests/E2E/PerformanceTests.swift

import XCTest
@testable import Aether3DCore

/// PerformanceTests - comprehensive performance validation
final class PerformanceTests: XCTestCase {

    // MARK: - Test Constants

    private enum PerformanceConstants {
        // Budget from QualityPreCheckConstants
        static let P50_BUDGET_MS: Double = 14.0
        static let P95_BUDGET_MS: Double = 22.0
        static let EMERGENCY_P50_MS: Double = 2.0

        static let FRAME_COUNT: Int = 1000
        static let WARMUP_FRAMES: Int = 100
    }

    // MARK: - Test Full Pipeline Latency

    func testFullPipelineP50Latency() {
        var latencies: [Double] = []

        // Warmup
        for _ in 0..<PerformanceConstants.WARMUP_FRAMES {
            _ = simulateFullPipelineFrame()
        }

        // Measure
        for _ in 0..<PerformanceConstants.FRAME_COUNT {
            let latency = simulateFullPipelineFrame()
            latencies.append(latency)
        }

        latencies.sort()
        let p50Index = Int(Double(latencies.count) * 0.50)
        let p50 = latencies[p50Index]

        XCTAssertLessThanOrEqual(
            p50,
            PerformanceConstants.P50_BUDGET_MS,
            "P50 latency \(p50)ms exceeds budget \(PerformanceConstants.P50_BUDGET_MS)ms"
        )
    }

    func testFullPipelineP95Latency() {
        var latencies: [Double] = []

        // Warmup
        for _ in 0..<PerformanceConstants.WARMUP_FRAMES {
            _ = simulateFullPipelineFrame()
        }

        // Measure
        for _ in 0..<PerformanceConstants.FRAME_COUNT {
            let latency = simulateFullPipelineFrame()
            latencies.append(latency)
        }

        latencies.sort()
        let p95Index = Int(Double(latencies.count) * 0.95)
        let p95 = latencies[p95Index]

        XCTAssertLessThanOrEqual(
            p95,
            PerformanceConstants.P95_BUDGET_MS,
            "P95 latency \(p95)ms exceeds budget \(PerformanceConstants.P95_BUDGET_MS)ms"
        )
    }

    // MARK: - Test Memory Usage

    func testMemoryStability() {
        var peakMemory: UInt64 = 0

        for i in 0..<PerformanceConstants.FRAME_COUNT {
            _ = simulateFullPipelineFrame()

            // Check memory every 100 frames
            if i % 100 == 0 {
                let currentMemory = getCurrentMemoryUsage()
                peakMemory = max(peakMemory, currentMemory)
            }
        }

        // Memory should not grow unbounded
        let finalMemory = getCurrentMemoryUsage()
        let memoryGrowthMB = Double(finalMemory - peakMemory) / (1024 * 1024)

        // Allow max 50MB growth over test duration
        XCTAssertLessThan(memoryGrowthMB, 50.0, "Memory grew by \(memoryGrowthMB)MB")
    }

    // MARK: - Test Individual Component Latency

    func testExposureAnalysisLatency() {
        measure {
            for _ in 0..<100 {
                _ = simulateExposureAnalysis()
            }
        }
    }

    func testTextureAnalysisLatency() {
        measure {
            for _ in 0..<100 {
                _ = simulateTextureAnalysis()
            }
        }
    }

    func testInformationGainLatency() {
        measure {
            for _ in 0..<100 {
                _ = simulateInformationGainCalculation()
            }
        }
    }

    func testEvidenceUpdateLatency() {
        measure {
            for _ in 0..<100 {
                _ = simulateEvidenceUpdate()
            }
        }
    }

    // MARK: - Test Battery Impact Estimation

    func testCPUUtilization() {
        // Run for 5 seconds at target frame rate
        let targetFPS = 30
        let testDuration: TimeInterval = 5.0
        let frameInterval = 1.0 / Double(targetFPS)

        var totalCPUTime: TimeInterval = 0
        var frameCount = 0

        let startWallTime = CFAbsoluteTimeGetCurrent()

        while CFAbsoluteTimeGetCurrent() - startWallTime < testDuration {
            let frameStart = CFAbsoluteTimeGetCurrent()
            _ = simulateFullPipelineFrame()
            let frameEnd = CFAbsoluteTimeGetCurrent()

            totalCPUTime += (frameEnd - frameStart)
            frameCount += 1

            // Simulate frame timing
            let sleepTime = frameInterval - (frameEnd - frameStart)
            if sleepTime > 0 {
                Thread.sleep(forTimeInterval: sleepTime)
            }
        }

        let cpuUtilization = totalCPUTime / testDuration

        // CPU utilization should be under 30% at 30fps
        XCTAssertLessThan(cpuUtilization, 0.30, "CPU utilization \(cpuUtilization * 100)% is too high")
    }

    // MARK: - Helpers

    private func simulateFullPipelineFrame() -> Double {
        let start = CFAbsoluteTimeGetCurrent()

        // Simulate all PR5 components
        _ = simulateExposureAnalysis()
        _ = simulateTextureAnalysis()
        _ = simulateInformationGainCalculation()
        _ = simulateEvidenceUpdate()

        let end = CFAbsoluteTimeGetCurrent()
        return (end - start) * 1000  // ms
    }

    private func simulateExposureAnalysis() -> Double {
        // Simulate histogram computation
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<256 {
            histogram[i] = Int.random(in: 0...1000)
        }

        let total = histogram.reduce(0, +)
        let overexposed = histogram[250...255].reduce(0, +)
        _ = Double(overexposed) / Double(total)

        return 0.0
    }

    private func simulateTextureAnalysis() -> Double {
        // Simulate feature detection
        var features: [(Int, Int)] = []
        for _ in 0..<200 {
            features.append((Int.random(in: 0..<1920), Int.random(in: 0..<1080)))
        }

        // Simulate spatial coverage computation
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: 8), count: 8)
        for (x, y) in features {
            grid[y / 135][x / 240] = true
        }

        return 0.0
    }

    private func simulateInformationGainCalculation() -> Double {
        // Simulate view novelty computation
        var views: [SIMD3<Double>] = []
        for _ in 0..<50 {
            views.append(SIMD3<Double>(
                Double.random(in: -1...1),
                Double.random(in: -1...1),
                Double.random(in: -1...1)
            ))
        }

        let candidate = SIMD3<Double>(0.5, 0.5, 0.5)
        var minAngle: Double = .infinity
        for view in views {
            let dot = simd_dot(candidate, view)
            minAngle = min(minAngle, acos(min(1, max(-1, dot))))
        }

        return 0.0
    }

    private func simulateEvidenceUpdate() -> Double {
        // Simulate ledger update
        var ledger: [String: Double] = [:]
        for i in 0..<20 {
            ledger["patch_\(i)"] = Double.random(in: 0...1)
        }

        let total = ledger.values.reduce(0, +) / Double(ledger.count)
        _ = max(0, min(1, total))

        return 0.0
    }

    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
```

---

## PART 6: CONSTANTS CONSOLIDATION

### 6.1 PR5 Master Constants File

```swift
// File: Core/Constants/PR5CaptureConstants.swift

import Foundation

/// PR5CaptureConstants - ALL PR5 magic numbers centralized
/// H2: No hardcoded values allowed in implementation files
public enum PR5CaptureConstants {

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 1: EXPOSURE CONTROL
    // ═══════════════════════════════════════════════════════════════════

    public enum Exposure {
        // Thresholds
        public static let LOW_LIGHT_THRESHOLD_LUX: Double = 5.0
        public static let CRITICAL_LOW_LIGHT_LUX: Double = 1.0
        public static let MAX_EV_CHANGE_PER_FRAME: Double = 0.05
        public static let EXPOSURE_LOCK_HYSTERESIS_MS: Int64 = 500
        public static let LOW_LIGHT_ADAPTATION_WINDOW_MS: Int64 = 2000

        // Histogram
        public static let OVEREXPOSURE_HISTOGRAM_THRESHOLD: Double = 0.05
        public static let UNDEREXPOSURE_HISTOGRAM_THRESHOLD: Double = 0.15
        public static let LARGE_BLOWN_REGION_THRESHOLD: Double = 0.02

        // Torch
        public static let TORCH_LEVEL_OFF: Float = 0.0
        public static let TORCH_LEVEL_LOW: Float = 0.3
        public static let TORCH_LEVEL_MEDIUM: Float = 0.6
        public static let TORCH_LEVEL_HIGH: Float = 0.9
        public static let TORCH_WARMUP_MS: Int64 = 200
        public static let TORCH_COOLDOWN_MS: Int64 = 5000

        // Temporal
        public static let EXPOSURE_EMA_ALPHA: Double = 0.1
        public static let MIN_STABLE_EXPOSURE_FRAMES: Int = 5
        public static let FLICKER_DETECTION_WINDOW: Int = 10
        public static let MAX_BRIGHTNESS_VARIANCE: Double = 0.03
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 2: FRAME QUALITY
    // ═══════════════════════════════════════════════════════════════════

    public enum FrameQuality {
        // Sharpness
        public static let LAPLACIAN_SHARP_THRESHOLD: Double = 150.0
        public static let LAPLACIAN_BLUR_THRESHOLD: Double = 50.0
        public static let TENENGRAD_SHARP_THRESHOLD: Double = 25.0

        // Motion
        public static let MAX_OPTICAL_FLOW_MAGNITUDE: Double = 3.0
        public static let MAX_ANGULAR_VELOCITY: Double = 0.5
        public static let MAX_LINEAR_ACCELERATION: Double = 2.0

        // Similarity
        public static let SSIM_REDUNDANCY_THRESHOLD: Double = 0.98
        public static let MIN_INFORMATION_GAIN: Double = 0.05

        // Weights
        public static let WEIGHT_SHARPNESS: Double = 0.35
        public static let WEIGHT_EXPOSURE: Double = 0.25
        public static let WEIGHT_MOTION: Double = 0.20
        public static let WEIGHT_INFORMATION: Double = 0.20

        // Performance
        public static let MAX_QUALITY_CHECK_LATENCY_MS: Double = 10.0
        public static let DEGRADED_QUALITY_CHECK_LATENCY_MS: Double = 5.0
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 3: TEXTURE STRENGTH
    // ═══════════════════════════════════════════════════════════════════

    public enum Texture {
        // Feature Count
        public static let STRONG_TEXTURE_FEATURE_COUNT: Int = 200
        public static let WEAK_TEXTURE_FEATURE_COUNT: Int = 80
        public static let CRITICAL_TEXTURE_FEATURE_COUNT: Int = 30

        // Gradient
        public static let MIN_GRADIENT_MAGNITUDE: Double = 15.0
        public static let MIN_GRADIENT_STD: Double = 20.0

        // Spatial
        public static let MIN_SPATIAL_COVERAGE: Double = 0.30
        public static let SPATIAL_GRID_SIZE: Int = 8

        // Enhancement
        public static let WEAK_TEXTURE_UNSHARP_AMOUNT: Float = 0.3
        public static let WEAK_TEXTURE_UNSHARP_RADIUS: Float = 1.5
        public static let WEAK_TEXTURE_BILATERAL_SIGMA: Float = 2.0
        public static let WEAK_TEXTURE_CLAHE_CLIP: Float = 2.0

        // ORB Adaptive
        public static let ORB_FAST_THRESHOLD_NORMAL: Int = 20
        public static let ORB_FAST_THRESHOLD_WEAK: Int = 10
        public static let ORB_FAST_THRESHOLD_CRITICAL: Int = 5
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 4: INFORMATION GAIN
    // ═══════════════════════════════════════════════════════════════════

    public enum InformationGain {
        // Coverage Grid
        public static let COVERAGE_GRID_SIZE: Int = 32
        public static let MIN_NOVEL_VIEW_ANGLE_DEG: Double = 15.0

        // Thresholds
        public static let MIN_INFORMATION_GAIN: Double = 0.03
        public static let HIGH_INFORMATION_GAIN: Double = 0.15

        // Frequency
        public static let MIN_MEDIAN_FREQUENCY: Double = 0.1

        // Depth
        public static let DEPTH_RANGE_BINS: Int = 10
        public static let MIN_DEPTH_COVERAGE_RATIO: Double = 0.20

        // Features
        public static let MAX_FEATURE_OVERLAP_RATIO: Double = 0.85
        public static let MIN_NEW_FEATURES: Int = 20

        // Weights
        public static let WEIGHT_SPATIAL_COVERAGE: Double = 0.30
        public static let WEIGHT_VIEW_NOVELTY: Double = 0.25
        public static let WEIGHT_DEPTH_COVERAGE: Double = 0.20
        public static let WEIGHT_FEATURE_NOVELTY: Double = 0.25
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 5: DYNAMIC WEIGHTS (v5.0)
    // ═══════════════════════════════════════════════════════════════════

    public enum DynamicWeights {
        // Gate/Soft transition points
        public static let GATE_SOFT_TRANSITION_START: Double = 0.45
        public static let GATE_SOFT_TRANSITION_END: Double = 0.75

        // Initial weights (progress < 0.45)
        public static let INITIAL_GATE_WEIGHT: Double = 0.65
        public static let INITIAL_SOFT_WEIGHT: Double = 0.35

        // Final weights (progress > 0.75)
        public static let FINAL_GATE_WEIGHT: Double = 0.35
        public static let FINAL_SOFT_WEIGHT: Double = 0.65

        // Gate internal
        public static let GATE_VIEW_WEIGHT: Double = 0.40
        public static let GATE_GEOM_WEIGHT: Double = 0.45
        public static let GATE_BASIC_WEIGHT: Double = 0.15

        // Soft internal (v5.0 adjusted)
        public static let SOFT_VIEW_WEIGHT: Double = 0.15
        public static let SOFT_GEOM_WEIGHT: Double = 0.10  // Reduced from 0.20
        public static let SOFT_DEPTH_WEIGHT: Double = 0.30  // Increased
        public static let SOFT_TOPO_WEIGHT: Double = 0.35   // Increased
        public static let SOFT_SEMANTIC_WEIGHT: Double = 0.10
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 6: COLOR MAPPING
    // ═══════════════════════════════════════════════════════════════════

    public enum ColorMapping {
        public static let BLACK_THRESHOLD: Double = 0.20
        public static let DARK_GRAY_THRESHOLD: Double = 0.45
        public static let LIGHT_GRAY_THRESHOLD: Double = 0.70
        public static let WHITE_THRESHOLD: Double = 0.88
        public static let ORIGINAL_COLOR_MIN_SOFT_EVIDENCE: Double = 0.75
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 7: PERFORMANCE BUDGETS
    // ═══════════════════════════════════════════════════════════════════

    public enum Performance {
        public static let P50_BUDGET_MS: Double = 14.0
        public static let P95_BUDGET_MS: Double = 22.0
        public static let EMERGENCY_P50_MS: Double = 2.0

        public static let TARGET_FPS: Int = 30
        public static let MIN_FPS_FULL: Double = 30.0
        public static let MIN_FPS_DEGRADED: Double = 20.0

        public static let MAX_MEMORY_GROWTH_MB: Double = 50.0
        public static let MAX_CPU_UTILIZATION: Double = 0.30
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 8: TIME WINDOW SMOOTHER
    // ═══════════════════════════════════════════════════════════════════

    public enum Smoother {
        public static let DEPTH_EDGE_WINDOW_SIZE: Int = 5
        public static let OCCLUSION_WINDOW_SIZE: Int = 5
        public static let EVIDENCE_EMA_ALPHA: Double = 0.1
    }

    // ═══════════════════════════════════════════════════════════════════
    // SECTION 9: MULTIPLICATIVE GAIN (v5.0)
    // ═══════════════════════════════════════════════════════════════════

    public enum MultiplicativeGain {
        /// Minimum multiplier (prevents complete zeroing)
        public static let MIN_FACTOR_FLOOR: Double = 0.1

        /// Base gain before multipliers
        public static let BASE_GAIN: Double = 0.5
    }
}
```

---

## PART 7: DELIVERABLES CHECKLIST

### 7.1 Required Files

| File Path | Description | Cross-Platform |
|-----------|-------------|----------------|
| `Core/Capture/ExposureController.swift` | Exposure lock + torch control | iOS impl, Linux stub |
| `Core/Capture/FrameQualityDetector.swift` | Frame quality decision | ✓ |
| `Core/Capture/TextureStrengthAnalyzer.swift` | Texture detection + assistFrame trigger | ✓ |
| `Core/Selection/InformationGainCalculator.swift` | Keyframe selection criteria | ✓ |
| `Core/Constants/PR5CaptureConstants.swift` | All PR5 constants | ✓ |
| `Tests/E2E/EvidenceCurveTests.swift` | Evidence system validation | ✓ |
| `Tests/E2E/PerformanceTests.swift` | Performance benchmarks | ✓ |
| `Tests/PR5CaptureTests/ExposureControllerTests.swift` | Exposure unit tests | ✓ |
| `Tests/PR5CaptureTests/FrameQualityTests.swift` | Quality detection tests | ✓ |
| `Tests/PR5CaptureTests/TextureStrengthTests.swift` | Texture analysis tests | ✓ |
| `Tests/PR5CaptureTests/InformationGainTests.swift` | Info gain tests | ✓ |

### 7.2 Integration Points

1. **PR2 Integration:** Evidence system consumes PR5 frame quality metrics
2. **PR3 Integration:** Gate system uses PR5 exposure/texture signals for thresholds
3. **PR4 Integration:** Soft system uses PR5 depth quality and information gain
4. **Existing Code:** Must integrate with existing `CameraSession.swift`, `RecordingController.swift`

### 7.3 CI Requirements

- All tests must pass on both macOS (Apple Silicon) and Linux (x86_64)
- Performance tests must meet P50/P95 budgets
- No force unwraps, no `Date()` calls, no magic numbers
- Thread safety verified with TSAN

---

## PART 8: IMPLEMENTATION PRIORITY

| Priority | Task | Effort | Impact |
|----------|------|--------|--------|
| P0 | ExposureController + tests | 2 days | High |
| P0 | FrameQualityDetector + tests | 2 days | High |
| P0 | PR5CaptureConstants | 0.5 days | Critical |
| P1 | TextureStrengthAnalyzer + tests | 1.5 days | Medium |
| P1 | InformationGainCalculator + tests | 2 days | Medium |
| P1 | EvidenceCurveTests (E2E) | 1.5 days | High |
| P2 | PerformanceTests | 1 day | Medium |
| P2 | Integration with CameraSession | 1 day | High |

**Total Estimated Effort:** 11.5 days (Week 5-6 as per master plan)

---

## PART 9: RESEARCH REFERENCES

### Exposure Control
- [Learning to Control Camera Exposure via Reinforcement Learning](https://arxiv.org/html/2404.01636v1)
- [Android Low Light Boost (2025)](https://android-developers.googleblog.com/2025/12/brighten-your-real-time-camera-feeds.html)
- [Gradient-based Camera Exposure Control](https://arxiv.org/pdf/1708.07338)
- [Auto-Exposure for Enhanced Mobile Robot Localization](https://www.mdpi.com/1424-8220/22/3/835)

### Image Quality Assessment
- [LAR-IQA: Lightweight NR-IQA Model](https://arxiv.org/abs/2408.17057)
- [MobileIQA via Knowledge Distillation (ECCV 2024)](https://link.springer.com/chapter/10.1007/978-3-031-91856-8_1)
- [Deep Learning NR-IQA Survey 2025](https://www.scitepress.org/Papers/2025/135977/135977.pdf)

### Low-Texture SLAM
- [Post-integration Point-Line SLAM (Nature 2025)](https://www.nature.com/articles/s41598-025-97250-6)
- [SL-SLAM: Deep Feature Extraction](https://arxiv.org/html/2405.03413v2)
- [PLFG-SLAM: Adaptive Threshold Feature Extraction](https://www.sciencedirect.com/science/article/abs/pii/S0263224125017944)

### Information Gain & View Selection
- [POp-GS: Next Best View with P-Optimality](https://arxiv.org/html/2503.07819)
- [Online 3DGS with Novel View Selection](https://arxiv.org/html/2508.14014)
- [FisherRF: Fisher Information for View Selection](https://arxiv.org/html/2503.07819)

### Mobile ML Optimization
- [CoreML vs TensorFlow Lite 2025](https://mbefe.com/blog/core-ml-vs-tensorflow-lite/)
- [Battery Usage of Deep Learning on iOS](https://dl.acm.org/doi/10.1145/3647632.3647990)
- [Mobile AI Frameworks Comparison](https://github.com/umitkacar/awesome-mobile-ai)

### Video Stabilization
- [SensorFlow: Sensor and Image Fused Stabilization (WACV 2025)](https://openaccess.thecvf.com/content/WACV2025/papers/Yu_SensorFlow_Sensor_and_Image_Fused_Video_Stabilization_WACV_2025_paper.pdf)
- [Real-time High-Frame-Rate Jitter Sensing](https://robomechjournal.springeropen.com/articles/10.1186/s40648-019-0144-z)

### Dynamic Object Detection
- [YOSO-SLAM: Real-Time Object Visual SLAM](https://link.springer.com/article/10.1007/s13369-025-10840-4)
- [DyGS-SLAM: Accurate Localization for Dynamic Scenes](https://openaccess.thecvf.com/content/ICCV2025/papers/Hu_DyGS-SLAM_Real-Time_Accurate_Localization_and_Gaussian_Reconstruction_for_Dynamic_Scenes_ICCV_2025_paper.pdf)

### ARKit Depth
- [ARKit Depth API Documentation](https://developer.apple.com/documentation/arkit/ardepthdata)
- [Prompt Depth Anything for 4K Depth (CVPR 2025)](https://openaccess.thecvf.com/content/CVPR2025/papers/Lin_Prompting_Depth_Anything_for_4K_Resolution_Accurate_Metric_Depth_Estimation_CVPR_2025_paper.pdf)

### Cross-Platform Swift
- [xtool: Cross-platform Xcode Replacement](https://github.com/xtool-org/xtool)
- [Apple Swift Build Open Source (2025)](https://alternativeto.net/news/2025/2/apple-open-sources-swift-build-xcode-s-build-engine-expanding-cross-platform-development/)
- [Swift SDKs for Cross-Compilation](https://www.polpiella.dev/swift-sdks)

---

**END OF PR5 IMPLEMENTATION PROMPT**
