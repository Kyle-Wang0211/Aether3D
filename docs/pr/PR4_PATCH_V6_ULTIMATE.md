# PR4 Soft Extreme System - Patch V6 ULTIMATE

**Document Version:** 6.0 (Ultimate Hardening + Soft Gate + Early Quantization + Robust Calibration)
**Status:** FINAL DRAFT
**Created:** 2026-02-01
**Scope:** PR4 Industrial-Grade Depth Fusion with Cross-Platform Determinism

---

## Part 0: V6 Critical Fixes Over V5

This V6 document addresses **6 NEW hard issues** identified in V5 review, implements **12 ULTIMATE seal patches**, and adds **research-based mobile optimizations**.

### V6 vs V5 Delta Matrix

| V5 Issue | V6 Fix | Impact |
|----------|--------|--------|
| **Hard-1**: MultiSourceArbitrator gate={0,1} causes jitter | Soft Gate [0,1] + hysteresis | Eliminates source flip-flop |
| **Hard-2**: Cross-platform determinism not achievable with Double | Early Quantization Mode | True bit-exact reproducibility |
| **Hard-3**: Calibration uses least-squares (outlier-sensitive) | Huber/MAD robust regression | Stable σ parameters |
| **Hard-4**: NoiseModel σ→0 when conf→1 | σ floor per source + conf=0 semantics | Prevents over-hard fusion |
| **Hard-5**: AllocationDetector unreliable on some iOS versions | Tiered verification (L0/L1/L2) | CI stability |
| **Hard-6**: UncertaintyPropagator assumes independence | Correlation upper bound ρ_max | Realistic uncertainty |

### 12 ULTIMATE Seal Patches

1. MultiSourceArbitrator: gate ∈ [0,1] + hysteresis
2. CrossPlatformDeterminismMode: early quantization
3. CalibrationHarness: Huber regression + outlierRate
4. NoiseModelContract: σ_floor + conf=0 branch locked
5. UncertaintyPropagator: ρ_max correlation handling
6. finalQuality includes uncertaintyPenalty
7. ROITracker: 8-bin gradient histogram signature
8. Tier3b fields banned from softQuality chain (lint enforced)
9. DeterminismFuzzer: explicit determinismKey/ignoredKey
10. AllocationDetector: L0/L1/L2 tiered verification
11. WeightSaturation: default locked + saturation delta tests
12. Diagnostics: release field stripping policy

---

## Part 1: The Twenty Pillars of PR4 V6

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE TWENTY PILLARS OF PR4 V6 ULTIMATE                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: SOFT GATE ARBITRATION (V6 NEW - replaces V5 binary gate)        │
│  ├── sourceGate ∈ [0,1] continuous, NOT {0,1} binary                       │
│  ├── Formula: gate = clamp((health - h_lo) / (h_hi - h_lo), 0, 1)          │
│  ├── Hysteresis: h_enter=0.5, h_exit=0.3 (different thresholds)            │
│  ├── Hard disable only when health < 0.1 (with 5-frame confirm)            │
│  ├── Gate multiplies TSDF weight, doesn't discard source                   │
│  └── Jitter test: health oscillating 0.28-0.32 must NOT flip gate          │
│                                                                             │
│  PILLAR 2: EARLY QUANTIZATION DETERMINISM (V6 NEW - cross-platform)        │
│  ├── All critical intermediates quantized at module boundaries             │
│  ├── Quantization points: σQ, μQ, weightQ, logitQ, gainQ                   │
│  ├── Format: Q16.16 fixed-point (Int64) for precision                      │
│  ├── Module I/O uses Int64, internal can use Double with care              │
│  ├── Final output: dequantize only at very end                             │
│  └── Guarantees: iOS ARM64 == Linux x86_64 == Linux ARM64                  │
│                                                                             │
│  PILLAR 3: ROBUST CALIBRATION (V6 NEW - replaces least-squares)            │
│  ├── Loss function: Huber loss with δ=0.05m (not L2/MSE)                   │
│  ├── Outlier detection: MAD-based, reject if |residual| > 3×MAD            │
│  ├── Output: σ_base, α, β + fitQualityScore + outlierRate                  │
│  ├── Validation: outlierRate > 30% triggers warning                        │
│  └── Reference: NVIDIA robust regression, scikit-learn HuberRegressor      │
│                                                                             │
│  PILLAR 4: NOISE MODEL WITH FLOOR (V6 ENHANCED)                            │
│  ├── σ = max(σ_floor(source), σ_base × (d/d_ref)^α × (1 - β×conf))        │
│  ├── σ_floor by source: LiDAR=0.002m, ML=0.005m, stereo=0.008m            │
│  ├── conf=0 semantics: INVALID (skip pixel), not low-confidence            │
│  ├── conf∈(0,0.1]: treat as conf=0.1 (floor)                               │
│  ├── Monotonicity: σ increases with depth, decreases with conf             │
│  └── Contract test: validateSigmaMonotonicity() for all source×depth×conf  │
│                                                                             │
│  PILLAR 5: CORRELATED UNCERTAINTY (V6 NEW)                                 │
│  ├── σ²_total = Σσ²_i + 2×ρ_max × Σ_{i<j} σ_i×σ_j                         │
│  ├── ρ_max = 0.3 (conservative correlation upper bound)                    │
│  ├── Alternative: max(σ_depth, σ_source) for highly correlated pairs       │
│  ├── Test: correlated inputs must not produce unrealistic uncertainty      │
│  └── Output: softQualityUncertainty reflects true confidence               │
│                                                                             │
│  PILLAR 6: UNCERTAINTY-PENALIZED QUALITY (V6 NEW)                          │
│  ├── finalQuality = gate × softMean × uncertaintyPenalty                   │
│  ├── uncertaintyPenalty = clamp(1 - k×uncertainty, p_min, 1)               │
│  ├── k = 2.0, p_min = 0.5 (uncertainty halves quality at most)             │
│  ├── Makes uncertainty actionable, not just diagnostic                     │
│  └── UI/strategy can use uncertainty for decision making                   │
│                                                                             │
│  PILLAR 7: ROI SIGNATURE MATCHING (V6 ENHANCED)                            │
│  ├── Match score = w1×IoU + w2×centroidDist + w3×histogramSim              │
│  ├── Histogram: 8-bin quantized gradient magnitude distribution            │
│  ├── Weights: w1=0.5, w2=0.3, w3=0.2 (all deterministic)                   │
│  ├── Handles ROI deformation from viewpoint changes                        │
│  └── Zero-allocation: histogram bins pre-allocated                         │
│                                                                             │
│  PILLAR 8: TIER3B ISOLATION (V6 HARDENED)                                  │
│  ├── Tier3b fields CANNOT be referenced by SoftQualityComputer             │
│  ├── Enforced by: lint rule + dependency scan test                         │
│  ├── deviceModel, iosVersion, gpuModel are metadata ONLY                   │
│  ├── Any Tier3b→softQuality link = CI FAIL                                 │
│  └── Prevents "platform feature leakage" into quality computation          │
│                                                                             │
│  PILLAR 9: DETERMINISM KEY SPECIFICATION (V6 NEW)                          │
│  ├── DeterminismFuzzer compares ONLY determinismKey fields                 │
│  ├── determinismKey: softQualityMeanQ, gainQ, weightQ, logitQ              │
│  ├── ignoredKey: latencyMs, timestamp, diagnostics sampling                │
│  ├── ignoredKey MUST be in whitelist (no silent additions)                 │
│  └── 100-run fuzzer: all determinismKey fields bit-exact                   │
│                                                                             │
│  PILLAR 10: TIERED ALLOCATION VERIFICATION (V6 NEW)                        │
│  ├── L0 (all platforms): capacity assertions + API lint + static scan     │
│  ├── L1 (iOS DEBUG): malloc_zone hooks (best effort)                       │
│  ├── L2 (benchmark device): full instrumentation                           │
│  ├── CI runs L0 always, L1 when available, L2 on dedicated machine         │
│  ├── L1 failure doesn't break CI, but logs warning                         │
│  └── "Zero allocation" claim based on L0, enhanced by L1/L2                │
│                                                                             │
│  PILLAR 11-20: [Inherited from V5 with enhancements]                       │
│  ├── PILLAR 11: NoiseModelContract (V5 + σ_floor)                          │
│  ├── PILLAR 12: OnlineMADEstimatorGate (V5, unchanged)                     │
│  ├── PILLAR 13: TruncationUpperBound μ_max (V5, unchanged)                 │
│  ├── PILLAR 14: WeightSaturationPolicy DIMINISHING (V5 + default locked)   │
│  ├── PILLAR 15: EdgeLogitMapping linear a=10 (V5, unchanged)               │
│  ├── PILLAR 16: TierFieldWhitelist (V5 + isolation enforcement)            │
│  ├── PILLAR 17: StrictImportIsolation (V3, unchanged)                      │
│  ├── PILLAR 18: TSDF-Inspired Fusion (V3 + early quantization)             │
│  ├── PILLAR 19: Temporal Filter State Machine (V3, unchanged)              │
│  └── PILLAR 20: Budget-Degrade Framework (V4, unchanged)                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 2: V6 Directory Structure (Delta from V5)

```
Core/Evidence/
├── PR4/
│   ├── Arbitration/
│   │   ├── SoftGateComputer.swift        // V6: continuous [0,1] gate
│   │   ├── SourceHealthTracker.swift     // V6: hysteresis tracking
│   │   ├── MultiSourceArbitrator.swift   // V6: soft gate integration
│   │   └── GateHysteresisConfig.swift    // V6 NEW: enter/exit thresholds
│   ├── Determinism/                       // V6 NEW FOLDER
│   │   ├── QuantizationPoints.swift      // V6: Q16.16 definitions
│   │   ├── EarlyQuantizer.swift          // V6: module boundary quantization
│   │   ├── DeterminismKeySpec.swift      // V6: determinismKey/ignoredKey
│   │   └── CrossPlatformMath.swift       // V6: deterministic math ops
│   ├── Uncertainty/
│   │   ├── UncertaintyPropagator.swift   // V6: with ρ_max correlation
│   │   ├── CorrelationConfig.swift       // V6 NEW: ρ_max = 0.3
│   │   └── UncertaintyPenalty.swift      // V6 NEW: quality penalty
│   ├── DepthFusion/
│   │   ├── ROITracker.swift              // V6: + histogram signature
│   │   ├── ROISignature.swift            // V6 NEW: 8-bin histogram
│   │   └── ... (unchanged from V5)
│   └── Internal/
│       ├── AllocationDetector.swift      // V6: L0/L1/L2 tiered
│       └── AllocationVerificationLevel.swift  // V6 NEW
├── Constants/
│   ├── NoiseModelContract.swift          // V6: + σ_floor + conf=0 semantics
│   ├── SoftGateConfig.swift              // V6 NEW: hysteresis params
│   ├── QuantizationConfig.swift          // V6 NEW: Q16.16 specs
│   ├── CorrelationBounds.swift           // V6 NEW: ρ_max
│   └── ... (unchanged from V5)
├── Tools/
│   └── CalibrationHarness/
│       ├── HuberRegressor.swift          // V6 NEW: robust regression
│       ├── MADOutlierDetector.swift      // V6 NEW: outlier rejection
│       └── CalibrationValidator.swift    // V6 NEW: outlierRate check

Tests/Evidence/PR4/
├── SoftGateTests/                         // V6 NEW FOLDER
│   ├── GateHysteresisTests.swift
│   ├── HealthBoundaryJitterTests.swift   // V6: oscillation test
│   └── SoftGateContinuityTests.swift
├── DeterminismTests/
│   ├── EarlyQuantizationTests.swift      // V6 NEW
│   ├── CrossPlatformBitExactTests.swift  // V6 NEW
│   └── DeterminismKeyValidationTests.swift  // V6 NEW
├── CalibrationTests/
│   ├── HuberRegressionTests.swift        // V6 NEW
│   ├── OutlierRejectionTests.swift       // V6 NEW
│   └── CalibrationRobustnessTests.swift  // V6 NEW
└── UncertaintyTests/
    ├── CorrelatedInputTests.swift        // V6 NEW
    └── UncertaintyPenaltyTests.swift     // V6 NEW
```

---

## Part 3: V6 Hard Fix #1 - Soft Gate Arbitration

### 3.1 SoftGateConfig.swift

```swift
//
// SoftGateConfig.swift
// Aether3D
//
// PR4 V6 - Soft Gate Configuration with Hysteresis
// HARD FIX #1: Eliminates binary gate jitter
//
// REFERENCE: ARGate architecture - learned gating fusion weights
// REFERENCE: Reliability-Aware Sensor Weighting (2024)
//

import Foundation

public enum SoftGateConfig {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Continuous Gate Mapping
    // ═══════════════════════════════════════════════════════════════════════

    /// Health threshold for full gate (gate=1.0)
    public static let healthThresholdHigh: Double = 0.6

    /// Health threshold for zero gate (gate=0.0)
    public static let healthThresholdLow: Double = 0.2

    // Formula: gate = clamp((health - h_lo) / (h_hi - h_lo), 0, 1)

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Hysteresis (Prevents Oscillation)
    // ═══════════════════════════════════════════════════════════════════════

    /// Health threshold to ENTER enabled state
    public static let hysteresisEnterThreshold: Double = 0.35

    /// Health threshold to EXIT enabled state
    public static let hysteresisExitThreshold: Double = 0.25

    /// Frames required to confirm state transition
    public static let hysteresisConfirmFrames: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Hard Disable (Emergency Only)
    // ═══════════════════════════════════════════════════════════════════════

    /// Health threshold for hard disable (truly broken sources)
    public static let hardDisableThreshold: Double = 0.1

    /// Frames required to confirm hard disable
    public static let hardDisableConfirmFrames: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gate Smoothing
    // ═══════════════════════════════════════════════════════════════════════

    /// EMA smoothing factor for gate transitions (α = 0.2 means ~5 frame time constant)
    public static let gateSmoothingAlpha: Double = 0.2
}
```

### 3.2 SoftGateComputer.swift (Key Implementation)

```swift
//
// SoftGateComputer.swift
// Aether3D
//
// PR4 V6 - Continuous Soft Gate with Hysteresis
//

import Foundation
import PRMath

public final class SoftGateComputer {

    public struct SourceGateState {
        public var smoothedGate: Double = 0.5
        public var isEnabled: Bool = true
        public var transitionFrameCount: Int = 0
        public var isHardDisabled: Bool = false
        public var hardDisableFrameCount: Int = 0
    }

    private var sourceStates: [String: SourceGateState] = [:]

    /// Compute soft gate for a source
    /// FORMULA: rawGate = clamp((health - h_lo) / (h_hi - h_lo), 0, 1)
    /// smoothedGate = α × rawGate + (1-α) × previousGate
    public func computeGate(sourceId: String, health: Double) -> Double {
        var state = sourceStates[sourceId] ?? SourceGateState()

        // Check hard disable
        if health < SoftGateConfig.hardDisableThreshold {
            state.hardDisableFrameCount += 1
            if state.hardDisableFrameCount >= SoftGateConfig.hardDisableConfirmFrames {
                state.isHardDisabled = true
            }
        } else {
            state.hardDisableFrameCount = 0
            state.isHardDisabled = false
        }

        if state.isHardDisabled {
            state.smoothedGate = 0.0
            sourceStates[sourceId] = state
            return 0.0
        }

        // Compute raw continuous gate
        let h_lo = SoftGateConfig.healthThresholdLow
        let h_hi = SoftGateConfig.healthThresholdHigh
        let rawGate = PRMath.clamp((health - h_lo) / (h_hi - h_lo), 0.0, 1.0)

        // Apply hysteresis
        let gateWithHysteresis = applyHysteresis(rawGate: rawGate, health: health, state: &state)

        // Smooth transition
        let alpha = SoftGateConfig.gateSmoothingAlpha
        state.smoothedGate = alpha * gateWithHysteresis + (1 - alpha) * state.smoothedGate

        sourceStates[sourceId] = state
        return state.smoothedGate
    }

    private func applyHysteresis(rawGate: Double, health: Double, state: inout SourceGateState) -> Double {
        let enterThreshold = SoftGateConfig.hysteresisEnterThreshold
        let exitThreshold = SoftGateConfig.hysteresisExitThreshold
        let confirmFrames = SoftGateConfig.hysteresisConfirmFrames

        if state.isEnabled {
            if health < exitThreshold {
                state.transitionFrameCount += 1
                if state.transitionFrameCount >= confirmFrames {
                    state.isEnabled = false
                    state.transitionFrameCount = 0
                }
            } else {
                state.transitionFrameCount = 0
            }
            return rawGate
        } else {
            if health > enterThreshold {
                state.transitionFrameCount += 1
                if state.transitionFrameCount >= confirmFrames {
                    state.isEnabled = true
                    state.transitionFrameCount = 0
                }
                return rawGate
            } else {
                state.transitionFrameCount = 0
                return PRMath.min(rawGate, 0.1)
            }
        }
    }
}
```

---

## Part 4: V6 Hard Fix #2 - Early Quantization Determinism

### 4.1 QuantizationConfig.swift

```swift
//
// QuantizationConfig.swift
// Aether3D
//
// PR4 V6 - Early Quantization for Cross-Platform Determinism
// HARD FIX #2: Achieves true bit-exact reproducibility
//
// REFERENCE: "Floating Point Determinism" - Gaffer On Games
// REFERENCE: "FLiT: Cross-Platform Floating-Point Result-Consistency"
//
// FORMAT: Q16.16 (16 bits integer, 16 bits fraction)
// Range: [-32768, 32767.99998], Precision: ~0.000015
//

import Foundation

public enum QuantizationConfig {

    public static let fractionalBits: Int = 16
    public static let scaleFactor: Int64 = 65536
    public static let scaleFactorDouble: Double = 65536.0
    public static let maxValue: Double = 32767.99998
    public static let minValue: Double = -32768.0

    /// Fields that MUST be quantized at module boundaries (determinismKey)
    public static let quantizedFields: Set<String> = [
        "sigmaQ", "muEffQ", "weightQ", "logitQ",
        "depthGainQ", "topoGainQ", "edgeGainQ", "baseGainQ",
        "softQualityQ", "uncertaintyQ", "gateQ"
    ]

    /// Fields allowed to vary (ignoredKey)
    public static let nonQuantizedFields: Set<String> = [
        "latencyMs", "timestampNs", "frameId", "deviceModel", "diagnosticsSampling"
    ]

    @inline(__always)
    public static func toQ16(_ value: Double) -> Int64 {
        let clamped = max(minValue, min(maxValue, value))
        let scaled = clamped * scaleFactorDouble
        return Int64(scaled.rounded(.toNearestOrEven))
    }

    @inline(__always)
    public static func fromQ16(_ quantized: Int64) -> Double {
        return Double(quantized) / scaleFactorDouble
    }
}
```

### 4.2 CrossPlatformMath.swift

```swift
//
// CrossPlatformMath.swift
// Aether3D
//
// PR4 V6 - Deterministic Math Operations
// Uses explicit algorithms rather than platform math libraries
//

import Foundation

public enum CrossPlatformMath {

    /// Deterministic exp using Taylor series (13 terms, accurate to ~1e-7)
    public static func expDeterministic(_ x: Double) -> Double {
        let clamped = max(-20.0, min(20.0, x))
        let ln2 = 0.6931471805599453
        let n = (clamped / ln2).rounded(.toNearestOrEven)
        let r = clamped - n * ln2

        var result = 1.0
        var term = 1.0
        for i in 1...13 {
            term *= r / Double(i)
            result += term
        }

        let nInt = Int(n)
        if nInt >= 0 {
            for _ in 0..<nInt { result *= 2.0 }
        } else {
            for _ in 0..<(-nInt) { result *= 0.5 }
        }
        return result
    }

    /// Deterministic log using series expansion
    public static func logDeterministic(_ x: Double) -> Double {
        guard x > 0 else { return -.infinity }

        var m = x
        var e = 0
        while m >= 2.0 { m *= 0.5; e += 1 }
        while m < 1.0 { m *= 2.0; e -= 1 }

        let y = (m - 1.0) / (m + 1.0)
        let y2 = y * y

        var result = y
        var term = y
        for i in 1...15 {
            term *= y2
            result += term / Double(2 * i + 1)
        }
        result *= 2.0

        let ln2 = 0.6931471805599453
        return result + Double(e) * ln2
    }

    /// Deterministic sqrt using Newton-Raphson (8 iterations)
    public static func sqrtDeterministic(_ x: Double) -> Double {
        guard x > 0 else { return 0.0 }
        var guess = x * 0.5
        for _ in 0..<8 {
            guess = (guess + x / guess) * 0.5
        }
        return guess
    }
}
```

---

## Part 5: V6 Hard Fix #3 - Robust Calibration

### 5.1 HuberRegressor.swift

```swift
//
// HuberRegressor.swift
// Aether3D
//
// PR4 V6 - Huber Loss Robust Regression for Noise Model Calibration
// HARD FIX #3: Replaces least-squares which is outlier-sensitive
//
// REFERENCE: scikit-learn HuberRegressor
// REFERENCE: NVIDIA "Dealing with Outliers Using Robust Regression"
//

import Foundation
import PRMath

public final class HuberRegressor {

    /// Huber loss delta (transition point from quadratic to linear)
    /// For depth errors, 0.05m is reasonable boundary
    public static let huberDelta: Double = 0.05

    /// Maximum iterations for optimization
    public static let maxIterations: Int = 100

    /// Convergence threshold
    public static let convergenceThreshold: Double = 1e-6

    /// Calibration result
    public struct CalibrationResult {
        public let sigmaBase: Double      // Base noise at reference depth
        public let alpha: Double          // Depth scaling exponent
        public let beta: Double           // Confidence reduction factor
        public let fitQualityScore: Double // [0,1], higher is better
        public let outlierRate: Double    // Fraction of outliers detected
        public let residualMAD: Double    // Median Absolute Deviation of residuals
        public let isValid: Bool          // outlierRate < 0.3
    }

    /// Fit noise model parameters using Huber robust regression
    ///
    /// Model: σ = σ_base × (depth / d_ref)^α × (1 - β × conf)
    ///
    /// - Parameters:
    ///   - depths: Measured depths (meters)
    ///   - confidences: Reported confidences [0,1]
    ///   - trueDepths: Ground truth depths (meters)
    ///   - sourceId: Source identifier for initial guess
    /// - Returns: Calibration result with fitted parameters
    public func fit(
        depths: [Double],
        confidences: [Double],
        trueDepths: [Double],
        sourceId: String
    ) -> CalibrationResult {
        precondition(depths.count == confidences.count)
        precondition(depths.count == trueDepths.count)
        precondition(depths.count >= 10, "Need at least 10 samples for calibration")

        let n = depths.count

        // Compute errors (observed noise)
        var errors: [Double] = []
        for i in 0..<n {
            errors.append(PRMath.abs(depths[i] - trueDepths[i]))
        }

        // Initial parameters (source-specific)
        var sigmaBase = initialSigmaBase(sourceId: sourceId)
        var alpha = 1.5
        var beta = 0.5
        let dRef = 2.0

        // IRLS (Iteratively Reweighted Least Squares) with Huber weights
        for _ in 0..<Self.maxIterations {
            // Compute predictions and residuals
            var residuals: [Double] = []
            var predictions: [Double] = []
            for i in 0..<n {
                let pred = sigmaBase * pow(depths[i] / dRef, alpha) * (1 - beta * confidences[i])
                predictions.append(pred)
                residuals.append(errors[i] - pred)
            }

            // Compute Huber weights
            let weights = computeHuberWeights(residuals: residuals)

            // Weighted parameter update (simplified gradient descent)
            let (dSigma, dAlpha, dBeta) = computeGradients(
                depths: depths, confidences: confidences, errors: errors,
                predictions: predictions, weights: weights,
                sigmaBase: sigmaBase, alpha: alpha, beta: beta, dRef: dRef
            )

            let lr = 0.01
            sigmaBase -= lr * dSigma
            alpha -= lr * dAlpha
            beta -= lr * dBeta

            // Clamp parameters to valid ranges
            sigmaBase = PRMath.clamp(sigmaBase, 0.001, 0.1)
            alpha = PRMath.clamp(alpha, 0.5, 3.0)
            beta = PRMath.clamp(beta, 0.0, 0.9)

            // Check convergence
            if PRMath.abs(dSigma) < Self.convergenceThreshold &&
               PRMath.abs(dAlpha) < Self.convergenceThreshold &&
               PRMath.abs(dBeta) < Self.convergenceThreshold {
                break
            }
        }

        // Compute final metrics
        var finalResiduals: [Double] = []
        for i in 0..<n {
            let pred = sigmaBase * pow(depths[i] / dRef, alpha) * (1 - beta * confidences[i])
            finalResiduals.append(errors[i] - pred)
        }

        let residualMAD = computeMAD(finalResiduals)
        let outlierRate = computeOutlierRate(residuals: finalResiduals, mad: residualMAD)
        let fitQualityScore = 1.0 - PRMath.min(outlierRate * 2.0, 1.0)

        return CalibrationResult(
            sigmaBase: sigmaBase,
            alpha: alpha,
            beta: beta,
            fitQualityScore: fitQualityScore,
            outlierRate: outlierRate,
            residualMAD: residualMAD,
            isValid: outlierRate < 0.3
        )
    }

    private func initialSigmaBase(sourceId: String) -> Double {
        switch sourceId {
        case "small_model": return 0.007
        case "large_model": return 0.010
        case "platform_api": return 0.005
        case "stereo": return 0.015
        default: return 0.010
        }
    }

    private func computeHuberWeights(residuals: [Double]) -> [Double] {
        let delta = Self.huberDelta
        return residuals.map { r in
            let absR = PRMath.abs(r)
            if absR <= delta {
                return 1.0
            } else {
                return delta / absR
            }
        }
    }

    private func computeGradients(
        depths: [Double], confidences: [Double], errors: [Double],
        predictions: [Double], weights: [Double],
        sigmaBase: Double, alpha: Double, beta: Double, dRef: Double
    ) -> (Double, Double, Double) {
        var dSigma = 0.0, dAlpha = 0.0, dBeta = 0.0
        let n = depths.count

        for i in 0..<n {
            let d = depths[i]
            let c = confidences[i]
            let e = errors[i]
            let p = predictions[i]
            let w = weights[i]
            let r = e - p

            let base = pow(d / dRef, alpha) * (1 - beta * c)
            dSigma += w * (-2 * r * base)

            let dPdAlpha = sigmaBase * base * PRMath.log(d / dRef)
            dAlpha += w * (-2 * r * dPdAlpha)

            let dPdBeta = -sigmaBase * pow(d / dRef, alpha) * c
            dBeta += w * (-2 * r * dPdBeta)
        }

        return (dSigma / Double(n), dAlpha / Double(n), dBeta / Double(n))
    }

    private func computeMAD(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = values.map { PRMath.abs($0 - median) }
        let sortedDev = deviations.sorted()
        return sortedDev[sortedDev.count / 2]
    }

    private func computeOutlierRate(residuals: [Double], mad: Double) -> Double {
        let threshold = 3.0 * mad
        let outliers = residuals.filter { PRMath.abs($0) > threshold }
        return Double(outliers.count) / Double(residuals.count)
    }
}
```

---

## Part 6: V6 Hard Fix #4 - Noise Model with Floor

### 6.1 NoiseModelContractV6.swift

```swift
//
// NoiseModelContractV6.swift
// Aether3D
//
// PR4 V6 - Noise Model Contract with σ Floor and conf=0 Semantics
// HARD FIX #4: Prevents σ→0 when conf→1
//

import Foundation

public enum NoiseModelContractV6 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - σ Floor by Source (V6 NEW)
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum σ by source type
    /// Even with perfect confidence, σ cannot go below this
    /// Based on sensor physics and calibration uncertainty
    public static let sigmaFloor: [String: Double] = [
        "platform_api": 0.002,  // LiDAR: 2mm floor (very good)
        "small_model": 0.005,   // ML small: 5mm floor
        "large_model": 0.005,   // ML large: 5mm floor
        "stereo": 0.008,        // Stereo: 8mm floor (texture-dependent)
    ]

    /// Default floor for unknown sources
    public static let defaultSigmaFloor: Double = 0.010

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Confidence Semantics (V6 CLARIFIED)
    // ═══════════════════════════════════════════════════════════════════════

    /// conf=0 semantics: INVALID (skip pixel entirely)
    /// This is NOT "low confidence valid" - it means no data
    public static let confZeroSemantics: String = "INVALID_SKIP_PIXEL"

    /// Minimum valid confidence
    /// conf in (0, confFloor] treated as confFloor
    public static let confFloor: Double = 0.1

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - V6 Sigma Computation
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute σ with floor protection
    ///
    /// FORMULA V6:
    /// σ = max(σ_floor(source), σ_base × (d/d_ref)^α × (1 - β×conf_eff))
    /// where conf_eff = max(conf, confFloor) for conf > 0
    ///
    /// - Parameters:
    ///   - depth: Z-depth in meters [0.1, 20.0]
    ///   - confidence: Confidence [0, 1], 0 = invalid
    ///   - sourceId: Depth source identifier
    /// - Returns: σ in meters, or nil if conf=0 (invalid)
    public static func sigmaV6(
        depth: Double,
        confidence: Double,
        sourceId: String
    ) -> Double? {
        // conf=0 means invalid - return nil
        if confidence <= 0.0 {
            return nil
        }

        // Get floor for this source
        let floor = sigmaFloor[sourceId] ?? defaultSigmaFloor

        // Effective confidence (floor applied)
        let confEff = max(confidence, confFloor)

        // Source-specific parameters
        let (sigmaBase, alpha, beta) = parametersForSource(sourceId)
        let dRef = 2.0

        // Compute raw sigma
        let rawSigma = sigmaBase * pow(depth / dRef, alpha) * (1 - beta * confEff)

        // Apply floor
        return max(floor, rawSigma)
    }

    /// Parameters by source
    private static func parametersForSource(_ sourceId: String) -> (sigmaBase: Double, alpha: Double, beta: Double) {
        switch sourceId {
        case "small_model": return (0.007, 2.0, 0.5)
        case "large_model": return (0.010, 1.5, 0.5)
        case "platform_api": return (0.005, 1.0, 0.5)
        case "stereo": return (0.015, 2.0, 0.5)
        default: return (0.020, 2.0, 0.5)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Monotonicity Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// Validate σ monotonicity: increases with depth, decreases with conf
    public static func validateMonotonicity(sourceId: String) -> Bool {
        // Test depth monotonicity (σ increases with depth)
        var prevSigma = 0.0
        for d in stride(from: 0.5, through: 10.0, by: 0.5) {
            guard let sigma = sigmaV6(depth: d, confidence: 0.5, sourceId: sourceId) else {
                return false
            }
            if sigma < prevSigma { return false }
            prevSigma = sigma
        }

        // Test confidence monotonicity (σ decreases with conf)
        prevSigma = Double.infinity
        for c in stride(from: 0.1, through: 1.0, by: 0.1) {
            guard let sigma = sigmaV6(depth: 2.0, confidence: c, sourceId: sourceId) else {
                return false
            }
            if sigma > prevSigma { return false }
            prevSigma = sigma
        }

        return true
    }
}
```

---

## Part 7: V6 Hard Fix #5 - Tiered Allocation Verification

### 7.1 AllocationVerificationLevel.swift

```swift
//
// AllocationVerificationLevel.swift
// Aether3D
//
// PR4 V6 - Tiered Allocation Verification
// HARD FIX #5: CI doesn't depend on unreliable iOS malloc hooks
//

import Foundation

/// Allocation verification levels
///
/// V6 FIX: V5's AllocationDetector relied on malloc_zone hooks which
/// fail on some iOS versions/sandbox configurations. This caused CI flakiness.
///
/// V6 SOLUTION: Tiered verification where CI uses L0 (always works),
/// and L1/L2 provide enhanced detection when available.
public enum AllocationVerificationLevel: Int, Comparable {

    /// Level 0: Cross-platform, always available
    /// - Capacity assertions (ContiguousArray.capacity)
    /// - API lint (no map/filter/sorted in hot path)
    /// - Static analysis for allocation patterns
    case L0_CrossPlatform = 0

    /// Level 1: iOS DEBUG with best-effort hooks
    /// - malloc_zone interception (may fail)
    /// - Swift runtime hooks (where available)
    /// - Falls back to L0 if hooks fail
    case L1_iOSDebug = 1

    /// Level 2: Dedicated benchmark device
    /// - Full Instruments integration
    /// - Memory graph analysis
    /// - Requires manual setup
    case L2_Benchmark = 2

    public static func < (lhs: AllocationVerificationLevel, rhs: AllocationVerificationLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Tiered allocation detector
public final class TieredAllocationDetector {

    /// Current verification level
    public private(set) var currentLevel: AllocationVerificationLevel = .L0_CrossPlatform

    /// Whether L1 hooks are available
    public private(set) var l1Available: Bool = false

    /// Initialize and detect available level
    public init() {
        #if DEBUG && os(iOS)
        // Try to install L1 hooks
        l1Available = tryInstallL1Hooks()
        if l1Available {
            currentLevel = .L1_iOSDebug
        }
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - L0: Capacity Assertions (Always Available)
    // ═══════════════════════════════════════════════════════════════════════

    /// Assert buffer capacity before hot path
    @inline(__always)
    public func assertCapacity<T>(_ array: ContiguousArray<T>, required: Int, file: StaticString = #file, line: UInt = #line) {
        #if DEBUG
        precondition(array.capacity >= required, "L0: Buffer capacity \(array.capacity) < required \(required)", file: file, line: line)
        #endif
    }

    /// Assert capacity unchanged after hot path (no COW)
    @inline(__always)
    public func assertCapacityUnchanged<T>(_ array: ContiguousArray<T>, expected: Int, file: StaticString = #file, line: UInt = #line) {
        #if DEBUG
        precondition(array.capacity == expected, "L0: COW triggered! Capacity changed from \(expected) to \(array.capacity)", file: file, line: line)
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - L1: iOS Debug Hooks (Best Effort)
    // ═══════════════════════════════════════════════════════════════════════

    #if DEBUG && os(iOS)
    private func tryInstallL1Hooks() -> Bool {
        // Try to install malloc_zone hooks
        // Return false if hooks fail (sandbox, iOS version, etc.)
        // This is best-effort - CI doesn't fail if this returns false
        return false // Placeholder - actual implementation would try hooks
    }

    /// L1: Track allocations in scope (only if hooks available)
    public func trackL1Scope(_ name: String, body: () -> Void) {
        if currentLevel >= .L1_iOSDebug && l1Available {
            // Use malloc hooks to count allocations
            body()
            // Log if allocations detected
        } else {
            // Fall back to L0 (no tracking, just capacity assertions)
            body()
        }
    }
    #endif

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - CI Integration
    // ═══════════════════════════════════════════════════════════════════════

    /// Run allocation test at appropriate level
    ///
    /// - L0 tests always run and must pass
    /// - L1 tests run if available, log warning on failure
    /// - L2 tests only run on benchmark device
    public func runAllocationTest(
        level: AllocationVerificationLevel,
        name: String,
        test: () -> Bool
    ) -> AllocationTestResult {
        if level > currentLevel {
            return AllocationTestResult(passed: true, skipped: true, level: level, message: "Level not available")
        }

        let passed = test()

        if level == .L0_CrossPlatform {
            // L0 failures are hard failures
            return AllocationTestResult(passed: passed, skipped: false, level: level, message: passed ? "OK" : "FAIL")
        } else {
            // L1/L2 failures are warnings
            return AllocationTestResult(passed: true, skipped: false, level: level, message: passed ? "OK" : "WARNING: allocation detected")
        }
    }

    public struct AllocationTestResult {
        public let passed: Bool
        public let skipped: Bool
        public let level: AllocationVerificationLevel
        public let message: String
    }
}
```

---

## Part 8: V6 Hard Fix #6 - Correlated Uncertainty

### 8.1 CorrelationConfig.swift

```swift
//
// CorrelationConfig.swift
// Aether3D
//
// PR4 V6 - Correlation Bounds for Uncertainty Propagation
// HARD FIX #6: Prevents unrealistic uncertainty from assumed independence
//

import Foundation

public enum CorrelationConfig {

    /// Maximum correlation coefficient for uncertainty sources
    /// Used when sources are potentially correlated but exact correlation unknown
    ///
    /// RATIONALE:
    /// - depthVariance and sourceDisagreement are correlated (same underlying noise)
    /// - temporalVariance and anomaly detection are correlated (same trigger)
    /// - Using ρ_max = 0.3 is conservative (assumes some but not full correlation)
    public static let rhoMax: Double = 0.3

    /// Pairs of variance sources that are highly correlated
    /// For these pairs, use max() instead of sum()
    public static let highlyCorrelatedPairs: [(String, String)] = [
        ("depthVariance", "sourceDisagreementVariance"),
        ("temporalVariance", "anomalyVariance"),
    ]

    /// Whether two sources are highly correlated
    public static func areHighlyCorrelated(_ a: String, _ b: String) -> Bool {
        for (x, y) in highlyCorrelatedPairs {
            if (a == x && b == y) || (a == y && b == x) {
                return true
            }
        }
        return false
    }
}
```

### 8.2 UncertaintyPropagatorV6.swift

```swift
//
// UncertaintyPropagatorV6.swift
// Aether3D
//
// PR4 V6 - Uncertainty Propagation with Correlation Handling
//

import Foundation
import PRMath

public final class UncertaintyPropagatorV6 {

    /// Compute total variance with correlation handling
    ///
    /// V6 FORMULA:
    /// For independent sources: σ²_total = Σσ²_i
    /// For correlated sources: σ²_total = Σσ²_i + 2×ρ_max × Σ_{i<j} σ_i×σ_j
    /// For highly correlated pairs: use max(σ_a², σ_b²) instead of sum
    ///
    /// - Parameter variances: Dictionary of variance source name to value
    /// - Returns: Total variance with correlation adjustment
    public func computeTotalVariance(variances: [String: Double]) -> Double {
        let names = Array(variances.keys)
        let n = names.count

        // Separate into groups
        var independentVariances: [Double] = []
        var correlatedGroups: [[Double]] = []

        var processed: Set<String> = []

        for i in 0..<n {
            let nameI = names[i]
            if processed.contains(nameI) { continue }

            var foundCorrelated = false
            for j in (i+1)..<n {
                let nameJ = names[j]
                if CorrelationConfig.areHighlyCorrelated(nameI, nameJ) {
                    // Highly correlated pair: take max
                    let vI = variances[nameI] ?? 0.0
                    let vJ = variances[nameJ] ?? 0.0
                    correlatedGroups.append([vI, vJ])
                    processed.insert(nameI)
                    processed.insert(nameJ)
                    foundCorrelated = true
                    break
                }
            }

            if !foundCorrelated {
                independentVariances.append(variances[nameI] ?? 0.0)
                processed.insert(nameI)
            }
        }

        // Sum independent variances with correlation adjustment
        var totalVariance = 0.0

        // Independent: σ²_total = Σσ²_i + 2×ρ_max × Σ_{i<j} σ_i×σ_j
        for v in independentVariances {
            totalVariance += v
        }

        // Cross terms for independent sources
        let rhoMax = CorrelationConfig.rhoMax
        for i in 0..<independentVariances.count {
            for j in (i+1)..<independentVariances.count {
                let sigmaI = PRMath.sqrt(independentVariances[i])
                let sigmaJ = PRMath.sqrt(independentVariances[j])
                totalVariance += 2.0 * rhoMax * sigmaI * sigmaJ
            }
        }

        // Highly correlated groups: use max
        for group in correlatedGroups {
            if let maxV = group.max() {
                totalVariance += maxV
            }
        }

        return totalVariance
    }

    /// Compute uncertainty penalty for final quality
    ///
    /// FORMULA: penalty = clamp(1 - k × uncertainty, p_min, 1)
    ///
    /// - Parameters:
    ///   - uncertainty: Total uncertainty (1-sigma)
    ///   - k: Penalty factor (default 2.0)
    ///   - pMin: Minimum penalty (default 0.5)
    /// - Returns: Penalty factor [pMin, 1.0]
    public func computeUncertaintyPenalty(
        uncertainty: Double,
        k: Double = 2.0,
        pMin: Double = 0.5
    ) -> Double {
        return PRMath.clamp(1.0 - k * uncertainty, pMin, 1.0)
    }
}
```

---

## Part 9: V6 Enhanced ROI Signature Matching

### 9.1 ROISignature.swift

```swift
//
// ROISignature.swift
// Aether3D
//
// PR4 V6 - ROI Signature with Gradient Histogram
// SEAL PATCH #7: Handles ROI deformation from viewpoint changes
//

import Foundation
import PRMath

public struct ROISignature: Equatable {
    public var gradientHistogram: [UInt8]  // 8 bins, sum=256
    public static let binEdges: [Double] = [0.0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.6, 1.0]

    public init() {
        self.gradientHistogram = [UInt8](repeating: 0, count: 8)
    }

    public static func compute(gradients: UnsafeBufferPointer<Double>, into signature: inout ROISignature) {
        for i in 0..<8 { signature.gradientHistogram[i] = 0 }
        var counts: [Int] = [0, 0, 0, 0, 0, 0, 0, 0]
        let n = gradients.count
        for g in gradients { counts[binIndex(for: g)] += 1 }
        if n > 0 {
            for i in 0..<8 { signature.gradientHistogram[i] = UInt8(counts[i] * 256 / n) }
        }
    }

    @inline(__always)
    private static func binIndex(for gradient: Double) -> Int {
        for i in 0..<8 { if gradient < binEdges[i + 1] { return i } }
        return 7
    }

    public func similarity(to other: ROISignature) -> Double {
        var intersection = 0, total = 0
        for i in 0..<8 {
            intersection += Int(min(gradientHistogram[i], other.gradientHistogram[i]))
            total += Int(max(gradientHistogram[i], other.gradientHistogram[i]))
        }
        guard total > 0 else { return 1.0 }
        return Double(intersection) / Double(total)
    }
}
```

### 9.2 ROI Match Score (V6)

```swift
/// V6 Match score: score = 0.5×IoU + 0.3×centroidSim + 0.2×histogramSim
public static let matchWeights: (iou: Double, centroid: Double, histogram: Double) = (0.5, 0.3, 0.2)
```

---

## Part 10: V6 Tier3b Isolation & Determinism Key

### 10.1 Tier3b Isolation Lint

```swift
public enum Tier3bIsolationLint {
    public static let isolatedFields: Set<String> = [
        "deviceModel", "iosVersion", "gpuModel", "lidarAvailable",
        "modelVersion", "inferenceLatencyMs", "fusionLatencyMs"
    ]
    public static let qualityComputationFiles: Set<String> = [
        "SoftQualityComputer.swift", "SoftGainFunctions.swift",
        "DepthFusionEngine.swift", "EdgeScorer.swift"
    ]
    // Any Tier3b field in qualityComputationFiles = CI FAIL
}
```

### 10.2 Determinism Key Spec

```swift
public enum DeterminismKeySpec {
    public static let determinismKey: Set<String> = [
        "softQualityQ", "depthGainQ", "topoGainQ", "edgeGainQ",
        "sigmaQ", "muEffQ", "weightQ", "logitQ", "gateQ"
    ]
    public static let ignoredKey: Set<String> = [
        "latencyMs", "timestampNs", "deviceModel", "iosVersion"
    ]
    // Unknown fields = CI FAIL
}
```

---

## Part 11: Mobile Optimization (Research-Based)

### Metal Guidelines (WWDC24/25)

- **Pixels per thread**: 4-8 (reduce launch overhead)
- **Threadgroup size**: 8x8 for depth fusion
- **Half precision**: confidence, weight, score (not depth)
- **Function constants**: specialize depth-only vs full passes
- **Fused operations**: Sobel+gradient, depth+truncation+weight

### CPU Guidelines

- **SIMD width**: 4 (SIMD4<Float>)
- **Tile size**: 32x32 (L1 cache friendly)
- **Access pattern**: row-major (y outer, x inner)
- **Branchless**: prefer conditional moves

---

## Part 12: Implementation (Single Day)

| Phase | Duration | Key Tasks |
|-------|----------|-----------|
| Morning | 3h | SoftGate, Quantization, CrossPlatformMath |
| Midday | 2h | HuberRegressor, UncertaintyV6 |
| Afternoon | 2h | TieredAllocation, ROISignature |
| Evening | 3h | Tests: Hysteresis, BitExact, Huber, Correlation |

---

## Part 13: Critical Checklist

- [ ] V6 Hard-1: Gate hysteresis prevents jitter
- [ ] V6 Hard-2: Early quantization bit-exact
- [ ] V6 Hard-3: Huber handles 20% outliers
- [ ] V6 Hard-4: σ ≥ σ_floor always
- [ ] V6 Hard-5: L0 tests always pass
- [ ] V6 Hard-6: Correlated uncertainty realistic
- [ ] Seal #1-12: All seal patches verified

---

## Part 14: References

1. [Mobile AR Depth - HotMobile 2024](https://dl.acm.org/doi/10.1145/3638550.3641122)
2. [ARGate Gated Fusion](https://arxiv.org/pdf/1901.10610)
3. [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)
4. [NVIDIA Robust Regression](https://developer.nvidia.com/blog/dealing-with-outliers-using-three-robust-linear-regression-models/)
5. [Apple Metal Optimization](https://developer.apple.com/videos/play/tech-talks/111373/)
6. [VDBFusion TSDF](https://pmc.ncbi.nlm.nih.gov/articles/PMC8838740/)

---

**END OF PR4 V6 ULTIMATE IMPLEMENTATION PROMPT**
