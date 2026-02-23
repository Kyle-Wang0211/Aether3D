# PR5 Capture Optimization - Bulletproof Patch v1.0

**Version:** 1.0.0
**Status:** DRAFT
**Created:** 2026-02-03
**Scope:** Comprehensive hardening for PR5 Capture Optimization
**Dependencies:** PR2 (Evidence System), PR3 (Gate System), PR4 (Soft System)
**Research Basis:** NTIRE 2025, Taming 3DGS (SIGGRAPH Asia 2024), AirSLAM 2025, RecoFlow 2025

---

## EXECUTIVE SUMMARY

This patch addresses **65+ critical vulnerabilities** identified in the original PR5 implementation prompt. The hardening covers:

- **Architecture-level** boundaries and type safety
- **Capture state machine** for coordinated strategy execution
- **Enhanced frame quality** with reconstructability focus
- **Robust texture analysis** including repetitive pattern detection
- **Privacy-preserving** data minimization
- **Crash recovery** with journal-based persistence
- **Cross-platform determinism** with golden fixture validation

---

## PART 0: ARCHITECTURAL HARDENING

### 0.1 Control Plane vs Evidence Plane Boundary (CRITICAL)

**Problem:** PR5 capture control and evidence system boundaries are not enforced, allowing capture decisions to directly mutate ledger state.

**Solution:** Strict separation with type-level enforcement.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// CONTROL PLANE: Can only affect DELTA (current frame contribution)
// EVIDENCE PLANE: Only Observation protocol can update LEDGER
// ═══════════════════════════════════════════════════════════════════════════

/// Control Plane Output - CANNOT directly modify ledger
public struct CaptureControlOutput: Codable {
    /// Delta multiplier [0, 1] - how much this frame contributes
    public let deltaMultiplier: Double

    /// Frame disposition
    public let disposition: FrameDisposition

    /// Audit record (for debugging, not for evidence)
    public let auditRecord: CaptureDecisionRecord

    // INVARIANT: No ledger mutation capability
}

/// Frame Disposition - what happens to the frame
public enum FrameDisposition: String, Codable {
    case keepBoth           // Keep raw + assist
    case keepRawOnly        // Keep raw, discard assist
    case keepAssistOnly     // Keep assist for matching, discard raw (rare)
    case discardBoth        // Discard entirely
    case deferDecision      // Buffer for later decision
}

/// Capture Decision Record - audit only, no evidence mutation
public struct CaptureDecisionRecord: Codable {
    public let timestamp: Int64                    // Monotonic
    public let frameIndex: UInt64
    public let captureState: CaptureState
    public let exposureDecision: ExposureDecisionSummary
    public let qualityDecision: QualityDecisionSummary
    public let textureDecision: TextureDecisionSummary
    public let infoGainDecision: InfoGainDecisionSummary
    public let thermalState: ThermalState
    public let batteryState: BatteryState
    public let uploadBacklog: Int

    // CRITICAL: This record is for AUDIT ONLY
    // It CANNOT be used to derive evidence values
}
```

### 0.2 RawFrame / AssistFrame Type Safety (CRITICAL)

**Problem:** Engineering mistakes can "smuggle" assistFrame into training/rendering pipeline.

**Solution:** Strong type wrappers with compile-time enforcement.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// STRONG TYPE WRAPPERS - Prevent accidental misuse at compile time
// ═══════════════════════════════════════════════════════════════════════════

/// RawFrame - IMMUTABLE, used for training/rendering ONLY
/// Research: "rawFrame → Training/Rendering ledger (IMMUTABLE, tamper-proof)"
public struct RawFrame: ~Copyable {
    fileprivate let buffer: CVPixelBuffer
    public let metadata: RawFrameMetadata

    /// INVARIANT: Once created, buffer content CANNOT be modified
    public init(buffer: CVPixelBuffer, metadata: RawFrameMetadata) {
        self.buffer = buffer
        self.metadata = metadata

        // Lock buffer to prevent modification
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    /// Read-only access for training/rendering
    public func withReadOnlyAccess<T>(_ body: (CVPixelBuffer) throws -> T) rethrows -> T {
        return try body(buffer)
    }
}

/// AssistFrame - ENHANCEABLE, used for matching/pose ONLY
/// Research: "assistFrame → Matching/Pose only (enhanceable, NOT in ledger)"
public struct AssistFrame {
    fileprivate var buffer: CVPixelBuffer
    public let metadata: AssistFrameMetadata
    public let enhancementApplied: EnhancementRecord

    /// Pool management
    private static let bufferPool = AssistFrameBufferPool(capacity: 10, ttlSeconds: 5.0)

    /// Create from pool with TTL
    public static func create(
        from raw: borrowing RawFrame,
        enhancement: EnhancementParams?
    ) -> AssistFrame {
        let pooledBuffer = bufferPool.acquire()
        // Copy and optionally enhance
        // ...
        return AssistFrame(buffer: pooledBuffer, ...)
    }

    /// Return to pool on release
    public func release() {
        Self.bufferPool.release(buffer)
    }
}

/// FrameBundle - always carries both paths with clear separation
public struct FrameBundle {
    public let raw: RawFrame
    public let assist: AssistFrame
    public let frameId: FrameID
    public let captureTimestamp: MonotonicTimestamp

    // INVARIANT: Training/rendering consumers MUST use raw
    // INVARIANT: Matching/pose consumers MUST use assist
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPILE-TIME GATES - Prevent misuse at API boundaries
// ═══════════════════════════════════════════════════════════════════════════

/// Training Input - ONLY accepts RawFrame
public protocol TrainingInputProtocol {
    func submitForTraining(_ frame: borrowing RawFrame, pose: CameraPose)
}

/// Rendering Input - ONLY accepts RawFrame
public protocol RenderingInputProtocol {
    func submitForRendering(_ frame: borrowing RawFrame, pose: CameraPose)
}

/// Matching Input - ONLY accepts AssistFrame
public protocol MatchingInputProtocol {
    func extractFeatures(_ frame: borrowing AssistFrame) -> [Feature]
    func matchFeatures(_ frame: borrowing AssistFrame, against: [Feature]) -> [Match]
}

/// Pose Estimation Input - ONLY accepts AssistFrame
public protocol PoseEstimationInputProtocol {
    func estimatePose(_ frame: borrowing AssistFrame, matches: [Match]) -> CameraPose?
}
```

### 0.3 Cross-Platform Determinism Enforcement

**Problem:** iOS/Android/Web use different compute backends, producing different decisions for same input.

**Solution:** Pure logic core with platform adapters and golden fixture validation.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// PURE LOGIC CORE - No platform dependencies
// ═══════════════════════════════════════════════════════════════════════════

/// All decision logic in pure Swift, no platform imports
public enum PR5DecisionCore {

    /// Exposure decision - pure logic
    public static func computeExposureDecision(
        histogram: [Int],           // 256-bin
        centerLuminance: Double,
        flickerScore: Double,
        currentState: ExposureState,
        constants: ExposureConstants
    ) -> ExposureDecision {
        // Pure computation, no platform calls
        // ...
    }

    /// Frame quality decision - pure logic
    public static func computeQualityDecision(
        metrics: FrameQualityMetrics,
        coverageNeed: CoverageNeed,
        budgetState: BudgetState,
        constants: FrameQualityConstants
    ) -> FrameQualityDecision {
        // Pure computation, no platform calls
        // ...
    }

    /// Texture strength decision - pure logic
    public static func computeTextureDecision(
        featureCount: Int,
        spatialCoverage: Double,
        repetitionScore: Double,
        gradientStats: GradientStats,
        constants: TextureConstants
    ) -> TextureDecision {
        // Pure computation, no platform calls
        // ...
    }

    /// Information gain decision - pure logic
    public static func computeInfoGainDecision(
        noveltyFactors: NoveltyFactors,
        stabilityFactors: StabilityFactors,
        budgetState: KeyframeBudgetState,
        constants: InfoGainConstants
    ) -> InfoGainDecision {
        // Pure computation, no platform calls
        // ...
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// PLATFORM ADAPTERS - Extract metrics, feed to pure core
// ═══════════════════════════════════════════════════════════════════════════

/// Platform Adapter Protocol
public protocol PR5PlatformAdapterProtocol {
    /// Extract histogram from frame (platform-specific)
    func extractHistogram(_ frame: borrowing RawFrame) -> [Int]

    /// Extract features for matching (platform-specific)
    func extractFeatures(_ frame: borrowing AssistFrame) -> [Feature]

    /// Get IMU data (platform-specific)
    func getIMUData() -> IMUReading

    /// Get thermal state (platform-specific)
    func getThermalState() -> ThermalState
}

#if canImport(ARKit)
/// iOS Adapter - uses ARKit, CoreML, Metal
public final class iOSPlatformAdapter: PR5PlatformAdapterProtocol {
    // iOS-specific implementations
}
#endif

#if os(Linux)
/// Linux Adapter - uses pure Swift, swift-numerics
public final class LinuxPlatformAdapter: PR5PlatformAdapterProtocol {
    // Linux-specific implementations
}
#endif

// ═══════════════════════════════════════════════════════════════════════════
// GOLDEN FIXTURE VALIDATION - Ensure cross-platform consistency
// ═══════════════════════════════════════════════════════════════════════════

/// Golden fixture for determinism testing
public struct PR5GoldenFixture: Codable {
    public let fixtureVersion: String  // "pr5.golden.v1"
    public let input: PR5DecisionInput
    public let expectedOutput: PR5DecisionOutput

    /// Validate current implementation against golden
    public func validate() -> Bool {
        let actualOutput = PR5DecisionCore.computeAllDecisions(input)
        return actualOutput == expectedOutput
    }
}

/// Test: Same input → Same output on all platforms
final class PR5CrossPlatformDeterminismTests: XCTestCase {
    func testGoldenFixtureConsistency() throws {
        let fixtures = try loadGoldenFixtures()
        for fixture in fixtures {
            XCTAssertTrue(fixture.validate(), "Golden fixture mismatch: \(fixture.fixtureVersion)")
        }
    }
}
```

---

## PART 1: CAPTURE STATE MACHINE (NEW)

### 1.1 State Machine Design

**Problem:** Exposure, frame quality, texture, and information gain strategies can conflict. No coordination mechanism exists.

**Solution:** Unified 5-state capture state machine that coordinates all strategies.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// CAPTURE STATE MACHINE - Coordinates all capture strategies
// ═══════════════════════════════════════════════════════════════════════════

/// Capture States - mutually exclusive operational modes
public enum CaptureState: String, Codable {
    case normal           // Standard operation
    case lowLight         // Low light compensation active
    case weakTexture      // Weak texture handling active
    case highMotion       // High motion / stabilization mode
    case thermalThrottle  // Thermal throttling active
}

/// State Machine Constants
public enum CaptureStateMachineConstants {
    // MARK: - State Transition Thresholds

    /// Low light entry threshold (mean luminance)
    public static let LOW_LIGHT_ENTRY_THRESHOLD: Double = 0.15
    /// Low light exit threshold (with hysteresis)
    public static let LOW_LIGHT_EXIT_THRESHOLD: Double = 0.25

    /// Weak texture entry threshold (feature count)
    public static let WEAK_TEXTURE_ENTRY_THRESHOLD: Int = 80
    /// Weak texture exit threshold (with hysteresis)
    public static let WEAK_TEXTURE_EXIT_THRESHOLD: Int = 120

    /// High motion entry threshold (angular velocity rad/s)
    public static let HIGH_MOTION_ENTRY_THRESHOLD: Double = 0.8
    /// High motion exit threshold (with hysteresis)
    public static let HIGH_MOTION_EXIT_THRESHOLD: Double = 0.4

    /// Thermal throttle entry (ProcessInfo.ThermalState)
    public static let THERMAL_THROTTLE_ENTRY: Int = 2  // .serious
    /// Thermal throttle exit
    public static let THERMAL_THROTTLE_EXIT: Int = 1   // .fair

    // MARK: - State Transition Timing

    /// Minimum time in state before transition (ms)
    public static let MIN_STATE_DURATION_MS: Int64 = 500

    /// Confirmation frames before transition
    public static let TRANSITION_CONFIRMATION_FRAMES: Int = 5

    // MARK: - State Priority (higher = more urgent)

    public static let PRIORITY_NORMAL: Int = 0
    public static let PRIORITY_WEAK_TEXTURE: Int = 1
    public static let PRIORITY_LOW_LIGHT: Int = 2
    public static let PRIORITY_HIGH_MOTION: Int = 3
    public static let PRIORITY_THERMAL_THROTTLE: Int = 4  // Highest - safety
}

/// State-Specific Strategy Configuration
public struct CaptureStateConfig: Codable {
    // Exposure strategy
    public let exposureLockMode: ExposureLockMode
    public let torchPolicy: TorchPolicy
    public let maxISOMultiplier: Double

    // Frame quality strategy
    public let qualityThresholdMultiplier: Double
    public let dropFramePolicy: DropFramePolicy

    // Assist enhancement strategy
    public let assistEnhancementLevel: AssistEnhancementLevel
    public let enhancementBudgetMs: Double

    // Information gain strategy
    public let keyframeBudgetMultiplier: Double
    public let noveltyWeightMultiplier: Double
    public let stabilityWeightMultiplier: Double

    // Compute budget
    public let heavyMetricsFrequency: Int  // Every N frames
    public let featureExtractionBudgetMs: Double
}

/// Predefined State Configurations
public enum CaptureStateConfigs {

    public static let normal = CaptureStateConfig(
        exposureLockMode: .locked,
        torchPolicy: .off,
        maxISOMultiplier: 1.0,
        qualityThresholdMultiplier: 1.0,
        dropFramePolicy: .standard,
        assistEnhancementLevel: .off,
        enhancementBudgetMs: 0.0,
        keyframeBudgetMultiplier: 1.0,
        noveltyWeightMultiplier: 1.0,
        stabilityWeightMultiplier: 1.0,
        heavyMetricsFrequency: 5,
        featureExtractionBudgetMs: 8.0
    )

    public static let lowLight = CaptureStateConfig(
        exposureLockMode: .adaptiveSlow,
        torchPolicy: .autoLow,
        maxISOMultiplier: 2.0,
        qualityThresholdMultiplier: 0.8,  // More lenient
        dropFramePolicy: .conservative,
        assistEnhancementLevel: .moderate,
        enhancementBudgetMs: 3.0,
        keyframeBudgetMultiplier: 0.8,    // Fewer keyframes
        noveltyWeightMultiplier: 0.8,
        stabilityWeightMultiplier: 1.2,   // Prioritize stability
        heavyMetricsFrequency: 8,         // Less frequent
        featureExtractionBudgetMs: 10.0
    )

    public static let weakTexture = CaptureStateConfig(
        exposureLockMode: .locked,
        torchPolicy: .off,
        maxISOMultiplier: 1.0,
        qualityThresholdMultiplier: 0.9,
        dropFramePolicy: .conservative,
        assistEnhancementLevel: .mild,
        enhancementBudgetMs: 2.0,
        keyframeBudgetMultiplier: 1.2,    // More keyframes for coverage
        noveltyWeightMultiplier: 1.2,     // Encourage diverse angles
        stabilityWeightMultiplier: 1.0,
        heavyMetricsFrequency: 3,         // More frequent texture checks
        featureExtractionBudgetMs: 10.0
    )

    public static let highMotion = CaptureStateConfig(
        exposureLockMode: .locked,
        torchPolicy: .off,
        maxISOMultiplier: 1.0,
        qualityThresholdMultiplier: 1.2,  // Stricter
        dropFramePolicy: .aggressive,
        assistEnhancementLevel: .off,     // No enhancement during motion
        enhancementBudgetMs: 0.0,
        keyframeBudgetMultiplier: 0.5,    // Fewer keyframes
        noveltyWeightMultiplier: 0.5,
        stabilityWeightMultiplier: 2.0,   // Heavy stability emphasis
        heavyMetricsFrequency: 10,
        featureExtractionBudgetMs: 5.0    // Faster extraction
    )

    public static let thermalThrottle = CaptureStateConfig(
        exposureLockMode: .locked,
        torchPolicy: .off,                // No torch to reduce heat
        maxISOMultiplier: 1.0,
        qualityThresholdMultiplier: 0.7,  // Very lenient
        dropFramePolicy: .aggressive,
        assistEnhancementLevel: .off,
        enhancementBudgetMs: 0.0,
        keyframeBudgetMultiplier: 0.3,    // Minimal keyframes
        noveltyWeightMultiplier: 0.5,
        stabilityWeightMultiplier: 1.0,
        heavyMetricsFrequency: 15,        // Minimal computation
        featureExtractionBudgetMs: 3.0
    )

    public static func config(for state: CaptureState) -> CaptureStateConfig {
        switch state {
        case .normal: return normal
        case .lowLight: return lowLight
        case .weakTexture: return weakTexture
        case .highMotion: return highMotion
        case .thermalThrottle: return thermalThrottle
        }
    }
}

/// Capture State Machine Implementation
public final class CaptureStateMachine {

    // MARK: - State

    private var currentState: CaptureState = .normal
    private var stateEntryTimestamp: MonotonicTimestamp
    private var transitionConfirmationCount: Int = 0
    private var pendingTransition: CaptureState?

    private let clockProvider: MonotonicClockProvider
    private let stateLock = NSLock()

    // MARK: - Public Interface

    public var state: CaptureState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    public var config: CaptureStateConfig {
        return CaptureStateConfigs.config(for: state)
    }

    /// Update state machine with current metrics
    public func update(metrics: CaptureMetrics) -> StateTransitionRecord? {
        stateLock.lock()
        defer { stateLock.unlock() }

        // Determine target state based on metrics and priority
        let targetState = determineTargetState(metrics)

        // Check if transition is needed
        if targetState != currentState {
            return handlePotentialTransition(to: targetState, metrics: metrics)
        } else {
            // Reset confirmation if staying in current state
            pendingTransition = nil
            transitionConfirmationCount = 0
            return nil
        }
    }

    // MARK: - Private

    private func determineTargetState(_ metrics: CaptureMetrics) -> CaptureState {
        // Priority-based state determination (highest priority wins)

        // Priority 4: Thermal throttle (safety)
        if metrics.thermalState.rawValue >= CaptureStateMachineConstants.THERMAL_THROTTLE_ENTRY {
            return .thermalThrottle
        }

        // Priority 3: High motion
        if metrics.angularVelocityMagnitude > CaptureStateMachineConstants.HIGH_MOTION_ENTRY_THRESHOLD {
            return .highMotion
        }

        // Priority 2: Low light
        if metrics.meanLuminance < CaptureStateMachineConstants.LOW_LIGHT_ENTRY_THRESHOLD {
            return .lowLight
        }

        // Priority 1: Weak texture
        if metrics.featureCount < CaptureStateMachineConstants.WEAK_TEXTURE_ENTRY_THRESHOLD {
            return .weakTexture
        }

        // Check exit conditions with hysteresis
        if currentState == .thermalThrottle &&
           metrics.thermalState.rawValue <= CaptureStateMachineConstants.THERMAL_THROTTLE_EXIT {
            return .normal
        }

        if currentState == .highMotion &&
           metrics.angularVelocityMagnitude < CaptureStateMachineConstants.HIGH_MOTION_EXIT_THRESHOLD {
            return .normal
        }

        if currentState == .lowLight &&
           metrics.meanLuminance > CaptureStateMachineConstants.LOW_LIGHT_EXIT_THRESHOLD {
            return .normal
        }

        if currentState == .weakTexture &&
           metrics.featureCount > CaptureStateMachineConstants.WEAK_TEXTURE_EXIT_THRESHOLD {
            return .normal
        }

        // Default: stay in current state
        return currentState
    }

    private func handlePotentialTransition(
        to targetState: CaptureState,
        metrics: CaptureMetrics
    ) -> StateTransitionRecord? {
        let now = clockProvider.now()

        // Check minimum state duration
        let durationInState = now.millisecondsSince(stateEntryTimestamp)
        if durationInState < CaptureStateMachineConstants.MIN_STATE_DURATION_MS {
            return nil  // Too soon to transition
        }

        // Confirmation logic
        if pendingTransition == targetState {
            transitionConfirmationCount += 1
        } else {
            pendingTransition = targetState
            transitionConfirmationCount = 1
        }

        // Check confirmation threshold
        if transitionConfirmationCount >= CaptureStateMachineConstants.TRANSITION_CONFIRMATION_FRAMES {
            let record = StateTransitionRecord(
                from: currentState,
                to: targetState,
                timestamp: now,
                triggerMetrics: metrics
            )

            currentState = targetState
            stateEntryTimestamp = now
            pendingTransition = nil
            transitionConfirmationCount = 0

            return record
        }

        return nil
    }
}

/// State Transition Record - for audit
public struct StateTransitionRecord: Codable {
    public let from: CaptureState
    public let to: CaptureState
    public let timestamp: MonotonicTimestamp
    public let triggerMetrics: CaptureMetrics
}
```

---

## PART 2: EXPOSURE CONTROL HARDENING

### 2.1 Exposure Anchor System

**Problem:** Auto-exposure causes color drift, breaking "color gets brighter" philosophy.

**Solution:** Anchor-based exposure with bounded drift.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// EXPOSURE ANCHOR SYSTEM - Prevent color drift
// ═══════════════════════════════════════════════════════════════════════════

/// Exposure Anchor - baseline locked at session start
public struct ExposureAnchor: Codable {
    public let iso: Float
    public let exposureDuration: Double
    public let whiteBalance: WhiteBalanceGains
    public let anchorTimestamp: MonotonicTimestamp

    /// Maximum allowed drift from anchor
    public static let MAX_ISO_DRIFT_RATIO: Float = 0.2       // ±20%
    public static let MAX_EXPOSURE_DRIFT_RATIO: Double = 0.15 // ±15%
    public static let MAX_WB_DRIFT: Float = 0.1              // ±10%
}

/// Exposure Controller with Anchor
public final class AnchoredExposureController {

    private var anchor: ExposureAnchor?
    private var currentExposure: ExposureSettings
    private let stateLock = NSLock()

    /// Lock exposure anchor (call at session start after stabilization)
    public func lockAnchor() {
        stateLock.lock()
        defer { stateLock.unlock() }

        anchor = ExposureAnchor(
            iso: currentExposure.iso,
            exposureDuration: currentExposure.duration,
            whiteBalance: currentExposure.whiteBalance,
            anchorTimestamp: MonotonicClock.now()
        )
    }

    /// Compute bounded exposure adjustment
    public func computeBoundedAdjustment(
        targetExposure: ExposureSettings
    ) -> ExposureSettings {
        guard let anchor = anchor else {
            return targetExposure  // No anchor yet
        }

        // Bound ISO drift
        let minISO = anchor.iso * (1.0 - ExposureAnchor.MAX_ISO_DRIFT_RATIO)
        let maxISO = anchor.iso * (1.0 + ExposureAnchor.MAX_ISO_DRIFT_RATIO)
        let boundedISO = min(maxISO, max(minISO, targetExposure.iso))

        // Bound exposure duration drift
        let minDuration = anchor.exposureDuration * (1.0 - ExposureAnchor.MAX_EXPOSURE_DRIFT_RATIO)
        let maxDuration = anchor.exposureDuration * (1.0 + ExposureAnchor.MAX_EXPOSURE_DRIFT_RATIO)
        let boundedDuration = min(maxDuration, max(minDuration, targetExposure.duration))

        // Bound white balance drift
        let boundedWB = boundWhiteBalance(targetExposure.whiteBalance, to: anchor.whiteBalance)

        return ExposureSettings(
            iso: boundedISO,
            duration: boundedDuration,
            whiteBalance: boundedWB
        )
    }
}
```

### 2.2 Flicker Detection and Mitigation

**Problem:** Indoor LED/fluorescent flicker causes banding artifacts.

**Solution:** Frequency detection with anti-banding shutter constraints.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// FLICKER DETECTION - Detect 50Hz/60Hz light flicker
// ═══════════════════════════════════════════════════════════════════════════

/// Flicker Detection Constants
public enum FlickerConstants {
    /// Flicker detection window (frames)
    public static let DETECTION_WINDOW_FRAMES: Int = 30

    /// Minimum periodicity confidence to declare flicker
    public static let PERIODICITY_CONFIDENCE_THRESHOLD: Double = 0.7

    /// 50Hz safe shutter speeds (seconds)
    public static let SAFE_SHUTTERS_50HZ: [Double] = [1.0/100, 1.0/50, 1.0/25]

    /// 60Hz safe shutter speeds (seconds)
    public static let SAFE_SHUTTERS_60HZ: [Double] = [1.0/120, 1.0/60, 1.0/30]

    /// Maximum brightness variance for stability (after anti-banding)
    public static let MAX_BRIGHTNESS_VARIANCE_STABLE: Double = 0.02
}

/// Flicker Detector
public final class FlickerDetector {

    private var luminanceHistory: RingBuffer<Double>
    private var detectedFrequency: FlickerFrequency = .unknown
    private var confidence: Double = 0.0

    public enum FlickerFrequency: String, Codable {
        case hz50 = "50Hz"
        case hz60 = "60Hz"
        case unknown = "unknown"
        case none = "none"  // No flicker detected
    }

    /// Analyze frame for flicker
    public func analyzeFrame(meanLuminance: Double, frameTimestamp: Double) {
        luminanceHistory.push(meanLuminance)

        guard luminanceHistory.isFull else { return }

        // Compute autocorrelation to detect periodicity
        let (frequency, conf) = detectPeriodicity(luminanceHistory.toArray())

        if conf > FlickerConstants.PERIODICITY_CONFIDENCE_THRESHOLD {
            detectedFrequency = frequency
            confidence = conf
        }
    }

    /// Get recommended shutter speeds for anti-banding
    public func getAntiFlickerShutters() -> [Double] {
        switch detectedFrequency {
        case .hz50: return FlickerConstants.SAFE_SHUTTERS_50HZ
        case .hz60: return FlickerConstants.SAFE_SHUTTERS_60HZ
        case .unknown, .none: return []  // No constraint
        }
    }

    private func detectPeriodicity(_ samples: [Double]) -> (FlickerFrequency, Double) {
        // Compute FFT or autocorrelation
        // Look for peaks at 50Hz and 60Hz (accounting for frame rate)
        // Return detected frequency and confidence
        // ...
        return (.unknown, 0.0)
    }
}
```

### 2.3 White Balance Drift Detection

**Problem:** White balance drift can be mistaken for "color getting brighter."

**Solution:** Chromaticity normalization for evidence calculation.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// WHITE BALANCE DRIFT DETECTION - Prevent false positive "brightening"
// ═══════════════════════════════════════════════════════════════════════════

/// White Balance Drift Constants
public enum WBDriftConstants {
    /// Maximum chromaticity shift before flagging
    public static let MAX_CHROMATICITY_SHIFT: Double = 0.05

    /// Reference patch sampling grid
    public static let REFERENCE_PATCH_GRID_SIZE: Int = 4

    /// Delta penalty for high WB drift
    public static let HIGH_WB_DRIFT_DELTA_PENALTY: Double = 0.3
}

/// White Balance Drift Detector
public struct WBDriftDetector {

    private var anchorChromaticity: Chromaticity?

    /// Chromaticity representation (u', v' CIE 1976)
    public struct Chromaticity: Codable {
        public let u: Double  // u' coordinate
        public let v: Double  // v' coordinate
    }

    /// Lock anchor chromaticity at session start
    public mutating func lockAnchor(from frame: borrowing RawFrame) {
        anchorChromaticity = computeAverageChromaticity(frame)
    }

    /// Compute drift score [0, 1] - higher = more drift
    public func computeDriftScore(from frame: borrowing RawFrame) -> Double {
        guard let anchor = anchorChromaticity else { return 0.0 }

        let current = computeAverageChromaticity(frame)
        let distance = sqrt(pow(current.u - anchor.u, 2) + pow(current.v - anchor.v, 2))

        // Normalize to [0, 1]
        return min(1.0, distance / (WBDriftConstants.MAX_CHROMATICITY_SHIFT * 2))
    }

    private func computeAverageChromaticity(_ frame: borrowing RawFrame) -> Chromaticity {
        // Sample reference patches and compute average chromaticity
        // ...
        return Chromaticity(u: 0.0, v: 0.0)
    }
}
```

---

## PART 3: FRAME QUALITY HARDENING

### 3.1 Reconstructability-First Quality Metric

**Problem:** Current quality metric focuses on visual sharpness, not actual reconstructability.

**Solution:** Reconstructability-focused quality with tracking success weight.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// RECONSTRUCTABILITY QUALITY - Focus on what matters for 3DGS training
// ═══════════════════════════════════════════════════════════════════════════

/// Reconstructability Quality Constants
public enum ReconstructabilityConstants {
    // MARK: - Weight Distribution

    /// Feature tracking success weight (most important)
    public static let WEIGHT_FEATURE_TRACKING: Double = 0.30

    /// Motion blur weight
    public static let WEIGHT_MOTION_BLUR: Double = 0.20

    /// Rolling shutter distortion weight
    public static let WEIGHT_ROLLING_SHUTTER: Double = 0.15

    /// Parallax quality weight
    public static let WEIGHT_PARALLAX: Double = 0.15

    /// Reprojection proxy weight
    public static let WEIGHT_REPROJ_PROXY: Double = 0.10

    /// Visual sharpness weight (least important)
    public static let WEIGHT_VISUAL_SHARPNESS: Double = 0.10

    // MARK: - Thresholds

    /// Minimum feature track length for good tracking
    public static let MIN_FEATURE_TRACK_LENGTH: Int = 5

    /// Maximum motion blur indicator
    public static let MAX_MOTION_BLUR_INDICATOR: Double = 0.3

    /// Maximum rolling shutter skew (pixels)
    public static let MAX_ROLLING_SHUTTER_SKEW_PX: Double = 5.0
}

/// Reconstructability Quality Metrics
public struct ReconstructabilityMetrics: Codable {
    /// Feature tracking success rate [0, 1]
    public let featureTrackingRate: Double

    /// Motion blur indicator [0, 1] (0 = sharp, 1 = severe blur)
    public let motionBlurIndicator: Double

    /// Rolling shutter distortion [0, 1]
    public let rollingShutterDistortion: Double

    /// Parallax quality [0, 1] (0 = no parallax, 1 = good parallax)
    public let parallaxQuality: Double

    /// Reprojection error proxy [0, 1] (0 = low error, 1 = high error)
    public let reprojErrorProxy: Double

    /// Visual sharpness [0, 1]
    public let visualSharpness: Double

    /// Compute weighted reconstructability score
    public var reconstructabilityScore: Double {
        let C = ReconstructabilityConstants.self

        // Feature tracking (higher = better)
        let trackingTerm = C.WEIGHT_FEATURE_TRACKING * featureTrackingRate

        // Motion blur (lower indicator = better)
        let blurTerm = C.WEIGHT_MOTION_BLUR * (1.0 - motionBlurIndicator)

        // Rolling shutter (lower = better)
        let rsTerm = C.WEIGHT_ROLLING_SHUTTER * (1.0 - rollingShutterDistortion)

        // Parallax (higher = better)
        let parallaxTerm = C.WEIGHT_PARALLAX * parallaxQuality

        // Reproj error (lower = better)
        let reprojTerm = C.WEIGHT_REPROJ_PROXY * (1.0 - reprojErrorProxy)

        // Sharpness (higher = better)
        let sharpTerm = C.WEIGHT_VISUAL_SHARPNESS * visualSharpness

        return trackingTerm + blurTerm + rsTerm + parallaxTerm + reprojTerm + sharpTerm
    }
}

/// Motion Blur Detector
public struct MotionBlurDetector {

    /// Detect motion blur from IMU and visual cues
    public static func detectMotionBlur(
        angularVelocity: SIMD3<Double>,
        linearAcceleration: SIMD3<Double>,
        exposureDuration: Double,
        edgeStrength: Double
    ) -> Double {
        // Angular motion during exposure
        let angularMagnitude = simd_length(angularVelocity)
        let angularBlur = angularMagnitude * exposureDuration

        // Linear motion during exposure (requires depth estimate)
        let linearMagnitude = simd_length(linearAcceleration)
        let linearBlur = linearMagnitude * exposureDuration * exposureDuration * 0.5

        // Edge strength indicates blur (weak edges = blur)
        let edgeBlurIndicator = 1.0 - min(1.0, edgeStrength)

        // Combine indicators
        let combinedBlur = max(angularBlur * 10.0, linearBlur * 5.0, edgeBlurIndicator)

        return min(1.0, combinedBlur)
    }
}
```

### 3.2 Dynamic Object Detection

**Problem:** Dynamic objects (people, cars) entering frame can corrupt ledger.

**Solution:** Dynamic region scoring with conservative ledger update.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// DYNAMIC OBJECT DETECTION - Prevent ledger corruption from moving objects
// Research: DynaSLAM, YOSO-SLAM (2025)
// ═══════════════════════════════════════════════════════════════════════════

/// Dynamic Region Constants
public enum DynamicRegionConstants {
    /// Optical flow magnitude threshold for dynamic detection
    public static let FLOW_MAGNITUDE_THRESHOLD: Double = 5.0  // pixels

    /// Minimum region size to consider (% of frame)
    public static let MIN_REGION_SIZE_RATIO: Double = 0.01

    /// Segmentation consistency threshold
    public static let SEGMENTATION_CONSISTENCY_THRESHOLD: Double = 0.8

    /// Delta penalty for frames with dynamic regions
    public static let DYNAMIC_REGION_DELTA_PENALTY: Double = 0.5

    /// Ledger update delay for patches near dynamic regions (frames)
    public static let LEDGER_UPDATE_DELAY_FRAMES: Int = 10
}

/// Dynamic Region Score
public struct DynamicRegionScore: Codable {
    /// Overall dynamic region ratio [0, 1]
    public let dynamicRatio: Double

    /// Per-patch dynamic flags
    public let dynamicPatches: Set<String>

    /// Confidence in detection [0, 1]
    public let confidence: Double

    /// Whether frame should update ledger normally
    public var shouldUpdateLedgerNormally: Bool {
        return dynamicRatio < 0.1 && confidence > 0.7
    }

    /// Patches that should delay ledger update
    public var patchesToDelay: Set<String> {
        return dynamicPatches
    }
}

/// Dynamic Region Detector
public final class DynamicRegionDetector {

    private var previousFeatures: [Feature] = []
    private var flowHistory: RingBuffer<[FlowVector]>

    /// Detect dynamic regions from optical flow anomalies
    public func detectDynamicRegions(
        currentFeatures: [Feature],
        cameraMotion: CameraMotion
    ) -> DynamicRegionScore {
        guard !previousFeatures.isEmpty else {
            previousFeatures = currentFeatures
            return DynamicRegionScore(dynamicRatio: 0.0, dynamicPatches: [], confidence: 0.0)
        }

        // Compute expected flow from camera motion
        let expectedFlow = computeExpectedFlow(cameraMotion: cameraMotion)

        // Find flow outliers (moving independently of camera)
        var dynamicPatches = Set<String>()
        var outlierCount = 0

        for (prev, curr) in zip(previousFeatures, currentFeatures) {
            let actualFlow = FlowVector(dx: curr.x - prev.x, dy: curr.y - prev.y)
            let expected = expectedFlow.at(prev.x, prev.y)

            let residual = simd_length(SIMD2<Double>(
                actualFlow.dx - expected.dx,
                actualFlow.dy - expected.dy
            ))

            if residual > DynamicRegionConstants.FLOW_MAGNITUDE_THRESHOLD {
                outlierCount += 1
                dynamicPatches.insert(patchIdAt(curr.x, curr.y))
            }
        }

        let dynamicRatio = Double(outlierCount) / Double(currentFeatures.count)

        previousFeatures = currentFeatures

        return DynamicRegionScore(
            dynamicRatio: dynamicRatio,
            dynamicPatches: dynamicPatches,
            confidence: currentFeatures.count > 50 ? 0.9 : 0.5
        )
    }

    private func computeExpectedFlow(cameraMotion: CameraMotion) -> FlowField {
        // Compute expected optical flow from camera motion + depth
        // ...
        return FlowField()
    }
}
```

### 3.3 Budget-Aware Frame Retention

**Problem:** Frame quality decisions don't consider thermal, battery, or upload pressure.

**Solution:** Budget-aware retention with graceful degradation.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// BUDGET-AWARE FRAME RETENTION - Consider system constraints
// ═══════════════════════════════════════════════════════════════════════════

/// System Budget State
public struct SystemBudgetState: Codable {
    /// Thermal state (0=nominal, 1=fair, 2=serious, 3=critical)
    public let thermalState: Int

    /// Battery level [0, 1]
    public let batteryLevel: Double

    /// Is charging?
    public let isCharging: Bool

    /// Upload backlog (bytes)
    public let uploadBacklogBytes: Int

    /// Memory pressure (0=normal, 1=warning, 2=critical)
    public let memoryPressure: Int

    /// Available storage (bytes)
    public let availableStorageBytes: Int

    /// Compute overall budget factor [0, 1] - lower = more constrained
    public var budgetFactor: Double {
        var factor = 1.0

        // Thermal penalty
        factor *= [1.0, 0.9, 0.6, 0.3][min(3, thermalState)]

        // Battery penalty (if not charging)
        if !isCharging {
            if batteryLevel < 0.1 { factor *= 0.3 }
            else if batteryLevel < 0.2 { factor *= 0.6 }
            else if batteryLevel < 0.3 { factor *= 0.8 }
        }

        // Upload backlog penalty
        let backlogMB = Double(uploadBacklogBytes) / (1024 * 1024)
        if backlogMB > 500 { factor *= 0.5 }
        else if backlogMB > 200 { factor *= 0.7 }
        else if backlogMB > 100 { factor *= 0.9 }

        // Memory pressure penalty
        factor *= [1.0, 0.7, 0.4][min(2, memoryPressure)]

        return factor
    }
}

/// Budget-Aware Frame Retainer
public struct BudgetAwareRetainer {

    /// Decide frame retention based on quality and budget
    public static func decideRetention(
        qualityScore: Double,
        noveltyScore: Double,
        budget: SystemBudgetState,
        captureState: CaptureState
    ) -> FrameRetentionDecision {

        let config = CaptureStateConfigs.config(for: captureState)
        let effectiveBudget = budget.budgetFactor

        // Adjust quality threshold based on budget
        let adjustedThreshold = config.qualityThresholdMultiplier / effectiveBudget

        // High quality + high novelty: always keep
        if qualityScore > 0.8 && noveltyScore > 0.5 {
            return .keepBoth(priority: .high)
        }

        // Good quality: keep based on budget
        if qualityScore > adjustedThreshold {
            if effectiveBudget > 0.7 {
                return .keepBoth(priority: .normal)
            } else {
                return .keepRawOnly(priority: .normal)  // Skip assist to save compute
            }
        }

        // Marginal quality: keep only if needed for coverage and budget allows
        if qualityScore > adjustedThreshold * 0.7 && noveltyScore > 0.7 {
            if effectiveBudget > 0.5 {
                return .keepRawOnly(priority: .low)
            }
        }

        // Low quality or low budget: discard
        return .discard(reason: effectiveBudget < 0.5 ? .budgetConstraint : .lowQuality)
    }
}

/// Frame Retention Decision
public enum FrameRetentionDecision: Codable {
    case keepBoth(priority: Priority)
    case keepRawOnly(priority: Priority)
    case keepAssistOnly(priority: Priority)
    case discard(reason: DiscardReason)

    public enum Priority: String, Codable {
        case high, normal, low
    }

    public enum DiscardReason: String, Codable {
        case lowQuality
        case redundant
        case budgetConstraint
        case dynamicContent
    }
}
```

---

## PART 4: TEXTURE ANALYSIS HARDENING

### 4.1 Multi-Dimensional Texture Analysis

**Problem:** Current texture analysis only uses gradient mean, missing structural edges and repetition patterns.

**Solution:** Three-component texture analysis.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// MULTI-DIMENSIONAL TEXTURE ANALYSIS
// Research: PLFG-SLAM (2025), GroundSLAM (2025)
// ═══════════════════════════════════════════════════════════════════════════

/// Texture Analysis Constants
public enum TextureAnalysisConstants {
    // MARK: - Micro Texture (fine detail)

    public static let MICRO_TEXTURE_STRONG_THRESHOLD: Double = 0.6
    public static let MICRO_TEXTURE_WEAK_THRESHOLD: Double = 0.3

    // MARK: - Structural Edges

    public static let STRUCTURAL_EDGE_MIN_LENGTH_PX: Int = 20
    public static let STRUCTURAL_EDGE_DENSITY_THRESHOLD: Double = 0.1

    // MARK: - Repetitive Pattern (危险信号)

    /// Autocorrelation peak threshold for repetition detection
    public static let REPETITION_AUTOCORR_PEAK_THRESHOLD: Double = 0.7

    /// FFT peak ratio threshold
    public static let REPETITION_FFT_PEAK_RATIO: Double = 3.0

    /// Maximum safe repetition score before warning
    public static let MAX_SAFE_REPETITION_SCORE: Double = 0.4
}

/// Three-Component Texture Analysis Result
public struct TextureAnalysisResult: Codable {
    /// Micro texture strength [0, 1] - fine detail richness
    public let microTextureStrength: Double

    /// Structural edge density [0, 1] - strong geometric edges
    public let structuralEdgeDensity: Double

    /// Repetition risk score [0, 1] - DANGER: high = drift risk
    /// Research: Repetitive textures are primary cause of SLAM drift
    public let repetitionRiskScore: Double

    /// Overall texture quality for SLAM
    public var slamTextureQuality: Double {
        // High repetition is very bad, even if texture looks "rich"
        let repetitionPenalty = repetitionRiskScore > TextureAnalysisConstants.MAX_SAFE_REPETITION_SCORE
            ? 0.5
            : 1.0 - repetitionRiskScore * 0.3

        // Combined score
        return (microTextureStrength * 0.4 + structuralEdgeDensity * 0.6) * repetitionPenalty
    }

    /// Recommended assist enhancement strategy
    public var recommendedEnhancement: AssistEnhancementStrategy {
        // High repetition: do NOT enhance (will amplify ambiguity)
        if repetitionRiskScore > TextureAnalysisConstants.MAX_SAFE_REPETITION_SCORE {
            return .none
        }

        // Weak micro texture: mild enhancement
        if microTextureStrength < TextureAnalysisConstants.MICRO_TEXTURE_WEAK_THRESHOLD {
            return .mild
        }

        // Weak structural edges: moderate enhancement
        if structuralEdgeDensity < TextureAnalysisConstants.STRUCTURAL_EDGE_DENSITY_THRESHOLD {
            return .moderate
        }

        return .none
    }
}

/// Assist Enhancement Strategy
public enum AssistEnhancementStrategy: String, Codable {
    case none      // No enhancement
    case mild      // Light unsharp mask only
    case moderate  // Unsharp + CLAHE
}

/// Repetition Pattern Detector
/// Research: GroundSLAM (2025) - KCC for repetitive patterns
public struct RepetitionPatternDetector {

    /// Detect repetitive patterns using autocorrelation
    public static func detectRepetition(
        grayImage: [[UInt8]],
        patchSize: Int = 64
    ) -> Double {
        // Sample patches across image
        var maxRepetitionScore: Double = 0.0

        // Compute autocorrelation for each patch
        // Look for secondary peaks (indicates repetition)

        // Also check FFT for strong periodic components
        let fftPeaks = computeFFTPeaks(grayImage)
        let fftRepetition = evaluateFFTPeaks(fftPeaks)

        return max(maxRepetitionScore, fftRepetition)
    }

    private static func computeFFTPeaks(_ image: [[UInt8]]) -> [FFTPeak] {
        // 2D FFT and peak detection
        // ...
        return []
    }

    private static func evaluateFFTPeaks(_ peaks: [FFTPeak]) -> Double {
        // Strong secondary peaks indicate repetitive pattern
        // ...
        return 0.0
    }
}
```

### 4.2 Specular/Transparent Surface Detection

**Problem:** Specular and transparent surfaces cause depth estimation failure and false texture readings.

**Research Basis:** [NTIRE 2025 Challenge on HR Depth from Specular and Transparent Surfaces](https://arxiv.org/html/2506.05815)

```swift
// ═══════════════════════════════════════════════════════════════════════════
// SPECULAR/TRANSPARENT SURFACE DETECTION
// Research: NTIRE 2025 Challenge, Mirror3DNet
// ═══════════════════════════════════════════════════════════════════════════

/// Specular/Transparent Detection Constants
public enum SpecularTransparentConstants {
    /// Specular highlight detection threshold
    public static let SPECULAR_HIGHLIGHT_THRESHOLD: UInt8 = 250

    /// Minimum specular region size (pixels)
    public static let MIN_SPECULAR_REGION_SIZE: Int = 100

    /// Depth confidence threshold for transparent detection
    public static let TRANSPARENT_DEPTH_CONFIDENCE_THRESHOLD: Double = 0.3

    /// Maximum specular ratio before capping texture strength
    public static let MAX_SPECULAR_RATIO_FOR_TEXTURE: Double = 0.15

    /// Delta penalty for high specular/transparent content
    public static let SPECULAR_DELTA_PENALTY: Double = 0.4
}

/// Specular/Transparent Analysis Result
public struct SpecularTransparentResult: Codable {
    /// Specular region ratio [0, 1]
    public let specularRatio: Double

    /// Transparent region ratio [0, 1]
    public let transparentRatio: Double

    /// Combined problematic ratio
    public var problematicRatio: Double {
        return min(1.0, specularRatio + transparentRatio)
    }

    /// Whether texture strength should be capped
    public var shouldCapTextureStrength: Bool {
        return problematicRatio > SpecularTransparentConstants.MAX_SPECULAR_RATIO_FOR_TEXTURE
    }

    /// Capped texture strength multiplier
    public var textureStrengthCap: Double {
        if problematicRatio > 0.3 { return 0.3 }
        if problematicRatio > 0.2 { return 0.5 }
        if problematicRatio > 0.1 { return 0.7 }
        return 1.0
    }
}

/// Specular/Transparent Detector
public struct SpecularTransparentDetector {

    /// Detect specular and transparent regions
    public static func detect(
        rgbFrame: borrowing RawFrame,
        depthConfidence: [[Float]]?
    ) -> SpecularTransparentResult {

        // Detect specular highlights (very bright + low saturation)
        let specularMask = detectSpecularHighlights(rgbFrame)
        let specularRatio = computeMaskRatio(specularMask)

        // Detect transparent regions (depth confidence drop)
        var transparentRatio = 0.0
        if let confidence = depthConfidence {
            let transparentMask = detectLowConfidenceRegions(confidence)
            transparentRatio = computeMaskRatio(transparentMask)
        }

        return SpecularTransparentResult(
            specularRatio: specularRatio,
            transparentRatio: transparentRatio
        )
    }

    private static func detectSpecularHighlights(_ frame: borrowing RawFrame) -> [[Bool]] {
        // Detect pixels with:
        // - Very high luminance (>250)
        // - Low saturation (white highlights)
        // ...
        return []
    }

    private static func detectLowConfidenceRegions(_ confidence: [[Float]]) -> [[Bool]] {
        // Detect regions where depth confidence is very low
        // (typically indicates transparent/reflective surfaces)
        // ...
        return []
    }
}
```

---

## PART 5: INFORMATION GAIN HARDENING

### 5.1 Novelty × Stability Product

**Problem:** Pure novelty-seeking encourages erratic camera motion, causing blur.

**Solution:** Information gain = Novelty × Stability (multiplicative, not additive).

```swift
// ═══════════════════════════════════════════════════════════════════════════
// INFORMATION GAIN = NOVELTY × STABILITY
// ═══════════════════════════════════════════════════════════════════════════

/// Information Gain Constants
public enum InfoGainConstants {
    // MARK: - Novelty Components

    /// View angle novelty weight
    public static let NOVELTY_VIEW_ANGLE_WEIGHT: Double = 0.35

    /// Distance novelty weight
    public static let NOVELTY_DISTANCE_WEIGHT: Double = 0.25

    /// Occlusion boundary novelty weight
    public static let NOVELTY_OCCLUSION_WEIGHT: Double = 0.25

    /// Depth range novelty weight
    public static let NOVELTY_DEPTH_RANGE_WEIGHT: Double = 0.15

    // MARK: - Stability Components

    /// Motion stability weight
    public static let STABILITY_MOTION_WEIGHT: Double = 0.40

    /// Exposure stability weight
    public static let STABILITY_EXPOSURE_WEIGHT: Double = 0.30

    /// Feature tracking stability weight
    public static let STABILITY_TRACKING_WEIGHT: Double = 0.30

    // MARK: - Multiplicative Floor

    /// Minimum stability required for any positive info gain
    public static let MIN_STABILITY_FOR_GAIN: Double = 0.3

    /// Stability exponent (controls how much stability matters)
    public static let STABILITY_EXPONENT: Double = 1.5
}

/// Novelty Factors
public struct NoveltyFactors: Codable {
    /// View angle novelty [0, 1]
    public let viewAngleNovelty: Double

    /// Distance novelty [0, 1]
    public let distanceNovelty: Double

    /// Occlusion boundary novelty [0, 1]
    public let occlusionNovelty: Double

    /// Depth range novelty [0, 1]
    public let depthRangeNovelty: Double

    /// Weighted novelty score
    public var weightedNovelty: Double {
        let C = InfoGainConstants.self
        return C.NOVELTY_VIEW_ANGLE_WEIGHT * viewAngleNovelty +
               C.NOVELTY_DISTANCE_WEIGHT * distanceNovelty +
               C.NOVELTY_OCCLUSION_WEIGHT * occlusionNovelty +
               C.NOVELTY_DEPTH_RANGE_WEIGHT * depthRangeNovelty
    }
}

/// Stability Factors
public struct StabilityFactors: Codable {
    /// Motion stability [0, 1] (1 = stable)
    public let motionStability: Double

    /// Exposure stability [0, 1]
    public let exposureStability: Double

    /// Feature tracking stability [0, 1]
    public let trackingStability: Double

    /// Weighted stability score
    public var weightedStability: Double {
        let C = InfoGainConstants.self
        return C.STABILITY_MOTION_WEIGHT * motionStability +
               C.STABILITY_EXPOSURE_WEIGHT * exposureStability +
               C.STABILITY_TRACKING_WEIGHT * trackingStability
    }
}

/// Information Gain Calculator with Novelty × Stability
public struct InfoGainCalculator {

    /// Calculate information gain as Novelty × Stability^exponent
    public static func calculateGain(
        novelty: NoveltyFactors,
        stability: StabilityFactors
    ) -> Double {
        let noveltyScore = novelty.weightedNovelty
        let stabilityScore = stability.weightedStability

        // Stability below threshold = zero gain (no matter how novel)
        if stabilityScore < InfoGainConstants.MIN_STABILITY_FOR_GAIN {
            return 0.0
        }

        // Multiplicative: high novelty only valuable if stable
        let stabilityMultiplier = pow(stabilityScore, InfoGainConstants.STABILITY_EXPONENT)

        return noveltyScore * stabilityMultiplier
    }
}
```

### 5.2 Keyframe Budget System

**Problem:** Unbounded keyframe selection causes storage/upload/training cost explosion.

**Research Basis:** [Taming 3DGS (SIGGRAPH Asia 2024)](https://dl.acm.org/doi/full/10.1145/3680528.3687694) - 4-5x reduction with keyframe budgeting.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// KEYFRAME BUDGET SYSTEM
// Research: Taming 3DGS (SIGGRAPH Asia 2024) - 4-5x training cost reduction
// ═══════════════════════════════════════════════════════════════════════════

/// Keyframe Budget Constants
public enum KeyframeBudgetConstants {
    /// Maximum keyframes per minute (base rate)
    public static let MAX_KEYFRAMES_PER_MINUTE: Int = 30

    /// Minimum keyframes per minute (even in throttle mode)
    public static let MIN_KEYFRAMES_PER_MINUTE: Int = 5

    /// Maximum raw frames in local buffer before thinning
    public static let MAX_LOCAL_BUFFER_SIZE: Int = 300

    /// Thinning trigger (% of buffer full)
    public static let THINNING_TRIGGER_RATIO: Double = 0.8

    /// Upload priority decay half-life (seconds)
    public static let UPLOAD_PRIORITY_HALFLIFE_SEC: Double = 60.0
}

/// Keyframe Budget State
public struct KeyframeBudgetState: Codable {
    /// Keyframes selected in current window
    public var keyframesInWindow: Int

    /// Window start timestamp
    public var windowStartTimestamp: MonotonicTimestamp

    /// Local buffer count
    public var localBufferCount: Int

    /// Upload queue size
    public var uploadQueueSize: Int

    /// Effective budget (adjusted by state machine)
    public func effectiveBudget(captureState: CaptureState) -> Int {
        let config = CaptureStateConfigs.config(for: captureState)
        let baseBudget = Double(KeyframeBudgetConstants.MAX_KEYFRAMES_PER_MINUTE)
        return max(
            KeyframeBudgetConstants.MIN_KEYFRAMES_PER_MINUTE,
            Int(baseBudget * config.keyframeBudgetMultiplier)
        )
    }

    /// Can accept new keyframe?
    public func canAcceptKeyframe(captureState: CaptureState, currentTime: MonotonicTimestamp) -> Bool {
        // Check window
        let elapsedSec = currentTime.secondsSince(windowStartTimestamp)
        if elapsedSec >= 60.0 {
            return true  // New window
        }

        // Check budget
        return keyframesInWindow < effectiveBudget(captureState: captureState)
    }
}

/// Keyframe Thinning Strategy
/// When local buffer is full, intelligently select which frames to keep
public struct KeyframeThinningStrategy {

    /// Thin local buffer to target size
    public static func thinBuffer(
        frames: inout [BufferedFrame],
        targetCount: Int
    ) {
        guard frames.count > targetCount else { return }

        // Score each frame
        let scored = frames.map { frame -> (BufferedFrame, Double) in
            let score = computeRetentionScore(frame)
            return (frame, score)
        }

        // Sort by score (higher = keep)
        let sorted = scored.sorted { $0.1 > $1.1 }

        // Keep top targetCount
        frames = sorted.prefix(targetCount).map { $0.0 }
    }

    private static func computeRetentionScore(_ frame: BufferedFrame) -> Double {
        // Factors:
        // - Information gain (higher = keep)
        // - Quality score (higher = keep)
        // - Age (newer slightly preferred)
        // - View coverage uniqueness (unique views preferred)

        var score = 0.0
        score += frame.infoGain * 0.4
        score += frame.qualityScore * 0.3
        score += frame.viewUniqueness * 0.2
        score += (1.0 - frame.normalizedAge) * 0.1  // Slight recency bias

        return score
    }
}
```

### 5.3 Diminishing Returns for Repeated Patches

**Problem:** Same patch hit repeatedly doesn't add proportional value.

**Solution:** Hit count tracking with logarithmic diminishing returns.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// DIMINISHING RETURNS FOR REPEATED PATCHES
// ═══════════════════════════════════════════════════════════════════════════

/// Patch Hit Tracker
public final class PatchHitTracker {

    /// Hit count per patch
    private var hitCounts: [String: Int] = [:]

    /// Last hit timestamp per patch
    private var lastHitTime: [String: MonotonicTimestamp] = [:]

    /// Diminishing return base (log base)
    private static let DIMINISHING_LOG_BASE: Double = 2.0

    /// Minimum multiplier (never zero)
    private static let MIN_MULTIPLIER: Double = 0.1

    /// Record patch hit
    public func recordHit(_ patchId: String, timestamp: MonotonicTimestamp) {
        hitCounts[patchId, default: 0] += 1
        lastHitTime[patchId] = timestamp
    }

    /// Get diminishing returns multiplier for patch
    public func getMultiplier(for patchId: String) -> Double {
        let hitCount = hitCounts[patchId, default: 0]

        if hitCount == 0 {
            return 1.0  // First hit = full value
        }

        // Logarithmic diminishing returns
        // 1st hit: 1.0, 2nd: 0.5, 4th: 0.33, 8th: 0.25, etc.
        let multiplier = 1.0 / log2(Double(hitCount) + Self.DIMINISHING_LOG_BASE)

        return max(Self.MIN_MULTIPLIER, multiplier)
    }

    /// Compute average multiplier for set of patches
    public func getAverageMultiplier(for patches: Set<String>) -> Double {
        guard !patches.isEmpty else { return 1.0 }

        let total = patches.reduce(0.0) { $0 + getMultiplier(for: $1) }
        return total / Double(patches.count)
    }
}
```

---

## PART 6: CRASH RECOVERY & JOURNAL SYSTEM

### 6.1 Capture Session Journal

**Problem:** Crash during capture can cause "ledger gap" and UI state inconsistency.

**Research Basis:** [RecoFlow (2025)](https://arxiv.org/html/2406.01339v1) - State persistence for crash recovery.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// CAPTURE SESSION JOURNAL - Crash recovery with state persistence
// Research: RecoFlow (2025) - App recovery via state journaling
// ═══════════════════════════════════════════════════════════════════════════

/// Journal Constants
public enum JournalConstants {
    /// Journal file name
    public static let JOURNAL_FILENAME = "capture_session_journal.json"

    /// Checkpoint interval (frames)
    public static let CHECKPOINT_INTERVAL_FRAMES: Int = 30

    /// Maximum journal size before compaction (entries)
    public static let MAX_JOURNAL_ENTRIES: Int = 1000

    /// Recovery display evidence decay (per missed checkpoint)
    public static let RECOVERY_DISPLAY_DECAY: Double = 0.0  // NEVER decay display evidence
}

/// Capture Session Journal Entry
public struct JournalEntry: Codable {
    public let entryId: UInt64
    public let timestamp: MonotonicTimestamp
    public let entryType: JournalEntryType
    public let payload: JournalPayload
}

/// Journal Entry Types
public enum JournalEntryType: String, Codable {
    case sessionStart
    case checkpoint
    case stateTransition
    case keyframeAccepted
    case uploadAcknowledged
    case sessionEnd
    case crashRecovery
}

/// Journal Payload
public enum JournalPayload: Codable {
    case sessionStart(SessionStartPayload)
    case checkpoint(CheckpointPayload)
    case stateTransition(StateTransitionPayload)
    case keyframe(KeyframePayload)
    case uploadAck(UploadAckPayload)
    case sessionEnd(SessionEndPayload)
    case crashRecovery(CrashRecoveryPayload)
}

/// Checkpoint Payload - periodic state snapshot
public struct CheckpointPayload: Codable {
    /// Last good frame index
    public let lastGoodFrameIndex: UInt64

    /// Last upload acknowledged frame
    public let lastUploadAckFrame: UInt64

    /// Current display evidence (UI-visible, MUST be monotonic)
    public let displayEvidence: Double

    /// Current ledger hash (for integrity)
    public let ledgerHash: String

    /// Capture state machine state
    public let captureState: CaptureState

    /// Keyframe budget state
    public let keyframeBudget: KeyframeBudgetState
}

/// Capture Session Journal Manager
public final class CaptureSessionJournal {

    private let fileManager: FileManager
    private let journalURL: URL
    private var entries: [JournalEntry] = []
    private var nextEntryId: UInt64 = 0
    private let writeLock = NSLock()

    /// Initialize journal (loads existing if crash recovery needed)
    public init(sessionDirectory: URL) throws {
        self.fileManager = FileManager.default
        self.journalURL = sessionDirectory.appendingPathComponent(JournalConstants.JOURNAL_FILENAME)

        // Check for existing journal (crash recovery case)
        if fileManager.fileExists(atPath: journalURL.path) {
            try loadExistingJournal()
        }
    }

    /// Record checkpoint
    public func checkpoint(payload: CheckpointPayload) throws {
        let entry = JournalEntry(
            entryId: nextEntryId,
            timestamp: MonotonicClock.now(),
            entryType: .checkpoint,
            payload: .checkpoint(payload)
        )
        try appendEntry(entry)
    }

    /// Recover from crash - returns recovery state
    public func recoverFromCrash() -> CrashRecoveryState? {
        // Find last valid checkpoint
        guard let lastCheckpoint = findLastValidCheckpoint() else {
            return nil
        }

        // CRITICAL: Display evidence MUST NOT decrease
        // Even if ledger has issues, UI must stay monotonic

        return CrashRecoveryState(
            lastGoodFrameIndex: lastCheckpoint.lastGoodFrameIndex,
            lastUploadAckFrame: lastCheckpoint.lastUploadAckFrame,
            displayEvidence: lastCheckpoint.displayEvidence,  // Preserved!
            captureState: lastCheckpoint.captureState,
            keyframeBudget: lastCheckpoint.keyframeBudget
        )
    }

    private func findLastValidCheckpoint() -> CheckpointPayload? {
        for entry in entries.reversed() {
            if case .checkpoint(let payload) = entry.payload {
                return payload
            }
        }
        return nil
    }

    private func appendEntry(_ entry: JournalEntry) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        entries.append(entry)
        nextEntryId += 1

        // Write to disk immediately (crash safety)
        try persistToDisk()

        // Compact if needed
        if entries.count > JournalConstants.MAX_JOURNAL_ENTRIES {
            try compactJournal()
        }
    }

    private func persistToDisk() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(entries)
        try data.write(to: journalURL, options: .atomic)
    }

    private func compactJournal() throws {
        // Keep only last checkpoint and subsequent entries
        if let lastCheckpointIndex = entries.lastIndex(where: { $0.entryType == .checkpoint }) {
            entries = Array(entries[lastCheckpointIndex...])
        }
        try persistToDisk()
    }

    private func loadExistingJournal() throws {
        let data = try Data(contentsOf: journalURL)
        let decoder = JSONDecoder()
        entries = try decoder.decode([JournalEntry].self, from: data)
        nextEntryId = (entries.last?.entryId ?? 0) + 1
    }
}

/// Crash Recovery State
public struct CrashRecoveryState: Codable {
    public let lastGoodFrameIndex: UInt64
    public let lastUploadAckFrame: UInt64
    public let displayEvidence: Double  // MUST be restored exactly
    public let captureState: CaptureState
    public let keyframeBudget: KeyframeBudgetState
}
```

---

## PART 7: PRIVACY & DATA MINIMIZATION

### 7.1 Privacy-Preserving Upload Protocol

**Problem:** Raw frames contain potentially sensitive data (faces, personal items).

**Research Basis:** [GDPR Privacy by Design (2025)](https://secureprivacy.ai/blog/privacy-by-design-gdpr-2025), [Privacy-Preserving IoT (2025)](https://www.sciencedirect.com/science/article/abs/pii/S0140366420319708)

```swift
// ═══════════════════════════════════════════════════════════════════════════
// PRIVACY-PRESERVING UPLOAD PROTOCOL
// Research: GDPR Privacy by Design (2025), Data Minimization principles
// ═══════════════════════════════════════════════════════════════════════════

/// Privacy Constants
public enum PrivacyConstants {
    /// Default: encrypt before upload
    public static let ENCRYPT_BEFORE_UPLOAD: Bool = true

    /// Face detection confidence threshold for masking
    public static let FACE_DETECTION_CONFIDENCE: Double = 0.7

    /// Face region expansion ratio (for safety margin)
    public static let FACE_REGION_EXPANSION: Double = 1.2

    /// Maximum descriptor size for assist features (bytes)
    public static let MAX_ASSIST_DESCRIPTOR_SIZE: Int = 512

    /// Data retention period (days) - for GDPR compliance
    public static let DATA_RETENTION_DAYS: Int = 90
}

/// Privacy Mode
public enum PrivacyMode: String, Codable {
    case standard          // Encrypt + upload
    case faceBlurred       // Blur faces before upload
    case descriptorOnly    // Only upload feature descriptors, not images
    case localOnly         // Never upload, local processing only
}

/// Upload Privacy Manager
public final class UploadPrivacyManager {

    private let privacyMode: PrivacyMode
    private let encryptionKey: SymmetricKey?

    /// Prepare frame bundle for upload with privacy protection
    public func prepareForUpload(
        bundle: FrameBundle
    ) -> PrivacyProtectedUploadBundle {

        switch privacyMode {
        case .standard:
            return PrivacyProtectedUploadBundle(
                encryptedRaw: encryptFrame(bundle.raw),
                featureDescriptors: extractDescriptors(bundle.assist),
                metadata: redactSensitiveMetadata(bundle),
                privacyMode: .standard
            )

        case .faceBlurred:
            let blurredRaw = blurFaces(in: bundle.raw)
            return PrivacyProtectedUploadBundle(
                encryptedRaw: encryptFrame(blurredRaw),
                featureDescriptors: extractDescriptors(bundle.assist),
                metadata: redactSensitiveMetadata(bundle),
                privacyMode: .faceBlurred
            )

        case .descriptorOnly:
            // Only upload descriptors, NOT images
            return PrivacyProtectedUploadBundle(
                encryptedRaw: nil,  // No image!
                featureDescriptors: extractDescriptors(bundle.assist),
                metadata: redactSensitiveMetadata(bundle),
                privacyMode: .descriptorOnly
            )

        case .localOnly:
            fatalError("localOnly mode should not call prepareForUpload")
        }
    }

    private func blurFaces(in frame: RawFrame) -> RawFrame {
        // Detect faces and blur regions
        // Note: This creates a NEW frame, doesn't modify original
        // ...
        return frame
    }

    private func encryptFrame(_ frame: RawFrame) -> EncryptedData? {
        guard let key = encryptionKey else { return nil }
        // AES-256-GCM encryption
        // ...
        return nil
    }

    private func extractDescriptors(_ frame: AssistFrame) -> [FeatureDescriptor] {
        // Extract compact descriptors (max 512 bytes each)
        // ...
        return []
    }

    private func redactSensitiveMetadata(_ bundle: FrameBundle) -> RedactedMetadata {
        // Remove potentially identifying metadata:
        // - Exact GPS coordinates (keep only region)
        // - Device serial numbers
        // - User identifiers
        // ...
        return RedactedMetadata()
    }
}

/// Privacy-Protected Upload Bundle
public struct PrivacyProtectedUploadBundle: Codable {
    public let encryptedRaw: EncryptedData?
    public let featureDescriptors: [FeatureDescriptor]
    public let metadata: RedactedMetadata
    public let privacyMode: PrivacyMode
}
```

---

## PART 8: AUDIT & DEBUGGING

### 8.1 Comprehensive Audit System

**Problem:** Cannot diagnose "why didn't it get brighter?" without detailed audit trail.

**Solution:** Comprehensive audit logging (numeric values only, no image content).

```swift
// ═══════════════════════════════════════════════════════════════════════════
// COMPREHENSIVE AUDIT SYSTEM - Debug without privacy violation
// ═══════════════════════════════════════════════════════════════════════════

/// Audit Record - complete capture decision trail
public struct CaptureAuditRecord: Codable {
    // MARK: - Identity

    public let frameIndex: UInt64
    public let timestamp: MonotonicTimestamp
    public let wallClockTime: String  // ISO8601, for display only

    // MARK: - State Machine

    public let captureState: CaptureState
    public let stateTransition: StateTransitionRecord?

    // MARK: - Exposure

    public let exposureLockState: ExposureLockMode
    public let meanLuminance: Double
    public let flickerScore: Double
    public let flickerFrequency: FlickerDetector.FlickerFrequency
    public let wbDriftScore: Double
    public let torchLevel: Float

    // MARK: - Frame Quality

    public let reconstructabilityScore: Double
    public let featureTrackingRate: Double
    public let motionBlurIndicator: Double
    public let rollingShutterDistortion: Double
    public let visualSharpness: Double

    // MARK: - Texture

    public let microTextureStrength: Double
    public let structuralEdgeDensity: Double
    public let repetitionRiskScore: Double
    public let specularRatio: Double
    public let transparentRatio: Double

    // MARK: - Dynamic Objects

    public let dynamicRegionRatio: Double
    public let dynamicPatchCount: Int

    // MARK: - Information Gain

    public let noveltyScore: Double
    public let stabilityScore: Double
    public let infoGainScore: Double
    public let patchDiminishingMultiplier: Double

    // MARK: - Budget

    public let thermalState: Int
    public let batteryLevel: Double
    public let uploadBacklogBytes: Int
    public let memoryPressure: Int
    public let budgetFactor: Double

    // MARK: - Decision

    public let frameDisposition: FrameDisposition
    public let dropReason: FrameRetentionDecision.DiscardReason?
    public let deltaMultiplier: Double
    public let isKeyframe: Bool

    // MARK: - Evidence (output)

    public let deltaContribution: Double
    public let displayEvidenceBefore: Double
    public let displayEvidenceAfter: Double

    // NOTE: No image content, no feature descriptors, no personal data
}

/// Debug Overlay Channel (dev build only)
#if DEBUG
public final class DebugOverlayChannel {

    /// Overlay colors for different issues
    public enum OverlayColor {
        case red      // Motion blur / high motion
        case orange   // Low light
        case yellow   // Weak texture
        case blue     // Dynamic objects
        case purple   // Specular/transparent
        case green    // Good quality
        case gray     // Thermal throttle
    }

    /// Generate overlay for debugging (no text, colors only)
    public static func generateOverlay(
        audit: CaptureAuditRecord,
        frameSize: CGSize
    ) -> DebugOverlay {
        var regions: [OverlayRegion] = []

        // Color-code the frame border based on primary issue
        let borderColor: OverlayColor
        switch audit.captureState {
        case .highMotion: borderColor = .red
        case .lowLight: borderColor = .orange
        case .weakTexture: borderColor = .yellow
        case .thermalThrottle: borderColor = .gray
        case .normal: borderColor = .green
        }

        // Add dynamic region highlights
        if audit.dynamicRegionRatio > 0.1 {
            // Highlight dynamic regions in blue
            // ...
        }

        // Add specular region highlights
        if audit.specularRatio > 0.1 {
            // Highlight specular regions in purple
            // ...
        }

        return DebugOverlay(borderColor: borderColor, regions: regions)
    }
}
#endif
```

---

## PART 9: CONSTANTS VERSION & GOVERNANCE

### 9.1 Constants Versioning

**Problem:** Cannot determine which thresholds were used when debugging old captures.

**Solution:** Versioned constants with audit trail.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// CONSTANTS VERSIONING - Track threshold changes
// ═══════════════════════════════════════════════════════════════════════════

/// Constants Version
public enum PR5ConstantsVersion {
    /// Current version string
    public static let CURRENT_VERSION = "pr5.v1.0.0"

    /// Schema version (bump on structural changes)
    public static let SCHEMA_VERSION: Int = 1

    /// Values version (bump on threshold changes)
    public static let VALUES_VERSION: Int = 0

    /// Patch version (bump on bug fixes)
    public static let PATCH_VERSION: Int = 0

    /// Full version string
    public static var fullVersion: String {
        return "pr5.v\(SCHEMA_VERSION).\(VALUES_VERSION).\(PATCH_VERSION)"
    }
}

/// Constants Manifest - included in every audit record
public struct ConstantsManifest: Codable {
    public let version: String
    public let schemaVersion: Int
    public let valuesVersion: Int
    public let patchVersion: Int
    public let timestamp: String  // ISO8601 of when constants were compiled

    /// Generate manifest hash for integrity
    public var manifestHash: String {
        // Hash of all constant values
        // ...
        return ""
    }

    public static let current = ConstantsManifest(
        version: PR5ConstantsVersion.CURRENT_VERSION,
        schemaVersion: PR5ConstantsVersion.SCHEMA_VERSION,
        valuesVersion: PR5ConstantsVersion.VALUES_VERSION,
        patchVersion: PR5ConstantsVersion.PATCH_VERSION,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )
}
```

---

## PART 10: TEN IRON LAWS (IMMUTABLE)

These laws MUST be enforced at compile time or runtime. Violation = build failure or crash.

```swift
// ═══════════════════════════════════════════════════════════════════════════
// TEN IRON LAWS - IMMUTABLE CONSTRAINTS
// ═══════════════════════════════════════════════════════════════════════════

public enum PR5IronLaws {

    // LAW 1: Enhancement NEVER modifies rawFrame
    // Enforced by: RawFrame is ~Copyable and read-only locked

    // LAW 2: Training/Rendering ONLY consumes rawFrame
    // Enforced by: Protocol constraints (TrainingInputProtocol, RenderingInputProtocol)

    // LAW 3: Every frame drop has auditable reason
    // Enforced by: FrameRetentionDecision.discard(reason:) is required

    // LAW 4: Every degradation is recoverable via journal
    // Enforced by: JournalConstants.RECOVERY_DISPLAY_DECAY = 0.0

    // LAW 5: Every threshold change bumps constantsVersion
    // Enforced by: CI check on constants file hash

    // LAW 6: Cross-platform differences caught by golden fixtures
    // Enforced by: PR5CrossPlatformDeterminismTests

    // LAW 7: No randomness in decision chain
    // Enforced by: Code review + determinism tests

    // LAW 8: All timestamp decisions use monotonic clock
    // Enforced by: MonotonicTimestamp type (no Date() in decision logic)

    // LAW 9: Privacy-sensitive data minimized before upload
    // Enforced by: UploadPrivacyManager.prepareForUpload()

    // LAW 10: New state machine states require test coverage
    // Enforced by: CI check for CaptureState enum coverage
}
```

---

## PART 11: TEST REQUIREMENTS

### 11.1 Evidence Curve Acceptance Criteria

```swift
// ═══════════════════════════════════════════════════════════════════════════
// EVIDENCE CURVE ACCEPTANCE CRITERIA - Quantifiable validation
// ═══════════════════════════════════════════════════════════════════════════

/// Test Scenarios with Acceptance Criteria
public enum EvidenceCurveTestScenarios {

    /// Scenario 1: Normal office environment
    public static let normalOffice = TestScenarioCriteria(
        name: "normal_office",
        p50TimeToDisplay70Sec: 45.0,      // P50: reach display=0.7 within 45s
        p95TimeToDisplay70Sec: 90.0,      // P95: reach display=0.7 within 90s
        maxStallDurationSec: 5.0,         // Never stall more than 5s
        maxDisplayVariance: 0.02          // Display jitter < 2%
    )

    /// Scenario 2: Weak texture (white wall)
    public static let weakTextureWall = TestScenarioCriteria(
        name: "weak_texture_wall",
        p50TimeToDisplay70Sec: 90.0,      // Slower due to weak texture
        p95TimeToDisplay70Sec: 150.0,
        maxStallDurationSec: 8.0,         // Longer acceptable stall
        maxDisplayVariance: 0.03
    )

    /// Scenario 3: Specular surface (glass table)
    public static let specularSurface = TestScenarioCriteria(
        name: "specular_surface",
        p50TimeToDisplay70Sec: 120.0,     // Slowest scenario
        p95TimeToDisplay70Sec: 180.0,
        maxStallDurationSec: 10.0,
        maxDisplayVariance: 0.04
    )

    /// Scenario 4: Low light corridor
    public static let lowLightCorridor = TestScenarioCriteria(
        name: "low_light_corridor",
        p50TimeToDisplay70Sec: 75.0,
        p95TimeToDisplay70Sec: 120.0,
        maxStallDurationSec: 6.0,
        maxDisplayVariance: 0.03
    )

    /// Scenario 5: Repetitive texture (tile floor)
    public static let repetitiveTile = TestScenarioCriteria(
        name: "repetitive_tile",
        p50TimeToDisplay70Sec: 100.0,     // Slow due to drift risk
        p95TimeToDisplay70Sec: 160.0,
        maxStallDurationSec: 8.0,
        maxDisplayVariance: 0.03
    )
}

/// Test Scenario Criteria
public struct TestScenarioCriteria {
    public let name: String
    public let p50TimeToDisplay70Sec: Double
    public let p95TimeToDisplay70Sec: Double
    public let maxStallDurationSec: Double
    public let maxDisplayVariance: Double
}
```

### 11.2 Performance Budget Compliance

```swift
/// Performance Budget Tests
public enum PerformanceBudgetCriteria {
    // MARK: - Latency Budgets

    /// Full pipeline P50 latency (ms)
    public static let PIPELINE_P50_MS: Double = 14.0

    /// Full pipeline P95 latency (ms)
    public static let PIPELINE_P95_MS: Double = 22.0

    /// Full pipeline P99 latency (ms)
    public static let PIPELINE_P99_MS: Double = 30.0

    /// Emergency mode P50 latency (ms)
    public static let EMERGENCY_P50_MS: Double = 5.0

    // MARK: - Frame Rate

    /// Minimum sustainable frame rate (fps)
    public static let MIN_FRAME_RATE_FPS: Double = 30.0

    /// Maximum frame drop rate (%)
    public static let MAX_FRAME_DROP_RATE_PCT: Double = 5.0

    // MARK: - Memory

    /// Maximum memory growth per 1000 frames (MB)
    public static let MAX_MEMORY_GROWTH_MB: Double = 20.0

    /// Maximum peak memory (MB)
    public static let MAX_PEAK_MEMORY_MB: Double = 200.0

    // MARK: - Thermal

    /// Maximum time at thermal serious before throttle (sec)
    public static let MAX_TIME_AT_THERMAL_SERIOUS_SEC: Double = 30.0

    // MARK: - Battery

    /// Maximum battery drain rate (%/hour during capture)
    public static let MAX_BATTERY_DRAIN_PCT_PER_HOUR: Double = 15.0
}
```

---

## PART 12: DELIVERABLES SUMMARY

### 12.1 Required Files (Updated)

| File Path | Description | Priority |
|-----------|-------------|----------|
| `Core/Capture/CaptureStateMachine.swift` | State machine with 5 states | P0 |
| `Core/Capture/AnchoredExposureController.swift` | Exposure with anchor + flicker | P0 |
| `Core/Capture/ReconstructabilityQuality.swift` | Reconstructability-first quality | P0 |
| `Core/Capture/DynamicRegionDetector.swift` | Dynamic object detection | P0 |
| `Core/Capture/TextureAnalyzer3D.swift` | 3-component texture analysis | P0 |
| `Core/Capture/RepetitionPatternDetector.swift` | Repetitive texture detection | P0 |
| `Core/Capture/SpecularTransparentDetector.swift` | Specular/transparent detection | P0 |
| `Core/Capture/InfoGainCalculator.swift` | Novelty × Stability | P0 |
| `Core/Capture/KeyframeBudgetManager.swift` | Keyframe budget system | P0 |
| `Core/Capture/PatchHitTracker.swift` | Diminishing returns tracker | P1 |
| `Core/Frame/RawFrame.swift` | Strong type wrapper | P0 |
| `Core/Frame/AssistFrame.swift` | Strong type wrapper with pool | P0 |
| `Core/Frame/FrameBundle.swift` | Dual-path bundle | P0 |
| `Core/Journal/CaptureSessionJournal.swift` | Crash recovery journal | P0 |
| `Core/Privacy/UploadPrivacyManager.swift` | Privacy-preserving upload | P1 |
| `Core/Audit/CaptureAuditRecord.swift` | Comprehensive audit record | P0 |
| `Core/Constants/PR5CaptureConstants.swift` | All constants + version | P0 |
| `Core/Constants/PR5ConstantsVersion.swift` | Version tracking | P0 |
| `Tests/E2E/EvidenceCurveAcceptanceTests.swift` | Scenario-based validation | P0 |
| `Tests/E2E/PerformanceBudgetTests.swift` | Performance compliance | P0 |
| `Tests/PR5/StateMachineTests.swift` | State machine tests | P0 |
| `Tests/PR5/CrossPlatformDeterminismTests.swift` | Golden fixture tests | P0 |
| `Tests/PR5/IronLawComplianceTests.swift` | Iron law enforcement | P0 |

### 12.2 CI Requirements (Updated)

1. **All tests pass** on macOS (Apple Silicon) and Linux (x86_64)
2. **Golden fixture validation** - same input → same output
3. **Constants hash check** - bump version on any change
4. **Iron law static analysis** - no Date(), no force unwrap, no rawFrame mutation
5. **Performance budget compliance** - P50/P95/P99 within limits
6. **Memory leak detection** - no growth over 1000 frames
7. **Capture state enum coverage** - all states have tests

---

## RESEARCH REFERENCES

### State Machine & VIO
- [Visual-Inertial SLAM for Unstructured Outdoor Environments (2025)](https://onlinelibrary.wiley.com/doi/10.1002/rob.22581)
- [AirSLAM: Robust VIO in Low-Texture/Repetitive Environments (2025)](https://arxiv.org/html/2405.03413v2)

### Keyframe Selection & Training
- [Taming 3DGS: Budget-Constrained Training (SIGGRAPH Asia 2024)](https://dl.acm.org/doi/full/10.1145/3680528.3687694)
- [OptiViewNeRF: Batch View Selection (2025)](https://www.sciencedirect.com/science/article/pii/S1569843224006642)

### Repetitive Texture & SLAM Drift
- [GroundSLAM: Robust VIO on Repetitive Patterns (2025)](https://sairlab.org/groundslam/)
- [Post-integration Point-Line SLAM in Low-Texture (Nature 2025)](https://www.nature.com/articles/s41598-025-97250-6)
- [RGB-D + GNN SLAM for Dynamic/Low-Texture (Nature 2025)](https://www.nature.com/articles/s41598-025-12978-5)

### Specular/Transparent Surfaces
- [NTIRE 2025 Challenge: Depth from Specular/Transparent](https://arxiv.org/html/2506.05815)
- [Depth Completion for Specular Objects (2025)](https://ietresearch.onlinelibrary.wiley.com/doi/10.1049/ipr2.70049)

### Crash Recovery
- [RecoFlow: App Recovery via User Flow Replay (2025)](https://arxiv.org/html/2406.01339v1)
- [Android Crash Recovery Module (2025)](https://source.android.com/docs/core/ota/modular-system/crash-recovery)
- [Mobile App Stability Outlook 2025](https://www.luciq.ai/mobile-app-stability-outlook-2025)

### Privacy & GDPR
- [GDPR Privacy by Design Implementation (2025)](https://secureprivacy.ai/blog/privacy-by-design-gdpr-2025)
- [Privacy-Enhancing Technologies Value (2025)](https://usercentrics.com/guides/data-privacy/privacy-enhancing-technologies-value/)
- [AI Data Minimization Guide (2025)](https://secureprivacy.ai/blog/ai-data-minimization)

---

**END OF PR5 BULLETPROOF PATCH v1.0**
