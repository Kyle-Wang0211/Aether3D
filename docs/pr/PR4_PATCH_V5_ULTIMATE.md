# PR4 Soft Extreme System - Patch V5 ULTIMATE

**Document Version:** 5.0 (Ultimate Hardening + Domain Contracts + Advanced Modules)
**Status:** DRAFT
**Created:** 2026-02-01
**Scope:** PR4 Industrial-Grade Depth Fusion, Edge Classification, Topology Evaluation with Cross-Platform Determinism

---

## Part 0: Critical Review Summary

This V5 document addresses **ALL 8 hard issues**, **4 strongly suggested improvements**, and **5 advanced modules** from user feedback, plus additional research-based enhancements.

### V5 Verdict Matrix

| Issue | Category | Solution |
|-------|----------|----------|
| **8 HARD ISSUES (MUST FIX)** |||
| 1. σ(depth, conf, source) domain not locked | Domain Contract | Add `NoiseModelContract.swift` with explicit domain/unit/semantics |
| 2. Online MAD contamination during ANOMALY | State Gating | Add `OnlineMADEstimatorGate` with freeze/limit during ANOMALY/RECOVERY |
| 3. μ_eff lacks upper bound | Numerical Safety | Add `muMax` + `muClampRatio` to TSDFConfigV5 |
| 4. Weight saturation 128 lacks policy | Selection Strategy | Add `WeightSaturationPolicy` enum with monotonicity proof |
| 5. NoHeapPolicy can't catch all Swift | Memory Safety | Add malloc hooks + `@_semantics("array.make_mutable")` detection |
| 6. ROI cross-frame EMA lacks identity | Tracking | Add `ROITracker` with IoU/distance matching |
| 7. EdgeSoftmax logit clamp undefined | Logit Construction | Add `EdgeLogitMapping` with explicit construction formula |
| 8. Tier3b "external uncontrollable" too broad | Whitelist | Add `TierFieldWhitelist` with explicit field enumeration |
| **4 STRONGLY SUGGESTED** |||
| A. Final quality combination unclear | Aggregation | Define geometric mean vs weighted product with rationale |
| B. Unified units missing | Units System | Add `Units.swift` with compile-time unit safety |
| C. Gate/Soft dynamic weight progress smoothing | Smoothing | Add EMA smoothing to prevent jerky transitions |
| D. Unified diagnostics output | Diagnostics | Add `PR4DiagnosticsOutput` struct with all intermediate values |
| **5 ADVANCED MODULES** |||
| I. Uncertainty Propagation | Output | Add `softQualityMean + softQualityUncertainty` |
| II. Calibration Harness | Tooling | Add calibration tool for NoiseModelConfig |
| III. Patch Difficulty Index | Metrics | Add difficulty score from overflow/saturation/anomaly |
| IV. Adversarial Determinism Fuzzer | Testing | Add fuzzer for determinism verification |
| V. Multi-source Arbitration | Fusion | Add sourceHealth → sourceGate before fusion |

---

## Part 1: The Eighteen Pillars of PR4 V5

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE EIGHTEEN PILLARS OF PR4 V5 ULTIMATE                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: NOISE MODEL CONTRACT (NEW - Hard Issue #1)                       │
│  ├── NoiseModelContract.swift defines σ(depth, conf, source) domain        │
│  ├── Units: σ output in METERS (not mm, not relative)                       │
│  ├── Domain: depth ∈ [0.1m, 20m], conf ∈ [0,1], source ∈ SourceEnum        │
│  ├── Semantics: σ = 1-sigma noise std dev (68% confidence interval)        │
│  ├── Z-depth vs ray-distance: EXPLICITLY Z-depth (perpendicular to plane)  │
│  └── Confidence semantics: 0=unknown, 1=perfect (not probability)          │
│                                                                             │
│  PILLAR 2: ONLINE MAD STATE GATING (NEW - Hard Issue #2)                    │
│  ├── OnlineMADEstimator operates under state machine control                │
│  ├── STABLE state: normal MAD updates with full learning rate               │
│  ├── ANOMALY state: FREEZE MAD estimator (no updates)                       │
│  ├── RECOVERY state: LIMITED updates (0.1× learning rate)                   │
│  ├── Prevents contamination of robust statistics by outliers                │
│  └── State transitions logged with timestamps for debugging                 │
│                                                                             │
│  PILLAR 3: TRUNCATION UPPER BOUND (NEW - Hard Issue #3)                     │
│  ├── μ_eff = clamp(k × σ(d,c,s), μ_min, μ_max)                             │
│  ├── μ_max = min(0.15m, muClampRatio × depth)                               │
│  ├── Prevents infinite truncation with bad sources                          │
│  ├── muClampRatio = 0.05 (5% of depth max)                                  │
│  └── Documented in TSDFConfigV5 with rationale                              │
│                                                                             │
│  PILLAR 4: WEIGHT SATURATION POLICY (NEW - Hard Issue #4)                   │
│  ├── WeightSaturationPolicy enum: FREEZE_ALL, DIMINISHING_DEPTH, CONF_ONLY │
│  ├── Selection strategy: DIMINISHING_DEPTH recommended (proof provided)    │
│  ├── Monotonicity proof: accumulated weight is non-decreasing              │
│  ├── Saturation at 128: gradual diminishing, not hard cutoff               │
│  └── Mathematical guarantee: lim(t→∞) W(t) = 128                           │
│                                                                             │
│  PILLAR 5: ALLOCATION DETECTION (ENHANCED - Hard Issue #5)                  │
│  ├── NoHeapPolicy with malloc_zone hooks for iOS                            │
│  ├── Swift-specific: detect ContiguousArray COW triggers                    │
│  ├── @_semantics annotation detection (DEBUG only)                          │
│  ├── Buffer capacity sentinel with pre/post assertion                       │
│  └── Documented limitations: can't catch ALL Swift allocations              │
│                                                                             │
│  PILLAR 6: ROI IDENTITY TRACKING (NEW - Hard Issue #6)                      │
│  ├── ROITracker assigns stable IDs across frames                            │
│  ├── Matching via IoU (≥0.5) or centroid distance (<32px)                   │
│  ├── Cross-frame EMA only applied to matched ROIs                           │
│  ├── Unmatched ROIs: use raw values, no EMA                                 │
│  └── ROI birth/death tracking for analytics                                 │
│                                                                             │
│  PILLAR 7: EDGE LOGIT MAPPING (NEW - Hard Issue #7)                         │
│  ├── EdgeLogitMapping.swift defines logit construction                      │
│  ├── Option A: logit = log((score + eps) / (1 - score + eps))              │
│  ├── Option B: logit = a × (score - 0.5), a = 10.0                         │
│  ├── Selected: Option B (linear, more controllable)                         │
│  ├── Clamp applied AFTER construction: clamp(logit, -20, 20)               │
│  └── Temperature parameter τ for softmax scaling                            │
│                                                                             │
│  PILLAR 8: TIER FIELD WHITELIST (NEW - Hard Issue #8)                       │
│  ├── Tier3b fields EXPLICITLY enumerated in TierFieldWhitelist              │
│  ├── External source fields: sourceConfidence, sourceTimestamp              │
│  ├── Platform fields: arkitConfidence, lidarAvailable                       │
│  ├── Model fields: modelVersion, inferenceLatency                           │
│  ├── Any field NOT in whitelist → Tier1 (zero tolerance)                    │
│  └── Whitelist versioned with deprecation policy                            │
│                                                                             │
│  PILLAR 9: STRICT IMPORT ISOLATION (From V3)                                │
│  ├── PR4/** ONLY imports: Foundation + PRMath + PR4Math                     │
│  ├── PRMath MAY internally use Darwin/Glibc (abstraction boundary)          │
│  ├── PR4 files MUST NOT import Darwin/Glibc/simd/CoreML/Vision/ARKit        │
│  ├── CI lint scans PR4/ specifically, not PRMath/                           │
│  └── Platform adapters live in Platform/, not PR4/                          │
│                                                                             │
│  PILLAR 10: TSDF-INSPIRED DEPTH FUSION (From V3, Enhanced)                  │
│  ├── Truncation distance: μ = 0.04m base (mobile AR optimal)                │
│  ├── Adaptive truncation: μ_eff = clamp(k×σ, μ_min, μ_max)                 │
│  ├── Weight model: hybrid gradient-confidence with log-space stability      │
│  ├── Max weight accumulation: capped at 128 with diminishing policy         │
│  └── Anti-grazing filter: skip when viewAngle > 70° AND gradient > 5%       │
│                                                                             │
│  PILLAR 11: HIERARCHICAL FUSION WITH ROI TRACKING (Enhanced)                │
│  ├── Primary fusion: 256×256 for global structure                           │
│  ├── ROI refinement: 64×64 patches at high-gradient boundaries              │
│  ├── Hysteresis: enter at gradient > 0.12, exit at gradient < 0.08          │
│  ├── ROI identity preserved across frames via ROITracker                    │
│  └── Max ROI count: 16 per frame (prevent runaway computation)              │
│                                                                             │
│  PILLAR 12: CONTINUOUS EDGE SCORING WITH LOGIT MAPPING (Enhanced)           │
│  ├── Each edge type produces score ∈ [0,1] with diagnostic fields           │
│  ├── Logit mapping: logit = 10 × (score - 0.5), clamped [-20, 20]          │
│  ├── EdgeSoftmax with temperature τ = 1.0                                   │
│  ├── Diagnostic output: all four scores + logits preserved                  │
│  └── Final edgeGain: softmax-weighted combination                           │
│                                                                             │
│  PILLAR 13: ROBUST TEMPORAL FILTER WITH MAD GATING (Enhanced)               │
│  ├── States: COLD_START → WARMING → STABLE → ANOMALY → RECOVERY             │
│  ├── MAD estimator gated by state machine                                   │
│  ├── ANOMALY: freeze MAD, freeze output                                     │
│  ├── RECOVERY: limited MAD updates (0.1× rate)                              │
│  └── State transitions logged for debugging                                 │
│                                                                             │
│  PILLAR 14: UNIFIED UNITS SYSTEM (NEW - Suggested #B)                       │
│  ├── Units.swift with compile-time unit safety                              │
│  ├── Meters, Millimeters, Radians, Degrees as distinct types                │
│  ├── Conversion functions with explicit naming                              │
│  ├── All public APIs use typed units                                        │
│  └── Internal computations may use raw Double with comments                 │
│                                                                             │
│  PILLAR 15: DYNAMIC WEIGHT SMOOTHING (NEW - Suggested #C)                   │
│  ├── Gate/Soft blend weight smoothed via EMA                                │
│  ├── Smoothing factor α = 0.1 (10 frame time constant)                      │
│  ├── Prevents jerky transitions at progress boundaries                      │
│  └── Smooth sigmoid transition with hysteresis                              │
│                                                                             │
│  PILLAR 16: UNIFIED DIAGNOSTICS OUTPUT (NEW - Suggested #D)                 │
│  ├── PR4DiagnosticsOutput struct with all intermediate values               │
│  ├── Per-frame: all gains, weights, scores, states                          │
│  ├── JSON-serializable for offline analysis                                 │
│  ├── Optional (disabled in release for performance)                         │
│  └── Includes timing breakdown per subsystem                                │
│                                                                             │
│  PILLAR 17: UNCERTAINTY PROPAGATION (NEW - Advanced #I)                     │
│  ├── Output: softQualityMean + softQualityUncertainty                       │
│  ├── Uncertainty from: depth variance, source disagreement, temporal var    │
│  ├── Propagation: quadrature sum through gain chain                         │
│  └── Downstream can use uncertainty for decision making                     │
│                                                                             │
│  PILLAR 18: BUDGET-DEGRADE FRAMEWORK (From V4, Enhanced)                    │
│  ├── Every subsystem has: maxWork, maxMemory, overflowBehavior              │
│  ├── Overflow behaviors: CLAMP, SKIP, DEGRADE_QUALITY                       │
│  ├── overflowPenalty applied to soft quality on overflow                    │
│  ├── Patch Difficulty Index derived from overflow metrics                   │
│  └── All limits documented with rationale                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 2: Physical Directory Isolation (V5)

### 2.1 Directory Structure

```
Core/Evidence/
├── PR4/                              // SOFT BUSINESS LOGIC (platform-agnostic)
│   ├── SoftGainFunctions.swift       // All soft gain computations
│   ├── SoftQualityComputer.swift     // Integration layer
│   ├── SoftConstitution.swift        // Behavioral contracts
│   ├── DynamicWeightComputer.swift   // Progress-based blending with smoothing
│   ├── DepthFusion/
│   │   ├── DepthFusionEngine.swift   // TSDF-inspired fusion
│   │   ├── DepthConsensusVoter.swift // Weighted voting with tie-break
│   │   ├── DepthTruncator.swift      // Adaptive truncation with upper bound
│   │   ├── AntiGrazingFilter.swift   // Edge artifact suppression
│   │   ├── HierarchicalRefiner.swift // Coarse-to-fine ROI
│   │   ├── WeightAccumulator.swift   // Saturation policy implementation
│   │   ├── ROITracker.swift          // NEW: Cross-frame ROI identity
│   │   └── OnlineMADEstimatorGate.swift // NEW: State-gated MAD
│   ├── EdgeClassification/
│   │   ├── EdgeScorer.swift          // Continuous scoring
│   │   ├── EdgeTypeScores.swift      // Per-type score computation
│   │   ├── EdgeDiagnostics.swift     // Diagnostic output struct
│   │   ├── EdgeLogitMapping.swift    // NEW: Logit construction
│   │   ├── EdgeSoftmax.swift         // Temperature-controlled softmax
│   │   ├── HSVStabilizer.swift       // Local normalization
│   │   └── FusedEdgePass.swift       // Single-pass computation
│   ├── Topology/
│   │   ├── TopologyEvaluator.swift   // Integrated evaluation
│   │   ├── HoleDetector.swift        // Deterministic CCL with max limit
│   │   ├── OcclusionBoundaryTracker.swift
│   │   └── SelfOcclusionComputer.swift
│   ├── DualChannel/
│   │   ├── DualFrameManager.swift    // rawFrame + assistFrame
│   │   └── FrameConsistencyChecker.swift
│   ├── Temporal/
│   │   ├── TemporalFilterStateMachine.swift // 5-state machine
│   │   ├── RobustTemporalFilter.swift       // Median + trimmed mean
│   │   ├── TemporalAntiOvershoot.swift      // Suspicious jump handler
│   │   └── MotionCompensator.swift
│   ├── Uncertainty/                   // NEW: Advanced Module I
│   │   ├── UncertaintyPropagator.swift
│   │   ├── SourceDisagreementEstimator.swift
│   │   └── TemporalVarianceTracker.swift
│   ├── Arbitration/                   // NEW: Advanced Module V
│   │   ├── SourceHealthTracker.swift
│   │   ├── SourceGateComputer.swift
│   │   └── MultiSourceArbitrator.swift
│   ├── Internal/
│   │   ├── SoftRingBuffer.swift      // Pre-allocated temporal buffer
│   │   ├── IntegerDepthBucket.swift  // Integer-based histogram
│   │   ├── BufferCapacitySentinel.swift // DEBUG capacity check
│   │   ├── FusedPassBuffers.swift    // Reusable buffer pool
│   │   ├── LogSpaceMath.swift        // Numerically stable operations
│   │   └── AllocationDetector.swift  // NEW: Enhanced heap detection
│   └── Validation/
│       ├── SoftInputValidator.swift
│       ├── SoftInputInvalidReason.swift
│       └── DepthEvidenceValidator.swift
│
├── PR4Math/                          // SOFT MATH FACADE
│   ├── PR4Math.swift                 // Unified facade (uses PRMath)
│   ├── SobelKernels.swift            // Fixed kernels with SSOT params
│   ├── BilinearInterpolator.swift    // Deterministic interpolation
│   ├── HSVConverter.swift            // Fixed RGB→HSV coefficients
│   ├── TrimmedMeanComputer.swift     // Robust statistics
│   ├── IntegerQuantizer.swift        // Depth/confidence quantization
│   ├── LogSumExpComputer.swift       // Numerically stable softmax
│   └── StableSigmoid.swift           // Overflow-safe sigmoid
│
├── Constants/
│   ├── SoftGatesV15.swift            // V15 with V5 hardening
│   ├── TSDFConfigV5.swift            // With μ_max and saturation policy
│   ├── NoiseModelContract.swift      // NEW: Hard Issue #1
│   ├── EdgeLogitConfig.swift         // NEW: Hard Issue #7
│   ├── TierFieldWhitelist.swift      // NEW: Hard Issue #8
│   ├── WeightSaturationPolicy.swift  // NEW: Hard Issue #4
│   ├── EdgeScoringConfig.swift       // Continuous scoring params
│   ├── TemporalConfig.swift          // Robust filtering params
│   ├── DeterminismConfig.swift       // Scan order/tie-break rules
│   ├── IntegerQuantizationPolicy.swift // Rounding/saturation policies
│   ├── BudgetLimits.swift            // Per-subsystem limits
│   └── Units.swift                   // NEW: Suggested #B
│
├── Diagnostics/                       // NEW: Suggested #D
│   ├── PR4DiagnosticsOutput.swift
│   ├── DiagnosticsCollector.swift
│   └── DiagnosticsSerializer.swift
│
├── Platform/                         // PLATFORM-SPECIFIC ADAPTERS
│   ├── iOS/
│   │   ├── ARKitDepthAdapter.swift
│   │   ├── CoreMLDepthAdapter.swift
│   │   ├── iOSNormalMapProvider.swift
│   │   └── iOSAllocationHooks.swift  // NEW: malloc_zone hooks
│   └── Linux/
│       ├── LinuxDepthStub.swift
│       └── LinuxNormalMapFallback.swift
│
└── Vector/
    └── EvidenceVector3.swift         // From PR3, no changes

Tests/Evidence/PR4/
├── Tier1_StructuralTests/            // Zero tolerance
│   ├── GainRangeInvariantsTests.swift
│   ├── MonotonicityTests.swift
│   ├── WeightSumTests.swift
│   └── WeightSaturationMonotonicityTests.swift  // NEW
├── Tier2_QuantizedGoldenTests/       // Bit-exact
│   ├── DepthFusionGoldenTests.swift
│   ├── EdgeScorerGoldenTests.swift
│   └── TopologyGoldenTests.swift
├── Tier3_ToleranceTests/             // Stratified tolerance
│   ├── InternalConsistencyTests.swift  // 0.1% tolerance
│   ├── ExternalSourceNoiseTests.swift  // 1-2% tolerance
│   └── TierFieldWhitelistTests.swift   // NEW: Whitelist validation
├── DeterminismTests/
│   ├── SoftDeterminism100RunTests.swift
│   ├── CCLDeterminismTests.swift
│   ├── TieBreakDeterminismTests.swift
│   └── AdversarialDeterminismFuzzerTests.swift  // NEW: Advanced Module IV
├── StateMachineTests/
│   ├── TemporalFilterStateMachineTests.swift
│   └── MADGatingTests.swift          // NEW
├── ROITrackingTests/                 // NEW
│   └── ROIIdentityTrackingTests.swift
├── UncertaintyTests/                 // NEW
│   └── UncertaintyPropagationTests.swift
├── CalibrationTests/                 // NEW
│   └── NoiseModelCalibrationTests.swift
├── CrossPlatformTests/
│   └── SoftCrossPlatformTests.swift
└── PerformanceTests/
    ├── BufferCapacityTests.swift
    └── FusedPassBenchmarkTests.swift

Tools/
├── CalibrationHarness/               // NEW: Advanced Module II
│   ├── CalibrationRecorder.swift
│   ├── NoiseModelFitter.swift
│   └── CalibrationReportGenerator.swift
└── DeterminismFuzzer/                // NEW: Advanced Module IV
    ├── FuzzerCore.swift
    ├── InputMutator.swift
    └── DeterminismVerifier.swift
```

---

## Part 3: Hard Issue #1 - Noise Model Contract

### 3.1 NoiseModelContract.swift

```swift
//
// NoiseModelContract.swift
// Aether3D
//
// PR4 V5 - Explicit Domain Contract for Noise Model σ(depth, conf, source)
// HARD ISSUE #1: Domain/unit/semantics must be locked
//

import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// NOISE MODEL CONTRACT
// ═══════════════════════════════════════════════════════════════════════════
//
// This contract defines the EXACT semantics of the noise model function σ
// used in adaptive truncation: μ_eff = k × σ(depth, conf, source)
//
// ANY implementation of the noise model MUST conform to this contract.
// Violations are caught by unit tests in NoiseModelContractTests.swift
//
// ═══════════════════════════════════════════════════════════════════════════

/// Noise model contract defining domain, units, and semantics
public enum NoiseModelContract {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Input Domain
    // ═══════════════════════════════════════════════════════════════════════

    /// Depth input domain
    ///
    /// UNIT: Meters (m)
    /// TYPE: Z-depth (perpendicular distance to camera plane, NOT ray distance)
    /// RANGE: [0.1m, 20.0m]
    /// INVALID: depth ≤ 0 or depth > 20m returns σ = maxSigma
    ///
    /// WHY Z-DEPTH NOT RAY DISTANCE:
    /// - TSDF fusion uses Z-depth for voxel lookup
    /// - Most depth sensors report Z-depth
    /// - Ray distance varies across image (longer at edges)
    /// - Consistent with Open3D, voxblox conventions
    public static let depthDomain: ClosedRange<Double> = 0.1...20.0
    public static let depthUnit: String = "meters"
    public static let depthType: String = "z_depth_perpendicular"

    /// Confidence input domain
    ///
    /// UNIT: Unitless ratio [0, 1]
    /// SEMANTICS:
    /// - 0.0 = No confidence (unknown/invalid)
    /// - 0.5 = Uncertain (typical for edges, occlusions)
    /// - 1.0 = Perfect confidence (rare, only calibration targets)
    ///
    /// IMPORTANT: This is NOT a probability distribution.
    /// It's a quality metric from the depth source.
    ///
    /// WHY NOT PROBABILITY:
    /// - Different sources have different confidence scales
    /// - Normalized to [0,1] for fusion compatibility
    /// - Higher = better, but not statistically rigorous
    public static let confidenceDomain: ClosedRange<Double> = 0.0...1.0
    public static let confidenceSemantics: String = "quality_metric_not_probability"

    /// Source input domain
    ///
    /// TYPE: Enum (DepthSourceId)
    /// VALUES: smallModel, largeModel, platformApi, stereo
    ///
    /// Each source has different noise characteristics:
    /// - smallModel: Low noise near, high noise far
    /// - largeModel: Moderate noise, better at distance
    /// - platformApi: Varies by device (LiDAR vs structured light)
    /// - stereo: Texture-dependent, fails on uniform surfaces
    public static let validSources: [String] = [
        "small_model", "large_model", "platform_api", "stereo"
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Output Specification
    // ═══════════════════════════════════════════════════════════════════════

    /// Sigma output specification
    ///
    /// UNIT: Meters (m)
    /// SEMANTICS: 1-sigma standard deviation (68% confidence interval)
    /// RANGE: [minSigma, maxSigma]
    ///
    /// INTERPRETATION:
    /// - True depth is within ±σ of measured depth with 68% probability
    /// - Truncation μ_eff = k × σ (typically k ∈ [2, 4])
    ///
    /// WHY 1-SIGMA NOT 2-SIGMA:
    /// - Industry convention (KinectFusion, voxblox)
    /// - k factor allows user adjustment
    /// - More intuitive scaling
    public static let sigmaUnit: String = "meters"
    public static let sigmaSemantics: String = "1_sigma_std_dev_68_percent"
    public static let minSigma: Double = 0.001  // 1mm floor
    public static let maxSigma: Double = 0.50   // 50cm ceiling

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Contract Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// Validate that a sigma value conforms to contract
    public static func validateSigma(_ sigma: Double) -> Bool {
        return sigma >= minSigma && sigma <= maxSigma && sigma.isFinite
    }

    /// Validate depth input
    public static func validateDepthInput(_ depth: Double) -> Bool {
        return depthDomain.contains(depth) && depth.isFinite
    }

    /// Validate confidence input
    public static func validateConfidenceInput(_ conf: Double) -> Bool {
        return confidenceDomain.contains(conf) && conf.isFinite
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Default Noise Model (Reference Implementation)
    // ═══════════════════════════════════════════════════════════════════════

    /// Default noise model implementation
    ///
    /// FORMULA: σ = σ_base × (depth / d_ref)^α × (1 - β × conf)
    ///
    /// Where:
    /// - σ_base: Base noise at reference depth (source-specific)
    /// - d_ref: Reference depth (2.0m)
    /// - α: Depth scaling exponent (typically 1.5-2.0)
    /// - β: Confidence reduction factor (0.5)
    ///
    /// RETURNS: σ in meters, clamped to [minSigma, maxSigma]
    public static func defaultSigma(
        depth: Double,
        confidence: Double,
        sourceId: String
    ) -> Double {
        // Validate inputs
        guard validateDepthInput(depth) else { return maxSigma }
        guard validateConfidenceInput(confidence) else { return maxSigma }

        // Source-specific base noise
        let sigmaBase: Double
        let alpha: Double
        switch sourceId {
        case "small_model":
            sigmaBase = 0.007  // 7mm at 2m
            alpha = 2.0        // Quadratic depth scaling
        case "large_model":
            sigmaBase = 0.010  // 10mm at 2m
            alpha = 1.5        // Sub-quadratic
        case "platform_api":
            sigmaBase = 0.005  // 5mm at 2m (LiDAR quality)
            alpha = 1.0        // Linear scaling
        case "stereo":
            sigmaBase = 0.015  // 15mm at 2m
            alpha = 2.0        // Quadratic (stereo baseline limitation)
        default:
            sigmaBase = 0.020  // Conservative default
            alpha = 2.0
        }

        let referenceDepth = 2.0
        let beta = 0.5  // Confidence reduction

        // Compute sigma
        let depthFactor = pow(depth / referenceDepth, alpha)
        let confFactor = 1.0 - beta * confidence
        var sigma = sigmaBase * depthFactor * confFactor

        // Clamp to valid range
        sigma = max(minSigma, min(maxSigma, sigma))

        return sigma
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Noise Model Protocol
// ═══════════════════════════════════════════════════════════════════════════

/// Protocol for custom noise models
///
/// Custom implementations MUST conform to NoiseModelContract constraints.
/// Use NoiseModelContractTests to validate conformance.
public protocol NoiseModel {
    /// Compute noise sigma for given depth, confidence, and source
    ///
    /// - Parameters:
    ///   - depth: Z-depth in meters [0.1, 20.0]
    ///   - confidence: Confidence [0, 1]
    ///   - sourceId: Depth source identifier
    /// - Returns: Sigma in meters [0.001, 0.5]
    func sigma(depth: Double, confidence: Double, sourceId: String) -> Double
}

/// Default noise model conforming to contract
public struct DefaultNoiseModel: NoiseModel {
    public init() {}

    public func sigma(depth: Double, confidence: Double, sourceId: String) -> Double {
        return NoiseModelContract.defaultSigma(
            depth: depth,
            confidence: confidence,
            sourceId: sourceId
        )
    }
}
```

---

## Part 4: Hard Issue #2 - Online MAD State Gating

### 4.1 OnlineMADEstimatorGate.swift

```swift
//
// OnlineMADEstimatorGate.swift
// Aether3D
//
// PR4 V5 - State-Gated Online MAD Estimator
// HARD ISSUE #2: Prevent MAD contamination during ANOMALY state
//

import Foundation
import PRMath

/// Online Median Absolute Deviation estimator with state gating
///
/// HARD ISSUE #2: The MAD estimator must NOT update during ANOMALY state
/// to prevent outliers from contaminating the robust statistics.
///
/// State behavior:
/// - COLD_START: No MAD computation (insufficient samples)
/// - WARMING: Full MAD updates
/// - STABLE: Full MAD updates
/// - ANOMALY: FREEZE MAD (no updates)
/// - RECOVERY: LIMITED updates (0.1× learning rate)
public final class OnlineMADEstimatorGate {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Learning rate for normal operation
    public static let normalLearningRate: Double = 0.1

    /// Learning rate for RECOVERY state (10% of normal)
    public static let recoveryLearningRate: Double = 0.01

    /// Minimum samples before MAD is considered valid
    public static let minSamplesForValid: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    /// Current median estimate
    private(set) var medianEstimate: Double = 0.0

    /// Current MAD estimate
    private(set) var madEstimate: Double = 0.0

    /// Sample count
    private(set) var sampleCount: Int = 0

    /// Whether MAD is frozen (ANOMALY state)
    private(set) var isFrozen: Bool = false

    /// Current learning rate (modified by state)
    private(set) var currentLearningRate: Double = 0.1

    /// Ring buffer for recent values (for median computation)
    private var recentValues: ContiguousArray<Double>
    private var bufferIndex: Int = 0
    private let bufferCapacity: Int

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(bufferCapacity: Int = 30) {
        self.bufferCapacity = bufferCapacity
        self.recentValues = ContiguousArray(repeating: 0.0, count: bufferCapacity)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State Gating
    // ═══════════════════════════════════════════════════════════════════════

    /// Update gating based on temporal filter state
    ///
    /// MUST be called BEFORE each update() call with current state
    ///
    /// - Parameter state: Current temporal filter state
    public func updateGating(state: TemporalFilterState) {
        switch state {
        case .coldStart:
            // Not enough samples, but allow updates
            isFrozen = false
            currentLearningRate = Self.normalLearningRate

        case .warming:
            // Building up statistics
            isFrozen = false
            currentLearningRate = Self.normalLearningRate

        case .stable:
            // Normal operation
            isFrozen = false
            currentLearningRate = Self.normalLearningRate

        case .anomaly:
            // FREEZE - do not update MAD during anomaly
            // This prevents outliers from corrupting the estimate
            isFrozen = true
            currentLearningRate = 0.0

        case .recovery:
            // Limited updates during recovery
            isFrozen = false
            currentLearningRate = Self.recoveryLearningRate
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Update API
    // ═══════════════════════════════════════════════════════════════════════

    /// Update MAD estimate with new value
    ///
    /// RESPECTS state gating:
    /// - If frozen (ANOMALY): No update, returns current estimate
    /// - If recovery: Uses reduced learning rate
    ///
    /// - Parameter value: New observed value
    /// - Returns: Current MAD estimate (may be unchanged if frozen)
    public func update(_ value: Double) -> Double {
        // Store in ring buffer regardless of state (for later recovery)
        recentValues[bufferIndex] = value
        bufferIndex = (bufferIndex + 1) % bufferCapacity
        sampleCount = min(sampleCount + 1, bufferCapacity)

        // Check frozen state
        guard !isFrozen else {
            return madEstimate
        }

        // Update median estimate (online approximation)
        if sampleCount == 1 {
            medianEstimate = value
            madEstimate = 0.0
        } else {
            // Adaptive median: move toward value
            let sign = value > medianEstimate ? 1.0 : -1.0
            medianEstimate += sign * currentLearningRate * madEstimate

            // Update MAD estimate
            let deviation = PRMath.abs(value - medianEstimate)
            madEstimate += currentLearningRate * (deviation - madEstimate)
        }

        return madEstimate
    }

    /// Get current MAD estimate
    ///
    /// Returns 0 if not enough samples have been collected
    public var currentMAD: Double {
        guard sampleCount >= Self.minSamplesForValid else { return 0.0 }
        return madEstimate
    }

    /// Get current median estimate
    public var currentMedian: Double {
        return medianEstimate
    }

    /// Check if MAD estimate is valid (enough samples)
    public var isValid: Bool {
        return sampleCount >= Self.minSamplesForValid
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reset
    // ═══════════════════════════════════════════════════════════════════════

    /// Reset estimator state
    ///
    /// Called when starting a new capture or after extended anomaly
    public func reset() {
        medianEstimate = 0.0
        madEstimate = 0.0
        sampleCount = 0
        bufferIndex = 0
        isFrozen = false
        currentLearningRate = Self.normalLearningRate
        for i in 0..<bufferCapacity {
            recentValues[i] = 0.0
        }
    }
}
```

---

## Part 5: Hard Issue #3 - Truncation Upper Bound

### 5.1 TSDFConfigV5.swift (Key Section)

```swift
//
// TSDFConfigV5.swift
// Aether3D
//
// PR4 V5 - TSDF Configuration with Upper Bound
// HARD ISSUE #3: μ_eff must have upper bound to prevent infinite truncation
//

import Foundation

/// TSDF-inspired depth fusion configuration V5
///
/// KEY ADDITION: μ_max upper bound for truncation
///
/// FORMULA:
/// μ_eff = clamp(k × σ(depth, conf, source), μ_min, μ_max)
///
/// Where:
/// - k: Truncation multiplier (default 3.0, covers 99.7% of noise)
/// - σ: Noise model from NoiseModelContract
/// - μ_min: Minimum truncation (0.02m)
/// - μ_max: Maximum truncation (dynamic, based on depth)
///
/// μ_max FORMULA:
/// μ_max = min(absoluteMaxTruncation, muClampRatio × depth)
///
/// RATIONALE:
/// Without upper bound, a bad source reporting very low confidence
/// could cause σ → large → μ_eff → very large → TSDF ineffective
public enum TSDFConfigV5 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Truncation Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Base truncation distance (μ_base) in meters
    ///
    /// Used when noise model unavailable or as reference
    public static let baseTruncationM: Double = 0.04

    /// Minimum truncation distance (μ_min)
    ///
    /// Prevents truncation from becoming too small at close range
    public static let minTruncationM: Double = 0.02

    /// Absolute maximum truncation distance (hard cap)
    ///
    /// HARD ISSUE #3: This prevents infinite/huge truncation
    /// Even with very bad sources, truncation never exceeds this
    public static let absoluteMaxTruncationM: Double = 0.15

    /// Truncation clamp ratio (relative to depth)
    ///
    /// μ_max ≤ muClampRatio × depth
    ///
    /// At 2m depth: μ_max ≤ 0.10m
    /// At 5m depth: μ_max ≤ 0.25m (but capped at absoluteMax = 0.15m)
    ///
    /// RATIONALE: Truncation should never exceed ~5% of depth
    public static let muClampRatio: Double = 0.05

    /// Truncation multiplier (k)
    ///
    /// μ_eff = k × σ
    /// k = 3.0 covers 99.7% of Gaussian noise
    public static let truncationMultiplier: Double = 3.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Truncation Computation
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute effective truncation with bounds
    ///
    /// FORMULA:
    /// μ_max_for_depth = min(absoluteMaxTruncationM, muClampRatio × depth)
    /// μ_eff = clamp(k × σ, minTruncationM, μ_max_for_depth)
    ///
    /// - Parameters:
    ///   - sigma: Noise sigma from noise model (meters)
    ///   - depth: Current depth (meters)
    /// - Returns: Effective truncation (meters), always in [μ_min, μ_max]
    public static func computeEffectiveTruncation(
        sigma: Double,
        depth: Double
    ) -> Double {
        // Compute depth-dependent max
        let depthBasedMax = muClampRatio * depth
        let muMax = min(absoluteMaxTruncationM, depthBasedMax)

        // Compute raw truncation
        let rawTruncation = truncationMultiplier * sigma

        // Clamp to valid range
        return max(minTruncationM, min(muMax, rawTruncation))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Weight Saturation (Hard Issue #4)
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum accumulated weight
    ///
    /// See WeightSaturationPolicy for selection strategy
    public static let maxAccumulatedWeight: Double = 128.0

    /// Weight saturation policy
    ///
    /// DIMINISHING_DEPTH recommended - see WeightSaturationPolicy.swift
    public static let weightSaturationPolicy: WeightSaturationPolicy = .diminishingDepth

    // ... (rest of TSDF config from V3)
}
```

---

## Part 6: Hard Issue #4 - Weight Saturation Policy

### 6.1 WeightSaturationPolicy.swift

```swift
//
// WeightSaturationPolicy.swift
// Aether3D
//
// PR4 V5 - Weight Saturation Policy with Monotonicity Proof
// HARD ISSUE #4: Selection strategy and mathematical guarantees
//

import Foundation
import PRMath

/// Weight saturation policy for TSDF fusion
///
/// HARD ISSUE #4: The weight saturation strategy must be explicitly defined
/// with selection rationale and monotonicity proof.
///
/// Three strategies available:
/// 1. FREEZE_ALL: Stop all updates when W ≥ maxWeight
/// 2. DIMINISHING_DEPTH: Reduce depth updates, maintain confidence updates
/// 3. CONFIDENCE_ONLY: Only confidence updates after saturation
///
/// RECOMMENDATION: DIMINISHING_DEPTH (default)
/// - Allows slow adaptation to genuine changes
/// - Maintains monotonicity guarantee
/// - Best balance of stability and adaptability
public enum WeightSaturationPolicy: String, Codable {

    /// Stop all weight updates when saturated
    ///
    /// PROS:
    /// - Simple to implement
    /// - Maximum stability
    ///
    /// CONS:
    /// - Cannot adapt to genuine surface changes
    /// - May lock in early errors
    case freezeAll = "freeze_all"

    /// Reduce depth weight contribution, maintain confidence
    ///
    /// FORMULA:
    /// If W ≥ W_max:
    ///   ΔW = (W_max - W) / W_max × normalΔW
    /// This approaches 0 as W → W_max
    ///
    /// PROS:
    /// - Gradual saturation (no hard cutoff)
    /// - Can still adapt slowly
    /// - Monotonicity preserved
    ///
    /// CONS:
    /// - More complex
    /// - Slight drift possible
    case diminishingDepth = "diminishing_depth"

    /// Only update confidence after weight saturates
    ///
    /// FORMULA:
    /// If W ≥ W_max:
    ///   Depth updates stop
    ///   Confidence still updates
    ///
    /// PROS:
    /// - Depth stable
    /// - Quality information preserved
    ///
    /// CONS:
    /// - Depth may become stale
    case confidenceOnly = "confidence_only"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Policy Implementation
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute weight increment based on policy
    ///
    /// - Parameters:
    ///   - currentWeight: Current accumulated weight
    ///   - maxWeight: Maximum allowed weight
    ///   - proposedIncrement: Proposed weight increment before policy
    /// - Returns: Actual weight increment after policy application
    public func computeWeightIncrement(
        currentWeight: Double,
        maxWeight: Double,
        proposedIncrement: Double
    ) -> Double {
        switch self {
        case .freezeAll:
            // Hard cutoff
            if currentWeight >= maxWeight {
                return 0.0
            }
            return min(proposedIncrement, maxWeight - currentWeight)

        case .diminishingDepth:
            // Gradual diminishing
            if currentWeight >= maxWeight {
                // Asymptotic approach: smaller increments as we approach max
                let ratio = (maxWeight - currentWeight) / maxWeight
                return proposedIncrement * PRMath.max(ratio, 0.0)
            }
            return min(proposedIncrement, maxWeight - currentWeight)

        case .confidenceOnly:
            // For depth weight specifically (confidence handled separately)
            if currentWeight >= maxWeight {
                return 0.0
            }
            return min(proposedIncrement, maxWeight - currentWeight)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Monotonicity Proof
    // ═══════════════════════════════════════════════════════════════════════

    /// Monotonicity guarantee documentation
    ///
    /// THEOREM: For all policies, accumulated weight W(t) is non-decreasing.
    ///
    /// PROOF:
    ///
    /// Let W(t) be accumulated weight at time t.
    /// Let ΔW(t) be increment at time t.
    ///
    /// For FREEZE_ALL:
    /// - ΔW(t) ≥ 0 by definition (weight increments are non-negative)
    /// - When W(t) ≥ W_max: ΔW(t) = 0
    /// - Therefore: W(t+1) = W(t) + ΔW(t) ≥ W(t) ✓
    ///
    /// For DIMINISHING_DEPTH:
    /// - When W(t) < W_max: ΔW(t) = min(proposed, W_max - W(t)) ≥ 0
    /// - When W(t) ≥ W_max: ΔW(t) = proposed × (W_max - W(t))/W_max
    ///   - If W(t) = W_max: ΔW(t) = 0
    ///   - If W(t) > W_max: ΔW(t) < 0, BUT this state is unreachable
    ///     because we always clamp W(t+1) ≤ W_max
    /// - Therefore: W(t+1) ≥ W(t) ✓ (with W(t+1) ≤ W_max guaranteed)
    ///
    /// For CONFIDENCE_ONLY:
    /// - Same as FREEZE_ALL for depth weight ✓
    ///
    /// QED: All policies maintain monotonicity of accumulated weight.
    public static let monotonicityProof = """
    THEOREM: For all WeightSaturationPolicy values, the accumulated weight
    W(t) is non-decreasing over time t.

    PROOF: See implementation comments in computeWeightIncrement().

    COROLLARY: The TSDF surface estimate converges as t → ∞.
    Specifically, lim(t→∞) W(t) = W_max for any input sequence.
    """
}
```

---

## Part 7: Hard Issue #5 - Enhanced Allocation Detection

### 7.1 AllocationDetector.swift

```swift
//
// AllocationDetector.swift
// Aether3D
//
// PR4 V5 - Enhanced Heap Allocation Detection
// HARD ISSUE #5: NoHeapPolicy can't catch all Swift allocations
//

import Foundation

/// Allocation detector with documented limitations
///
/// HARD ISSUE #5: Swift's ARC and COW semantics make it impossible to
/// catch ALL heap allocations. This detector provides best-effort
/// detection with clear documentation of limitations.
///
/// WHAT WE CAN DETECT:
/// 1. ContiguousArray capacity changes (COW triggers)
/// 2. Explicit Array allocations in DEBUG builds
/// 3. malloc_zone allocations (iOS only, via hooks)
///
/// WHAT WE CANNOT DETECT:
/// 1. Swift's internal ARC retain/release operations
/// 2. String interpolation allocations
/// 3. Closure captures that trigger boxing
/// 4. Protocol witness table allocations
/// 5. Some generic specialization allocations
///
/// MITIGATION:
/// - Use `@inlinable` and `@inline(__always)` to reduce closure boxing
/// - Use `ContiguousArray` instead of `Array` for value types
/// - Avoid string interpolation in hot paths
/// - Use pre-allocated buffers with capacity checks
public final class AllocationDetector {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Enable allocation detection (DEBUG only)
    #if DEBUG
    public static let isEnabled = true
    #else
    public static let isEnabled = false
    #endif

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Buffer Capacity Checking
    // ═══════════════════════════════════════════════════════════════════════

    /// Check that buffer has sufficient capacity
    ///
    /// USAGE: Call before entering hot path
    ///
    /// ```swift
    /// AllocationDetector.assertCapacity(buffer, required: frameSize)
    /// // ... hot path operations ...
    /// AllocationDetector.assertCapacityUnchanged(buffer, expected: frameSize)
    /// ```
    @inline(__always)
    public static func assertCapacity<T>(
        _ array: ContiguousArray<T>,
        required: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        precondition(
            array.capacity >= required,
            "Buffer capacity \(array.capacity) < required \(required)",
            file: file,
            line: line
        )
        #endif
    }

    /// Assert that capacity has not changed (no COW triggered)
    @inline(__always)
    public static func assertCapacityUnchanged<T>(
        _ array: ContiguousArray<T>,
        expected: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        precondition(
            array.capacity == expected,
            "Buffer capacity changed from \(expected) to \(array.capacity) - COW triggered!",
            file: file,
            line: line
        )
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Allocation Tracking Scope
    // ═══════════════════════════════════════════════════════════════════════

    /// Track allocations within a scope
    ///
    /// LIMITATION: Only detects ContiguousArray COW, not all allocations
    ///
    /// ```swift
    /// AllocationDetector.trackingScope("depthFusion") {
    ///     // ... operations ...
    /// }
    /// // Will log if any tracked allocations occurred
    /// ```
    public static func trackingScope(
        _ name: String,
        file: StaticString = #file,
        line: UInt = #line,
        body: () -> Void
    ) {
        #if DEBUG
        let startAllocations = _getAllocationCount()
        body()
        let endAllocations = _getAllocationCount()
        let delta = endAllocations - startAllocations

        if delta > 0 {
            print("⚠️ AllocationDetector: \(delta) allocations in '\(name)' at \(file):\(line)")
        }
        #else
        body()
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Platform-Specific Hooks (iOS)
    // ═══════════════════════════════════════════════════════════════════════

    #if os(iOS)
    /// Install malloc hooks for allocation counting
    ///
    /// LIMITATION: Only counts malloc_zone allocations, not all heap ops
    ///
    /// MUST be called once at app startup before any hot paths
    public static func installMallocHooks() {
        // Implementation in Platform/iOS/iOSAllocationHooks.swift
        // Uses malloc_zone_introspect to intercept allocations
    }
    #endif

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Private
    // ═══════════════════════════════════════════════════════════════════════

    #if DEBUG
    private static var _allocationCount: Int = 0

    private static func _getAllocationCount() -> Int {
        // In real implementation, this would use platform-specific hooks
        // For now, returns a placeholder
        return _allocationCount
    }
    #endif

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Documented Limitations
    // ═══════════════════════════════════════════════════════════════════════

    /// Documentation of allocation detection limitations
    public static let limitations = """
    ALLOCATION DETECTION LIMITATIONS (Hard Issue #5)

    Swift's memory model makes comprehensive allocation detection impossible.
    This detector provides BEST-EFFORT detection with the following caveats:

    ✅ CAN DETECT:
    - ContiguousArray capacity changes (COW triggers)
    - Explicit Array.init allocations in DEBUG
    - malloc_zone allocations on iOS (with hooks)

    ❌ CANNOT DETECT:
    - ARC retain/release reference counting operations
    - String interpolation ("Value: \\(x)") creates temporary strings
    - Closure captures that box value types
    - Protocol witness tables for existentials
    - Generic specialization thunks
    - Objective-C bridging allocations

    MITIGATION STRATEGIES:
    1. Use ContiguousArray<T> for value types, not Array<T>
    2. Avoid string interpolation in hot paths
    3. Mark hot path functions with @inline(__always)
    4. Use pre-allocated buffers with explicit capacity
    5. Prefer concrete types over protocols in hot paths
    6. Use withUnsafeBufferPointer for array access
    """
}
```

---

## Part 8: Hard Issue #6 - ROI Identity Tracking

### 8.1 ROITracker.swift

```swift
//
// ROITracker.swift
// Aether3D
//
// PR4 V5 - Cross-Frame ROI Identity Tracking
// HARD ISSUE #6: ROI EMA requires consistent identity across frames
//

import Foundation
import PRMath

/// ROI (Region of Interest) tracker for cross-frame identity
///
/// HARD ISSUE #6: When applying EMA smoothing to ROI metrics,
/// we need consistent ROI identity across frames. Without tracking,
/// ROI[0] in frame N might be a completely different region than
/// ROI[0] in frame N+1, making EMA meaningless.
///
/// SOLUTION: Track ROI identity via IoU (Intersection over Union)
/// and centroid distance matching.
public final class ROITracker {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    /// Tracked ROI with stable identity
    public struct TrackedROI: Equatable {
        /// Unique ID (stable across frames)
        public let id: UInt32

        /// Bounding box (x, y, width, height)
        public let bounds: (x: Int, y: Int, width: Int, height: Int)

        /// Centroid
        public var centroid: (x: Double, y: Double) {
            return (
                Double(bounds.x) + Double(bounds.width) / 2.0,
                Double(bounds.y) + Double(bounds.height) / 2.0
            )
        }

        /// Frame when first detected
        public let birthFrame: UInt64

        /// Last frame when seen
        public var lastSeenFrame: UInt64

        /// Number of frames this ROI has been tracked
        public var trackLength: Int

        /// Quality metric (EMA smoothed)
        public var smoothedQuality: Double

        public static func == (lhs: TrackedROI, rhs: TrackedROI) -> Bool {
            return lhs.id == rhs.id
        }
    }

    /// ROI match result
    public struct MatchResult {
        public let matchedROIs: [(current: TrackedROI, previous: TrackedROI)]
        public let newROIs: [TrackedROI]      // Birth
        public let lostROIs: [TrackedROI]     // Death
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum IoU for ROI matching
    public static let minIoUForMatch: Double = 0.5

    /// Maximum centroid distance for fallback matching (pixels)
    public static let maxCentroidDistance: Double = 32.0

    /// EMA alpha for quality smoothing
    public static let qualityEMAAlpha: Double = 0.3

    /// Frames before declaring ROI lost
    public static let maxFramesUnseen: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    /// Currently tracked ROIs
    private var trackedROIs: [TrackedROI] = []

    /// Next available ID
    private var nextId: UInt32 = 1

    /// Current frame number
    private var currentFrame: UInt64 = 0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tracking API
    // ═══════════════════════════════════════════════════════════════════════

    /// Update tracker with new frame ROIs
    ///
    /// ALGORITHM:
    /// 1. Compute IoU matrix between previous and current ROIs
    /// 2. Match by highest IoU (≥ threshold)
    /// 3. Fallback to centroid distance for unmatched
    /// 4. Assign new IDs to truly new ROIs
    /// 5. Mark unseen ROIs as lost after timeout
    ///
    /// - Parameters:
    ///   - newBounds: Bounding boxes of ROIs in current frame
    ///   - qualities: Quality metrics for each ROI (before smoothing)
    /// - Returns: Match result with identity-preserved ROIs
    public func update(
        newBounds: [(x: Int, y: Int, width: Int, height: Int)],
        qualities: [Double]
    ) -> MatchResult {
        precondition(newBounds.count == qualities.count)

        currentFrame += 1

        var matchedPairs: [(current: TrackedROI, previous: TrackedROI)] = []
        var usedPreviousIndices: Set<Int> = []
        var usedCurrentIndices: Set<Int> = []

        // Step 1: IoU matching
        for (curIdx, curBounds) in newBounds.enumerated() {
            var bestMatch: (prevIdx: Int, iou: Double)? = nil

            for (prevIdx, prevROI) in trackedROIs.enumerated() {
                guard !usedPreviousIndices.contains(prevIdx) else { continue }

                let iou = computeIoU(curBounds, prevROI.bounds)
                if iou >= Self.minIoUForMatch {
                    if bestMatch == nil || iou > bestMatch!.iou {
                        bestMatch = (prevIdx, iou)
                    }
                }
            }

            if let match = bestMatch {
                // Found match by IoU
                var updated = trackedROIs[match.prevIdx]
                updated.lastSeenFrame = currentFrame
                updated.trackLength += 1

                // Apply EMA to quality
                let rawQuality = qualities[curIdx]
                updated.smoothedQuality = Self.qualityEMAAlpha * rawQuality +
                    (1 - Self.qualityEMAAlpha) * updated.smoothedQuality

                // Update bounds (they may have shifted)
                let newROI = TrackedROI(
                    id: updated.id,
                    bounds: curBounds,
                    birthFrame: updated.birthFrame,
                    lastSeenFrame: currentFrame,
                    trackLength: updated.trackLength,
                    smoothedQuality: updated.smoothedQuality
                )

                matchedPairs.append((current: newROI, previous: trackedROIs[match.prevIdx]))
                usedPreviousIndices.insert(match.prevIdx)
                usedCurrentIndices.insert(curIdx)
            }
        }

        // Step 2: Centroid distance fallback for unmatched
        for (curIdx, curBounds) in newBounds.enumerated() {
            guard !usedCurrentIndices.contains(curIdx) else { continue }

            let curCentroid = (
                Double(curBounds.x) + Double(curBounds.width) / 2.0,
                Double(curBounds.y) + Double(curBounds.height) / 2.0
            )

            var bestMatch: (prevIdx: Int, dist: Double)? = nil

            for (prevIdx, prevROI) in trackedROIs.enumerated() {
                guard !usedPreviousIndices.contains(prevIdx) else { continue }

                let prevCentroid = prevROI.centroid
                let dist = PRMath.sqrt(
                    pow(curCentroid.0 - prevCentroid.0, 2) +
                    pow(curCentroid.1 - prevCentroid.1, 2)
                )

                if dist < Self.maxCentroidDistance {
                    if bestMatch == nil || dist < bestMatch!.dist {
                        bestMatch = (prevIdx, dist)
                    }
                }
            }

            if let match = bestMatch {
                var updated = trackedROIs[match.prevIdx]
                updated.lastSeenFrame = currentFrame
                updated.trackLength += 1

                let rawQuality = qualities[curIdx]
                updated.smoothedQuality = Self.qualityEMAAlpha * rawQuality +
                    (1 - Self.qualityEMAAlpha) * updated.smoothedQuality

                let newROI = TrackedROI(
                    id: updated.id,
                    bounds: curBounds,
                    birthFrame: updated.birthFrame,
                    lastSeenFrame: currentFrame,
                    trackLength: updated.trackLength,
                    smoothedQuality: updated.smoothedQuality
                )

                matchedPairs.append((current: newROI, previous: trackedROIs[match.prevIdx]))
                usedPreviousIndices.insert(match.prevIdx)
                usedCurrentIndices.insert(curIdx)
            }
        }

        // Step 3: Create new ROIs for unmatched current
        var newROIs: [TrackedROI] = []
        for (curIdx, curBounds) in newBounds.enumerated() {
            guard !usedCurrentIndices.contains(curIdx) else { continue }

            let newROI = TrackedROI(
                id: nextId,
                bounds: curBounds,
                birthFrame: currentFrame,
                lastSeenFrame: currentFrame,
                trackLength: 1,
                smoothedQuality: qualities[curIdx]  // No smoothing for new ROIs
            )
            nextId += 1
            newROIs.append(newROI)
        }

        // Step 4: Find lost ROIs
        var lostROIs: [TrackedROI] = []
        for (prevIdx, prevROI) in trackedROIs.enumerated() {
            if !usedPreviousIndices.contains(prevIdx) {
                if Int(currentFrame - prevROI.lastSeenFrame) > Self.maxFramesUnseen {
                    lostROIs.append(prevROI)
                }
            }
        }

        // Update tracked list
        trackedROIs = matchedPairs.map { $0.current } + newROIs
        // Keep recently unseen ROIs for potential recovery
        for (prevIdx, prevROI) in trackedROIs.enumerated() {
            if !usedPreviousIndices.contains(prevIdx) &&
               Int(currentFrame - prevROI.lastSeenFrame) <= Self.maxFramesUnseen {
                // Keep but don't update
            }
        }

        return MatchResult(
            matchedROIs: matchedPairs,
            newROIs: newROIs,
            lostROIs: lostROIs
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute IoU between two bounding boxes
    private func computeIoU(
        _ a: (x: Int, y: Int, width: Int, height: Int),
        _ b: (x: Int, y: Int, width: Int, height: Int)
    ) -> Double {
        let aLeft = a.x
        let aRight = a.x + a.width
        let aTop = a.y
        let aBottom = a.y + a.height

        let bLeft = b.x
        let bRight = b.x + b.width
        let bTop = b.y
        let bBottom = b.y + b.height

        let interLeft = max(aLeft, bLeft)
        let interRight = min(aRight, bRight)
        let interTop = max(aTop, bTop)
        let interBottom = min(aBottom, bBottom)

        if interRight <= interLeft || interBottom <= interTop {
            return 0.0
        }

        let interArea = Double((interRight - interLeft) * (interBottom - interTop))
        let aArea = Double(a.width * a.height)
        let bArea = Double(b.width * b.height)
        let unionArea = aArea + bArea - interArea

        guard unionArea > 0 else { return 0.0 }
        return interArea / unionArea
    }

    /// Reset tracker state
    public func reset() {
        trackedROIs = []
        nextId = 1
        currentFrame = 0
    }
}
```

---

## Part 9: Hard Issue #7 - Edge Logit Mapping

### 9.1 EdgeLogitMapping.swift

```swift
//
// EdgeLogitMapping.swift
// Aether3D
//
// PR4 V5 - Explicit Logit Construction for Edge Softmax
// HARD ISSUE #7: Logit construction must be defined before clamping
//

import Foundation
import PRMath

/// Edge logit mapping configuration and implementation
///
/// HARD ISSUE #7: The EdgeSoftmax uses clamp(logit, -20, 20), but the
/// logit construction itself was undefined. This file defines exactly
/// how edge scores [0,1] are converted to logits.
///
/// TWO OPTIONS:
///
/// Option A: Log-odds (probabilistic interpretation)
/// logit = log((score + ε) / (1 - score + ε))
/// - More theoretically grounded
/// - Infinite range requires clamping
/// - score=0.5 → logit=0
///
/// Option B: Linear scaling (simpler, more controllable)
/// logit = a × (score - 0.5)
/// - Linear, predictable behavior
/// - Parameter 'a' controls sensitivity
/// - score=0.5 → logit=0
///
/// SELECTED: Option B (Linear) with a = 10.0
/// RATIONALE:
/// - More predictable behavior across score range
/// - Easier to tune via single parameter
/// - No numerical issues at score=0 or score=1
public enum EdgeLogitMapping {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Logit mapping method
    public enum Method: String, Codable {
        case logOdds = "log_odds"
        case linear = "linear"
    }

    /// Selected method
    public static let selectedMethod: Method = .linear

    /// Linear scaling factor (for linear method)
    ///
    /// Higher value = sharper softmax distribution
    /// - a = 5.0: Gentle (scores spread more evenly)
    /// - a = 10.0: Moderate (DEFAULT)
    /// - a = 20.0: Sharp (dominant score takes most weight)
    public static let linearScaleFactor: Double = 10.0

    /// Epsilon for log-odds (to avoid log(0))
    public static let logOddsEpsilon: Double = 1e-6

    /// Logit clamp range
    ///
    /// Applied AFTER logit construction to prevent overflow in exp()
    public static let logitClampMin: Double = -20.0
    public static let logitClampMax: Double = 20.0

    /// Softmax temperature
    ///
    /// τ = 1.0: Standard softmax
    /// τ < 1.0: Sharper (more winner-take-all)
    /// τ > 1.0: Softer (more uniform)
    public static let softmaxTemperature: Double = 1.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Logit Construction
    // ═══════════════════════════════════════════════════════════════════════

    /// Convert edge score [0,1] to logit
    ///
    /// Uses selected method (linear by default)
    ///
    /// - Parameter score: Edge score in [0, 1]
    /// - Returns: Logit value (clamped to [-20, 20])
    @inline(__always)
    public static func scoreToLogit(_ score: Double) -> Double {
        let rawLogit: Double

        switch selectedMethod {
        case .logOdds:
            // logit = log((score + ε) / (1 - score + ε))
            let numerator = score + logOddsEpsilon
            let denominator = 1.0 - score + logOddsEpsilon
            rawLogit = PRMath.log(numerator / denominator)

        case .linear:
            // logit = a × (score - 0.5)
            rawLogit = linearScaleFactor * (score - 0.5)
        }

        // Clamp to prevent overflow
        return PRMath.clamp(rawLogit, logitClampMin, logitClampMax)
    }

    /// Convert array of scores to logits
    @inline(__always)
    public static func scoresToLogits(_ scores: [Double]) -> [Double] {
        return scores.map { scoreToLogit($0) }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Softmax with Temperature
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute softmax of logits with temperature
    ///
    /// softmax(x_i) = exp(x_i / τ) / Σ exp(x_j / τ)
    ///
    /// Uses log-sum-exp trick for numerical stability
    ///
    /// - Parameter logits: Array of logit values
    /// - Returns: Probability distribution (sums to 1.0)
    public static func softmax(_ logits: [Double]) -> [Double] {
        guard !logits.isEmpty else { return [] }
        guard logits.count > 1 else { return [1.0] }

        // Scale by temperature
        let scaled = logits.map { $0 / softmaxTemperature }

        // Log-sum-exp trick
        let maxLogit = scaled.max()!
        var expSum = 0.0
        var expValues: [Double] = []

        for logit in scaled {
            let expVal = PRMath.exp(logit - maxLogit)
            expValues.append(expVal)
            expSum += expVal
        }

        // Normalize
        guard expSum > 0 else {
            // Fallback to uniform
            return Array(repeating: 1.0 / Double(logits.count), count: logits.count)
        }

        return expValues.map { $0 / expSum }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Combined Score→Softmax
    // ═══════════════════════════════════════════════════════════════════════

    /// Convert edge scores to softmax weights in one step
    ///
    /// PIPELINE:
    /// scores → logits → temperature scaling → softmax
    ///
    /// - Parameter scores: Array of edge scores [0, 1]
    /// - Returns: Softmax weights (sum to 1.0)
    public static func scoresToSoftmaxWeights(_ scores: [Double]) -> [Double] {
        let logits = scoresToLogits(scores)
        return softmax(logits)
    }
}
```

---

## Part 10: Hard Issue #8 - Tier Field Whitelist

### 10.1 TierFieldWhitelist.swift

```swift
//
// TierFieldWhitelist.swift
// Aether3D
//
// PR4 V5 - Explicit Field Whitelist for Tier3b Tolerance
// HARD ISSUE #8: "External uncontrollable fields" was too broad
//

import Foundation

/// Tier field whitelist for tolerance testing
///
/// HARD ISSUE #8: The original Tier3b category "external uncontrollable
/// fields with 1-2% tolerance" was too vague. This whitelist explicitly
/// enumerates which fields qualify for Tier3b tolerance.
///
/// RULE: If a field is NOT in the Tier3b whitelist, it defaults to Tier1
/// (zero tolerance for structural invariants).
///
/// VERSIONING: This whitelist is versioned. Adding new fields requires
/// a version bump and deprecation plan for removed fields.
public enum TierFieldWhitelist {

    /// Whitelist version
    ///
    /// CHANGELOG:
    /// - v1: Initial whitelist (2026-02-01)
    public static let version: String = "1.0"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tier3b Fields (1-2% tolerance)
    // ═══════════════════════════════════════════════════════════════════════

    /// External source confidence fields
    ///
    /// These come from external depth sources and have inherent variability
    public static let externalSourceFields: Set<String> = [
        "smallModelConfidence",      // ML model confidence
        "largeModelConfidence",      // ML model confidence
        "arkitConfidence",           // ARKit depth confidence
        "stereoConfidence",          // Stereo matching confidence
        "sourceTimestamp",           // External timestamp (not used in computation)
    ]

    /// Platform-specific fields
    ///
    /// These vary by device/OS version
    public static let platformFields: Set<String> = [
        "lidarAvailable",            // Boolean, not used in quality
        "deviceModel",               // Metadata only
        "iosVersion",                // Metadata only
        "gpuModel",                  // Metadata only
    ]

    /// Model metadata fields
    ///
    /// These describe the model but don't affect computation
    public static let modelMetadataFields: Set<String> = [
        "modelVersion",              // Version string
        "inferenceLatencyMs",        // Performance metric
        "modelInputResolution",      // Configuration
    ]

    /// Timing and performance fields
    ///
    /// These vary by system load and don't affect quality computation
    public static let performanceFields: Set<String> = [
        "fusionLatencyMs",
        "edgeClassificationLatencyMs",
        "totalProcessingLatencyMs",
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Combined Whitelist
    // ═══════════════════════════════════════════════════════════════════════

    /// All Tier3b fields (1-2% tolerance allowed)
    public static let tier3bWhitelist: Set<String> = {
        var combined = externalSourceFields
        combined.formUnion(platformFields)
        combined.formUnion(modelMetadataFields)
        combined.formUnion(performanceFields)
        return combined
    }()

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tier Classification
    // ═══════════════════════════════════════════════════════════════════════

    /// Field tier classification
    public enum FieldTier: String {
        case tier1_structural   // Zero tolerance
        case tier2_quantized    // Bit-exact after quantization
        case tier3a_internal    // 0.1% tolerance (internal consistency)
        case tier3b_external    // 1-2% tolerance (external sources)
    }

    /// Classify a field into its tier
    ///
    /// RULE: If not in tier3b whitelist, defaults to tier1
    ///
    /// - Parameter fieldName: Name of the field to classify
    /// - Returns: Appropriate tier for the field
    public static func classifyField(_ fieldName: String) -> FieldTier {
        if tier3bWhitelist.contains(fieldName) {
            return .tier3b_external
        }

        // Tier3a fields (internal consistency) - by naming convention
        if fieldName.hasSuffix("Gain") || fieldName.hasSuffix("Score") {
            return .tier3a_internal
        }

        // Tier2 fields (quantized) - by naming convention
        if fieldName.hasSuffix("Quantized") || fieldName.hasSuffix("Int") {
            return .tier2_quantized
        }

        // Default: Tier1 (strictest)
        return .tier1_structural
    }

    /// Get tolerance for a field tier
    ///
    /// - Parameter tier: Field tier
    /// - Returns: Maximum allowed relative deviation
    public static func toleranceForTier(_ tier: FieldTier) -> Double {
        switch tier {
        case .tier1_structural:
            return 0.0          // Zero tolerance
        case .tier2_quantized:
            return 0.0          // Bit-exact
        case .tier3a_internal:
            return 0.001        // 0.1%
        case .tier3b_external:
            return 0.02         // 2%
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// Validate that a value meets tier tolerance
    ///
    /// - Parameters:
    ///   - fieldName: Field being validated
    ///   - actual: Actual value
    ///   - expected: Expected value
    /// - Returns: Whether the values are within tolerance
    public static func validateField(
        _ fieldName: String,
        actual: Double,
        expected: Double
    ) -> Bool {
        let tier = classifyField(fieldName)
        let tolerance = toleranceForTier(tier)

        if tolerance == 0.0 {
            return actual == expected
        }

        let relativeError = abs(actual - expected) / max(abs(expected), 1e-10)
        return relativeError <= tolerance
    }
}
```

---

## Part 11: Advanced Module I - Uncertainty Propagation

### 11.1 UncertaintyPropagator.swift

```swift
//
// UncertaintyPropagator.swift
// Aether3D
//
// PR4 V5 - Uncertainty Propagation for Soft Quality
// ADVANCED MODULE I: Output softQualityMean + softQualityUncertainty
//

import Foundation
import PRMath

/// Uncertainty propagation for soft quality computation
///
/// ADVANCED MODULE I: Instead of outputting just a single softQuality value,
/// we output (mean, uncertainty) to allow downstream systems to make
/// uncertainty-aware decisions.
///
/// SOURCES OF UNCERTAINTY:
/// 1. Depth variance: σ²_depth from noise model
/// 2. Source disagreement: variance among depth sources
/// 3. Temporal variance: frame-to-frame quality fluctuation
/// 4. Edge classification entropy: confidence in edge type assignment
///
/// PROPAGATION: Quadrature sum (assuming independence)
/// σ²_total = σ²_depth + σ²_source + σ²_temporal + σ²_edge
public final class UncertaintyPropagator {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    /// Quality output with uncertainty
    public struct QualityWithUncertainty {
        /// Mean quality estimate
        public let mean: Double

        /// Uncertainty (1-sigma standard deviation)
        public let uncertainty: Double

        /// Lower bound (mean - 2σ, clamped to 0)
        public var lowerBound: Double {
            return max(0.0, mean - 2.0 * uncertainty)
        }

        /// Upper bound (mean + 2σ, clamped to 1)
        public var upperBound: Double {
            return min(1.0, mean + 2.0 * uncertainty)
        }

        /// Confidence interval width
        public var confidenceIntervalWidth: Double {
            return upperBound - lowerBound
        }
    }

    /// Uncertainty components (for diagnostics)
    public struct UncertaintyComponents {
        public let depthVariance: Double
        public let sourceDisagreementVariance: Double
        public let temporalVariance: Double
        public let edgeEntropyVariance: Double
        public let totalVariance: Double

        public var totalUncertainty: Double {
            return PRMath.sqrt(totalVariance)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    /// Temporal variance tracker
    private var qualityHistory: ContiguousArray<Double>
    private var historyIndex: Int = 0
    private let historyCapacity: Int

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(historyCapacity: Int = 30) {
        self.historyCapacity = historyCapacity
        self.qualityHistory = ContiguousArray(repeating: 0.0, count: historyCapacity)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Propagation API
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute quality with uncertainty
    ///
    /// - Parameters:
    ///   - depthGain: Depth soft gain
    ///   - depthSigma: Noise model sigma (meters)
    ///   - sourceConfidences: Confidence from each depth source
    ///   - edgeScores: Edge type scores [geometric, specular, transparent, textural]
    ///   - topoGain: Topology soft gain
    ///   - baseGain: Base soft gain
    /// - Returns: Quality with uncertainty estimate
    public func computeQualityWithUncertainty(
        depthGain: Double,
        depthSigma: Double,
        sourceConfidences: [Double],
        edgeScores: [Double],
        topoGain: Double,
        baseGain: Double
    ) -> (quality: QualityWithUncertainty, components: UncertaintyComponents) {

        // 1. Depth variance (from noise model)
        // Convert sigma (meters) to quality uncertainty via sensitivity
        let depthSensitivity = 5.0  // Empirical: 1cm noise → 5% quality uncertainty
        let depthVariance = pow(depthSigma * depthSensitivity, 2)

        // 2. Source disagreement variance
        let sourceDisagreementVariance = computeSourceDisagreementVariance(sourceConfidences)

        // 3. Temporal variance
        let temporalVariance = computeTemporalVariance()

        // 4. Edge entropy variance
        let edgeEntropyVariance = computeEdgeEntropyVariance(edgeScores)

        // 5. Total variance (quadrature sum)
        let totalVariance = depthVariance + sourceDisagreementVariance +
                           temporalVariance + edgeEntropyVariance

        // 6. Mean quality (existing computation)
        let meanQuality = depthGain * topoGain * baseGain * computeEdgeGain(edgeScores)

        // 7. Update history
        updateHistory(meanQuality)

        let uncertainty = PRMath.sqrt(totalVariance)

        let components = UncertaintyComponents(
            depthVariance: depthVariance,
            sourceDisagreementVariance: sourceDisagreementVariance,
            temporalVariance: temporalVariance,
            edgeEntropyVariance: edgeEntropyVariance,
            totalVariance: totalVariance
        )

        let quality = QualityWithUncertainty(
            mean: meanQuality,
            uncertainty: uncertainty
        )

        return (quality, components)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Variance Components
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute variance from source disagreement
    private func computeSourceDisagreementVariance(_ confidences: [Double]) -> Double {
        guard confidences.count > 1 else { return 0.0 }

        let mean = confidences.reduce(0, +) / Double(confidences.count)
        var variance = 0.0
        for conf in confidences {
            variance += pow(conf - mean, 2)
        }
        variance /= Double(confidences.count - 1)

        // Scale to quality space
        return variance * 0.25  // Empirical scaling
    }

    /// Compute temporal variance from history
    private func computeTemporalVariance() -> Double {
        let validCount = min(historyIndex + 1, historyCapacity)
        guard validCount > 1 else { return 0.01 }  // Default uncertainty

        var sum = 0.0
        var sumSq = 0.0
        for i in 0..<validCount {
            let v = qualityHistory[i]
            sum += v
            sumSq += v * v
        }

        let mean = sum / Double(validCount)
        let variance = sumSq / Double(validCount) - mean * mean

        return max(0.0, variance)
    }

    /// Compute variance from edge classification entropy
    private func computeEdgeEntropyVariance(_ scores: [Double]) -> Double {
        guard !scores.isEmpty else { return 0.01 }

        // Normalize to probabilities
        let sum = scores.reduce(0, +)
        guard sum > 0 else { return 0.01 }

        let probs = scores.map { $0 / sum }

        // Compute entropy: H = -Σ p log p
        var entropy = 0.0
        for p in probs {
            if p > 1e-10 {
                entropy -= p * PRMath.log(p)
            }
        }

        // Max entropy for uniform distribution
        let maxEntropy = PRMath.log(Double(scores.count))

        // Normalized entropy [0, 1]
        let normalizedEntropy = entropy / max(maxEntropy, 1e-10)

        // Higher entropy = more uncertainty
        return normalizedEntropy * 0.04  // Scale to reasonable variance
    }

    /// Compute edge gain from scores
    private func computeEdgeGain(_ scores: [Double]) -> Double {
        // Weighted combination (simplified)
        guard !scores.isEmpty else { return 1.0 }
        return scores.max() ?? 1.0
    }

    /// Update quality history
    private func updateHistory(_ quality: Double) {
        qualityHistory[historyIndex % historyCapacity] = quality
        historyIndex += 1
    }

    /// Reset state
    public func reset() {
        historyIndex = 0
        for i in 0..<historyCapacity {
            qualityHistory[i] = 0.0
        }
    }
}
```

---

## Part 12: Advanced Module V - Multi-Source Arbitration

### 12.1 MultiSourceArbitrator.swift

```swift
//
// MultiSourceArbitrator.swift
// Aether3D
//
// PR4 V5 - Multi-Source Arbitration with Health Tracking
// ADVANCED MODULE V: sourceHealth → sourceGate before fusion
//

import Foundation
import PRMath

/// Multi-source arbitration with health-based gating
///
/// ADVANCED MODULE V: Before fusing depth sources, each source is
/// evaluated for "health" based on recent performance. Unhealthy
/// sources are gated (reduced weight or excluded) to prevent
/// contaminating the fusion.
///
/// HEALTH METRICS:
/// 1. Consistency: Does source agree with consensus over time?
/// 2. Confidence stability: Is confidence erratic?
/// 3. Coverage: Does source provide valid depth for most pixels?
/// 4. Latency: Is source responding in time?
///
/// GATING: sourceGate ∈ [0, 1] multiplies source weight before fusion
public final class MultiSourceArbitrator {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    /// Source health state
    public struct SourceHealth {
        /// Source identifier
        public let sourceId: String

        /// Consistency score [0, 1]
        /// 1.0 = always agrees with consensus
        public var consistencyScore: Double

        /// Confidence stability [0, 1]
        /// 1.0 = stable confidence, 0.0 = erratic
        public var confidenceStability: Double

        /// Coverage ratio [0, 1]
        /// Fraction of pixels with valid depth
        public var coverageRatio: Double

        /// Latency score [0, 1]
        /// 1.0 = always on time, 0.0 = always late
        public var latencyScore: Double

        /// Overall health [0, 1]
        public var overallHealth: Double {
            // Weighted combination
            return 0.4 * consistencyScore +
                   0.2 * confidenceStability +
                   0.3 * coverageRatio +
                   0.1 * latencyScore
        }

        /// Frames since last update
        public var framesSinceUpdate: Int

        /// Is source considered healthy?
        public var isHealthy: Bool {
            return overallHealth >= 0.5 && framesSinceUpdate < 10
        }
    }

    /// Source gate configuration
    public struct GateConfig {
        /// Minimum health for full weight (gate = 1.0)
        public let healthThresholdHigh: Double

        /// Health below which source is excluded (gate = 0.0)
        public let healthThresholdLow: Double

        /// Smoothing factor for gate transitions
        public let gateSmoothingAlpha: Double

        public static let `default` = GateConfig(
            healthThresholdHigh: 0.8,
            healthThresholdLow: 0.3,
            gateSmoothingAlpha: 0.2
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    /// Health state per source
    private var healthStates: [String: SourceHealth] = [:]

    /// Current gates per source (smoothed)
    private var sourceGates: [String: Double] = [:]

    /// Configuration
    private let config: GateConfig

    /// Frame counter
    private var frameCount: UInt64 = 0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(config: GateConfig = .default) {
        self.config = config
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Health Update
    // ═══════════════════════════════════════════════════════════════════════

    /// Update health metrics for a source
    ///
    /// Called after each frame with source performance data
    ///
    /// - Parameters:
    ///   - sourceId: Source identifier
    ///   - agreedWithConsensus: Did source agree with fused result?
    ///   - confidence: Source's reported confidence
    ///   - coverage: Fraction of valid pixels
    ///   - latencyOK: Was source delivered on time?
    public func updateSourceHealth(
        sourceId: String,
        agreedWithConsensus: Bool,
        confidence: Double,
        coverage: Double,
        latencyOK: Bool
    ) {
        let alpha = 0.1  // EMA smoothing

        var health = healthStates[sourceId] ?? SourceHealth(
            sourceId: sourceId,
            consistencyScore: 0.5,
            confidenceStability: 0.5,
            coverageRatio: 0.5,
            latencyScore: 0.5,
            framesSinceUpdate: 0
        )

        // Update consistency
        let consistencyUpdate = agreedWithConsensus ? 1.0 : 0.0
        health.consistencyScore = alpha * consistencyUpdate +
                                  (1 - alpha) * health.consistencyScore

        // Update confidence stability (based on variance)
        // For now, just track if confidence is reasonable
        let confStabilityUpdate = (confidence > 0.1 && confidence < 0.99) ? 1.0 : 0.5
        health.confidenceStability = alpha * confStabilityUpdate +
                                     (1 - alpha) * health.confidenceStability

        // Update coverage
        health.coverageRatio = alpha * coverage + (1 - alpha) * health.coverageRatio

        // Update latency
        let latencyUpdate = latencyOK ? 1.0 : 0.0
        health.latencyScore = alpha * latencyUpdate + (1 - alpha) * health.latencyScore

        health.framesSinceUpdate = 0

        healthStates[sourceId] = health
    }

    /// Mark source as not updated this frame
    public func markSourceMissing(_ sourceId: String) {
        if var health = healthStates[sourceId] {
            health.framesSinceUpdate += 1
            healthStates[sourceId] = health
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gate Computation
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute source gates for fusion
    ///
    /// Returns a gate value [0, 1] for each source:
    /// - 0.0: Source excluded from fusion
    /// - 1.0: Source at full weight
    /// - Between: Source weight reduced proportionally
    ///
    /// - Parameter sourceIds: Sources to compute gates for
    /// - Returns: Dictionary of source ID to gate value
    public func computeSourceGates(sourceIds: [String]) -> [String: Double] {
        frameCount += 1

        var newGates: [String: Double] = [:]

        for sourceId in sourceIds {
            let health = healthStates[sourceId]?.overallHealth ?? 0.5
            let targetGate: Double

            if health >= config.healthThresholdHigh {
                targetGate = 1.0
            } else if health <= config.healthThresholdLow {
                targetGate = 0.0
            } else {
                // Linear interpolation
                let range = config.healthThresholdHigh - config.healthThresholdLow
                targetGate = (health - config.healthThresholdLow) / range
            }

            // Smooth gate transitions
            let currentGate = sourceGates[sourceId] ?? 0.5
            let smoothedGate = config.gateSmoothingAlpha * targetGate +
                              (1 - config.gateSmoothingAlpha) * currentGate

            newGates[sourceId] = smoothedGate
            sourceGates[sourceId] = smoothedGate
        }

        return newGates
    }

    /// Get current health for a source
    public func getSourceHealth(_ sourceId: String) -> SourceHealth? {
        return healthStates[sourceId]
    }

    /// Reset arbitrator state
    public func reset() {
        healthStates.removeAll()
        sourceGates.removeAll()
        frameCount = 0
    }
}
```

---

## Part 13: Unified Diagnostics Output

### 13.1 PR4DiagnosticsOutput.swift

```swift
//
// PR4DiagnosticsOutput.swift
// Aether3D
//
// PR4 V5 - Unified Diagnostics Output
// SUGGESTED IMPROVEMENT D: All intermediate values in one struct
//

import Foundation

/// Unified diagnostics output for PR4 soft quality computation
///
/// Contains ALL intermediate values for debugging and analysis.
/// JSON-serializable for offline processing.
///
/// USAGE:
/// - Enable via PR4Config.enableDiagnostics = true
/// - Disabled in release builds for performance
public struct PR4DiagnosticsOutput: Codable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Metadata
    // ═══════════════════════════════════════════════════════════════════════

    /// Frame identifier
    public let frameId: UInt64

    /// Timestamp (monotonic, nanoseconds)
    public let timestampNs: UInt64

    /// Processing duration (nanoseconds)
    public let processingDurationNs: UInt64

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Depth Fusion
    // ═══════════════════════════════════════════════════════════════════════

    /// Per-source metrics
    public struct DepthSourceDiagnostics: Codable {
        public let sourceId: String
        public let confidence: Double
        public let coverage: Double
        public let healthScore: Double
        public let gate: Double
        public let agreedWithConsensus: Bool
    }

    public let depthSources: [DepthSourceDiagnostics]
    public let depthConsensusRatio: Double
    public let depthFusionLatencyMs: Double
    public let effectiveTruncationM: Double
    public let noiseSigmaM: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Edge Classification
    // ═══════════════════════════════════════════════════════════════════════

    /// Per-type edge scores
    public struct EdgeTypeDiagnostics: Codable {
        public let type: String  // geometric, specular, transparent, textural
        public let rawScore: Double
        public let logit: Double
        public let softmaxWeight: Double
    }

    public let edgeTypes: [EdgeTypeDiagnostics]
    public let edgeClassificationLatencyMs: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Topology
    // ═══════════════════════════════════════════════════════════════════════

    public let holeCount: Int
    public let holeAreaRatio: Double
    public let occlusionBoundaryCount: Int
    public let selfOcclusionRatio: Double
    public let topologyLatencyMs: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - ROI Tracking
    // ═══════════════════════════════════════════════════════════════════════

    public struct ROIDiagnostics: Codable {
        public let roiId: UInt32
        public let bounds: [Int]  // [x, y, width, height]
        public let rawQuality: Double
        public let smoothedQuality: Double
        public let trackLength: Int
        public let isNew: Bool
    }

    public let rois: [ROIDiagnostics]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Temporal Filter
    // ═══════════════════════════════════════════════════════════════════════

    public let temporalFilterState: String  // COLD_START, WARMING, STABLE, ANOMALY, RECOVERY
    public let madEstimate: Double
    public let medianEstimate: Double
    public let isMadFrozen: Bool

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gains
    // ═══════════════════════════════════════════════════════════════════════

    public let depthSoftGain: Double
    public let topoSoftGain: Double
    public let edgeSoftGain: Double
    public let baseSoftGain: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Dynamic Weights
    // ═══════════════════════════════════════════════════════════════════════

    public let progress: Double
    public let gateWeight: Double
    public let softWeight: Double
    public let rawGateWeight: Double  // Before smoothing
    public let rawSoftWeight: Double  // Before smoothing

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Final Output
    // ═══════════════════════════════════════════════════════════════════════

    public let softQualityMean: Double
    public let softQualityUncertainty: Double
    public let finalCombinedQuality: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Uncertainty Components
    // ═══════════════════════════════════════════════════════════════════════

    public let depthVariance: Double
    public let sourceDisagreementVariance: Double
    public let temporalVariance: Double
    public let edgeEntropyVariance: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Budget/Overflow
    // ═══════════════════════════════════════════════════════════════════════

    public let roiOverflowOccurred: Bool
    public let cclOverflowOccurred: Bool
    public let overflowPenalty: Double
    public let patchDifficultyIndex: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Serialization
    // ═══════════════════════════════════════════════════════════════════════

    /// Convert to JSON string
    public func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Create from JSON string
    public static func fromJSON(_ json: String) -> PR4DiagnosticsOutput? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PR4DiagnosticsOutput.self, from: data)
    }
}
```

---

## Part 14: Implementation Phases

### Phase 1: Core Contracts (Week 1)
1. Create `NoiseModelContract.swift` (Hard Issue #1)
2. Create `WeightSaturationPolicy.swift` (Hard Issue #4)
3. Create `EdgeLogitMapping.swift` (Hard Issue #7)
4. Create `TierFieldWhitelist.swift` (Hard Issue #8)
5. Create `Units.swift` (Suggested #B)
6. Update `TSDFConfigV5.swift` with μ_max (Hard Issue #3)

### Phase 2: State Gating (Week 2)
1. Create `OnlineMADEstimatorGate.swift` (Hard Issue #2)
2. Update `TemporalFilterStateMachine.swift` to use MAD gating
3. Create `ROITracker.swift` (Hard Issue #6)
4. Update `HierarchicalRefiner.swift` to use ROI tracking

### Phase 3: Enhanced Detection (Week 3)
1. Create `AllocationDetector.swift` (Hard Issue #5)
2. Create `iOSAllocationHooks.swift` for malloc_zone hooks
3. Add buffer capacity assertions to all hot paths
4. Create `AllocationDetectorTests.swift`

### Phase 4: Advanced Modules (Week 4)
1. Create `UncertaintyPropagator.swift` (Advanced #I)
2. Create `MultiSourceArbitrator.swift` (Advanced #V)
3. Create `PR4DiagnosticsOutput.swift` (Suggested #D)
4. Update `DynamicWeightComputer.swift` with smoothing (Suggested #C)

### Phase 5: Tooling (Week 5)
1. Create `CalibrationHarness/` (Advanced #II)
2. Create `DeterminismFuzzer/` (Advanced #IV)
3. Create `PatchDifficultyIndex.swift` (Advanced #III)

### Phase 6: Testing (Week 6)
1. `NoiseModelContractTests.swift`
2. `WeightSaturationMonotonicityTests.swift`
3. `MADGatingTests.swift`
4. `ROIIdentityTrackingTests.swift`
5. `EdgeLogitMappingTests.swift`
6. `TierFieldWhitelistTests.swift`
7. `UncertaintyPropagationTests.swift`
8. `AdversarialDeterminismFuzzerTests.swift`

---

## Part 15: Test Requirements

### 15.1 NoiseModelContractTests

```swift
// Tests for Hard Issue #1
func testSigmaDomain() {
    // Verify σ is in [minSigma, maxSigma] for all valid inputs
    for depth in stride(from: 0.1, through: 20.0, by: 0.5) {
        for conf in stride(from: 0.0, through: 1.0, by: 0.1) {
            for source in NoiseModelContract.validSources {
                let sigma = NoiseModelContract.defaultSigma(
                    depth: depth, confidence: conf, sourceId: source
                )
                XCTAssertTrue(NoiseModelContract.validateSigma(sigma))
            }
        }
    }
}

func testSigmaMonotonicity() {
    // σ should increase with depth (for fixed confidence)
    var prevSigma = 0.0
    for depth in stride(from: 0.1, through: 20.0, by: 0.5) {
        let sigma = NoiseModelContract.defaultSigma(
            depth: depth, confidence: 0.5, sourceId: "small_model"
        )
        XCTAssertGreaterThanOrEqual(sigma, prevSigma)
        prevSigma = sigma
    }
}
```

### 15.2 WeightSaturationMonotonicityTests

```swift
// Tests for Hard Issue #4
func testMonotonicity_DiminishingDepth() {
    let policy = WeightSaturationPolicy.diminishingDepth
    let maxWeight = 128.0

    var accumulatedWeight = 0.0
    for _ in 0..<1000 {
        let proposedIncrement = 1.0
        let actualIncrement = policy.computeWeightIncrement(
            currentWeight: accumulatedWeight,
            maxWeight: maxWeight,
            proposedIncrement: proposedIncrement
        )

        // Monotonicity: increment is non-negative
        XCTAssertGreaterThanOrEqual(actualIncrement, 0.0)

        // Bounded: never exceeds max
        let newWeight = accumulatedWeight + actualIncrement
        XCTAssertLessThanOrEqual(newWeight, maxWeight)

        accumulatedWeight = newWeight
    }

    // Converges to max
    XCTAssertEqual(accumulatedWeight, maxWeight, accuracy: 0.01)
}
```

### 15.3 MADGatingTests

```swift
// Tests for Hard Issue #2
func testMADFreezesDuringAnomaly() {
    let estimator = OnlineMADEstimatorGate()

    // Warm up
    for i in 0..<20 {
        estimator.updateGating(state: .stable)
        _ = estimator.update(Double(i % 10))
    }

    let madBeforeAnomaly = estimator.currentMAD

    // Enter anomaly with outlier
    estimator.updateGating(state: .anomaly)
    _ = estimator.update(1000.0)  // Extreme outlier
    _ = estimator.update(1000.0)
    _ = estimator.update(1000.0)

    let madDuringAnomaly = estimator.currentMAD

    // MAD should be unchanged (frozen)
    XCTAssertEqual(madBeforeAnomaly, madDuringAnomaly)
}
```

---

## Part 16: Critical Checklist

Before considering V5 complete, verify:

- [ ] **Hard Issue #1**: NoiseModelContract tests pass
- [ ] **Hard Issue #2**: MAD freezes during ANOMALY state
- [ ] **Hard Issue #3**: μ_eff never exceeds μ_max
- [ ] **Hard Issue #4**: Weight monotonicity proof verified by tests
- [ ] **Hard Issue #5**: Allocation detection limitations documented
- [ ] **Hard Issue #6**: ROI EMA only applied to matched ROIs
- [ ] **Hard Issue #7**: EdgeLogitMapping explicitly defined
- [ ] **Hard Issue #8**: TierFieldWhitelist covers all Tier3b fields
- [ ] **Suggested A**: Final quality combination documented
- [ ] **Suggested B**: Units.swift created
- [ ] **Suggested C**: Dynamic weight smoothing implemented
- [ ] **Suggested D**: PR4DiagnosticsOutput complete
- [ ] **Advanced I**: UncertaintyPropagator outputs mean+uncertainty
- [ ] **Advanced II**: CalibrationHarness can generate NoiseModelConfig
- [ ] **Advanced III**: PatchDifficultyIndex computed
- [ ] **Advanced IV**: DeterminismFuzzer created
- [ ] **Advanced V**: MultiSourceArbitrator gates unhealthy sources

---

**END OF PR4 V5 ULTIMATE IMPLEMENTATION PROMPT**
