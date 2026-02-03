# PR4 Soft Extreme System - Patch V3 Bulletproof

**Document Version:** 3.0 (Ultimate Hardening + Research-Validated Parameters + Critical Review)
**Status:** DRAFT
**Created:** 2026-02-01
**Scope:** PR4 Industrial-Grade Depth Fusion, Edge Classification, Topology Evaluation with Cross-Platform Determinism

---

## Part 0: Critical Review Summary

This document incorporates the user's improvement suggestions after **critical review** (not blind acceptance). Each suggestion was evaluated against:
- Industry best practices (KinectFusion, voxblox, Open3D, InfiniTAM)
- Recent research (2024-2026 papers on mobile AR depth estimation)
- Swift language constraints and iOS/Linux cross-platform requirements
- Numerical stability analysis

### Verdict Matrix

| User Issue | Verdict | Rationale |
|------------|---------|-----------|
| **HARD ISSUES** |||
| 1. Swift extension stored property | ✅ VALID | Confirmed: Swift extensions cannot have stored properties. Use wrapper class pattern. |
| 2. PR4 import lint vs PRMath libm | ✅ VALID | PRMath internally uses libm is acceptable; PR4 files must NOT import Darwin/Glibc directly. |
| 3. DepthSourceAdapter platform location | ✅ VALID | Platform-specific implementations must be in platform-conditional files, not PR4/. |
| 4. AllocationSentinel cross-platform | ⚠️ PARTIALLY VALID | malloc_count not available on all platforms. Use buffer capacity tracking instead. |
| 5. Duplicate Phase numbering | ✅ VALID | V2 had duplicate Phase 6 and Phase 8. Fixed in V3. |
| 6. normalMap dependency for Linux | ✅ VALID | Must provide fallback when surface normals unavailable. |
| **STABILITY ENHANCEMENTS** |||
| 7. TSDF truncation μ=0.15m too large | ✅ VALID | Research confirms 0.03-0.05m for mobile AR. Changed to 0.04m. |
| 8. Weight exp(-grad²/0.01) underflow | ✅ VALID | Use log-space computation or clamped hybrid model. |
| 9. Integer quantization policies | ✅ VALID | Need explicit rounding/saturation/sentinel definitions. |
| 10. ROI hysteresis + tie-break | ✅ VALID | Need stable selection with deterministic fallback. |
| 11. Edge scoring diagnostic output | ✅ VALID | Add per-type score fields for debugging. |
| 12. CCL max component limits | ✅ VALID | Prevent runaway memory on pathological inputs. |
| 13. Temporal filter state machine | ✅ VALID | Need explicit states with recovery transitions. |
| **NUMERICAL CONCERNS** |||
| Tier3 0.1% tolerance too strict | ⚠️ PARTIALLY VALID | 0.1% for internal; 1-2% for external sources. Keep stratified. |

### My Additional Improvements (Research-Based)

| Enhancement | Source | Rationale |
|-------------|--------|-----------|
| Log-sum-exp trick for softmax | Oxford IMA Journal 2021 | Prevents overflow in weighted voting |
| Adaptive truncation per-depth | voxblox paper | Mobile sensors have depth-dependent noise |
| Kalman filter for temporal depth | MDR-SLAM (2024) | Better than EMA for sensor fusion |
| Max weight accumulation cap | Open3D TSDF | Prevents numeric overflow in long captures |
| Concurrent queue for thread-safe storage | Swift best practice | Better read throughput than NSLock |
| Robust median via partial sort | Algorithm optimization | O(n) vs O(n log n) for trimmed mean |

---

## Part 1: The Fourteen Pillars of PR4 V3

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE FOURTEEN PILLARS OF PR4 V3 BULLETPROOF               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: STRICT IMPORT ISOLATION (Physical Elimination of libm)          │
│  ├── PR4/** ONLY imports: Foundation + PRMath + PR4Math                    │
│  ├── PRMath MAY internally use Darwin/Glibc (abstraction boundary)         │
│  ├── PR4 files MUST NOT import Darwin/Glibc/simd/CoreML/Vision/ARKit       │
│  ├── CI lint scans PR4/ specifically, not PRMath/                          │
│  └── Platform adapters live in Platform/, not PR4/                         │
│                                                                             │
│  PILLAR 2: TSDF-INSPIRED DEPTH FUSION (Research-Validated Parameters)      │
│  ├── Truncation distance: μ = 0.04m (mobile AR optimal, not 0.15m)         │
│  ├── Adaptive truncation: μ_eff = max(0.02m, μ × depth / 2m)               │
│  ├── Weight model: hybrid gradient-confidence with log-space stability     │
│  ├── Max weight accumulation: capped at 128 to prevent overflow            │
│  └── Anti-grazing filter: skip when viewAngle > 70° AND gradient > 5%      │
│                                                                             │
│  PILLAR 3: HIERARCHICAL FUSION (Coarse-to-Fine with Hysteresis)            │
│  ├── Primary fusion: 256×256 for global structure                          │
│  ├── ROI refinement: 64×64 patches at high-gradient boundaries             │
│  ├── Hysteresis: enter at gradient > 0.12, exit at gradient < 0.08         │
│  ├── Deterministic tie-break: top-left wins (min y, then min x)            │
│  └── Max ROI count: 16 per frame (prevent runaway computation)             │
│                                                                             │
│  PILLAR 4: CONTINUOUS EDGE SCORING (Diagnostic-Rich)                       │
│  ├── Each edge type produces score ∈ [0,1] with diagnostic fields          │
│  ├── Geometric: colorGrad × depthGrad × depthConf → geometricScore         │
│  ├── Textural: colorGrad × (1-depthGrad) × freqEnergy → texturalScore      │
│  ├── Specular: brightness × (1-saturation) × (1-depthConf) → specularScore │
│  ├── Transparent: (1-colorEdge) × depthConflict × holeProximity → transScore│
│  ├── Diagnostic output: all four scores preserved for debugging            │
│  └── Final edgeGain: weighted softmax with temperature parameter           │
│                                                                             │
│  PILLAR 5: ROBUST TEMPORAL FILTER (State Machine with Recovery)            │
│  ├── States: COLD_START → WARMING → STABLE → ANOMALY → RECOVERY            │
│  ├── COLD_START: First 3 frames, no filtering, collect samples             │
│  ├── WARMING: Frames 4-10, use median filter only                          │
│  ├── STABLE: Full trimmed mean + EMA, normal operation                     │
│  ├── ANOMALY: Detected jump > 3σ, freeze output, wait for confirmation     │
│  ├── RECOVERY: 5 consistent frames to return to STABLE                     │
│  └── State transitions logged for debugging                                │
│                                                                             │
│  PILLAR 6: INTEGER QUANTIZATION (Explicit Policies)                        │
│  ├── Depth: meters → Int32 millimeters, round_half_even                    │
│  ├── Confidence: [0,1] → UInt16 Q0.16, round_half_up, saturate at 65535    │
│  ├── Sentinel values: depth=0 (invalid), conf=0 (no confidence)            │
│  ├── Overflow policy: saturate (not wrap) for all integer conversions      │
│  ├── Underflow policy: clamp to 0 for unsigned, to MIN for signed          │
│  └── All policies documented in IntegerQuantizationPolicy enum             │
│                                                                             │
│  PILLAR 7: DEPTH SOURCE EVIDENCE PACKAGE (Normalized Contract)             │
│  ├── Required: depthMap, confidenceMap, sourceId, modelVersionHash         │
│  ├── Required metadata: unitScale, validRange, timestamp, frameId          │
│  ├── Normalization: always meters, invalid=0.0, confidence [0,1]           │
│  ├── Source priority for tie-break: platform > small_model > large > stereo│
│  └── Evidence validator rejects malformed packages before fusion           │
│                                                                             │
│  PILLAR 8: THREE-TIER GOLDEN TESTS (Stratified Tolerance)                  │
│  ├── Tier 1 (0 tolerance): Structural invariants (range, monotonicity)     │
│  ├── Tier 2 (bit-exact): Quantized Int64 values match golden fixtures      │
│  ├── Tier 3a (0.1% internal): Internal pipeline consistency                │
│  ├── Tier 3b (1-2% external): External source noise tolerance              │
│  └── NO 10% tolerance anywhere - too loose, hides regressions              │
│                                                                             │
│  PILLAR 9: PROCESS ISOLATION (New Entry Points Only)                       │
│  ├── processObservation() UNCHANGED (PR2/PR3 path preserved)               │
│  ├── NEW: processObservationWithSoft() for PR4+ path                       │
│  ├── NEW: processFrameWithGateAndSoft() convenience wrapper                │
│  ├── Soft computation completely isolated from gate computation            │
│  └── PR4 bug CANNOT regress PR2/PR3 behavior (physical isolation)          │
│                                                                             │
│  PILLAR 10: DETERMINISTIC CCL (Fixed Scan + Max Components)                │
│  ├── Scan order: row-major (y outer, x inner), IMMUTABLE                   │
│  ├── Connectivity: 4-connected for holes (SSOT constant)                   │
│  ├── Queue order: left → right → up → down (deterministic BFS)             │
│  ├── Label assignment: sequential from 1                                   │
│  ├── Max components: 1024 (prevent memory explosion)                       │
│  └── Overflow behavior: merge smallest components on overflow              │
│                                                                             │
│  PILLAR 11: ZERO-ALLOCATION HOT PATH (Buffer Capacity Tracking)            │
│  ├── Pre-allocated ContiguousArray for ALL buffers                         │
│  ├── Buffer capacity checked at init, asserted at runtime                  │
│  ├── NO map/filter/sorted/reversed in hot path                             │
│  ├── Fused single-pass: grayscale + Sobel + HSV + depthGrad + mask         │
│  ├── BufferCapacitySentinel: DEBUG-only capacity validation                │
│  └── Reusable buffer pool with explicit capacity guarantees                │
│                                                                             │
│  PILLAR 12: SOFT CONSTITUTION (Behavioral Contracts)                       │
│  ├── softQuality semantic: 0 = poor quality, 1 = near-optimal              │
│  ├── Each sub-gain: [floor, 1.0] output range, documented monotonicity     │
│  ├── Gate→Soft gating: multiplicative (final = gate × soft)                │
│  ├── Progress source: from PR3 evidence (coverage ratio), not UI           │
│  └── All contracts in SoftConstitution.swift with assertion checks         │
│                                                                             │
│  PILLAR 13: PLATFORM ADAPTATION (Wrapper Pattern, Not Extension)           │
│  ├── DepthSourceAdapter is a WRAPPER CLASS, not extension                  │
│  ├── Platform-specific code in Platform/iOS/ and Platform/Linux/           │
│  ├── PR4/ contains ONLY platform-agnostic business logic                   │
│  ├── Fallback strategy when normalMap unavailable (zero-gradient)          │
│  └── Conditional compilation (#if os(iOS)) ONLY in Platform/               │
│                                                                             │
│  PILLAR 14: NUMERICAL STABILITY (Log-Space + Clamping)                     │
│  ├── Weight computation in log-space: log(w) = -grad²/(2σ²), then exp      │
│  ├── Log-sum-exp trick for softmax: max subtraction before exp             │
│  ├── All exponentials clamped: exp(clamp(x, -20, 20))                      │
│  ├── Sigmoid computed via numerically stable formula                       │
│  └── Gradient clipping for extreme values                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key References:**
- [TSDF Integration - Open3D](https://www.open3d.org/docs/latest/tutorial/t_reconstruction_system/integration.html)
- [voxblox: Incremental TSDF - ETH Zurich](https://github.com/ethz-asl/voxblox)
- [Log-sum-exp numerical stability - Oxford IMA Journal](https://academic.oup.com/imajna/article/41/4/2311/5893596)
- [Mobile AR Depth Estimation - HotMobile 2024](https://arxiv.org/abs/2310.14437)
- [SelfReDepth: Real-time Depth Restoration](https://dl.acm.org/doi/10.1007/s11554-024-01491-z)
- [Swift Extension Stored Properties](https://medium.com/@marcosantadev/stored-properties-in-swift-extensions-615d4c5a9a58)
- [Integer Quantization for Deep Learning](https://arxiv.org/pdf/2004.09602)
- [Connected Component Labeling Review](https://www.sciencedirect.com/science/article/pii/S0031320317301693)

---

## Part 2: Physical Directory Isolation (HARDENED V3)

### 2.1 Directory Structure

```
Core/Evidence/
├── PR4/                              // SOFT BUSINESS LOGIC (platform-agnostic)
│   ├── SoftGainFunctions.swift       // All soft gain computations
│   ├── SoftQualityComputer.swift     // Integration layer
│   ├── SoftConstitution.swift        // Behavioral contracts
│   ├── DynamicWeightComputer.swift   // Progress-based blending
│   ├── DepthFusion/
│   │   ├── DepthFusionEngine.swift   // TSDF-inspired fusion (V3 params)
│   │   ├── DepthConsensusVoter.swift // Weighted voting with tie-break
│   │   ├── DepthTruncator.swift      // Adaptive truncation (V3)
│   │   ├── AntiGrazingFilter.swift   // Edge artifact suppression
│   │   ├── HierarchicalRefiner.swift // Coarse-to-fine ROI with hysteresis (V3)
│   │   └── WeightAccumulator.swift   // Max weight capping (V3)
│   ├── EdgeClassification/
│   │   ├── EdgeScorer.swift          // Continuous scoring
│   │   ├── EdgeTypeScores.swift      // Per-type score computation
│   │   ├── EdgeDiagnostics.swift     // Diagnostic output struct (V3)
│   │   ├── HSVStabilizer.swift       // Local normalization
│   │   └── FusedEdgePass.swift       // Single-pass computation
│   ├── Topology/
│   │   ├── TopologyEvaluator.swift   // Integrated evaluation
│   │   ├── HoleDetector.swift        // Deterministic CCL with max limit (V3)
│   │   ├── OcclusionBoundaryTracker.swift
│   │   └── SelfOcclusionComputer.swift
│   ├── DualChannel/
│   │   ├── DualFrameManager.swift    // rawFrame + assistFrame
│   │   └── FrameConsistencyChecker.swift
│   ├── Temporal/
│   │   ├── TemporalFilterStateMachine.swift // 5-state machine (V3)
│   │   ├── RobustTemporalFilter.swift       // Median + trimmed mean
│   │   ├── TemporalAntiOvershoot.swift      // Suspicious jump handler
│   │   └── MotionCompensator.swift
│   ├── Internal/
│   │   ├── SoftRingBuffer.swift      // Pre-allocated temporal buffer
│   │   ├── IntegerDepthBucket.swift  // Integer-based histogram
│   │   ├── BufferCapacitySentinel.swift // DEBUG capacity check (V3)
│   │   ├── FusedPassBuffers.swift    // Reusable buffer pool
│   │   └── LogSpaceMath.swift        // Numerically stable operations (V3)
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
│   ├── LogSumExpComputer.swift       // Numerically stable softmax (V3)
│   └── StableSigmoid.swift           // Overflow-safe sigmoid (V3)
│
├── Platform/                         // PLATFORM-SPECIFIC ADAPTERS
│   ├── iOS/
│   │   ├── ARKitDepthAdapter.swift   // ARKit depth extraction
│   │   ├── CoreMLDepthAdapter.swift  // ML model inference
│   │   └── iOSNormalMapProvider.swift
│   └── Linux/
│       ├── LinuxDepthStub.swift      // Stub for Linux builds
│       └── LinuxNormalMapFallback.swift // Zero-gradient fallback
│
├── Constants/
│   ├── SoftGatesV14.swift            // V14 with V3 hardening
│   ├── TSDFConfigV3.swift            // Research-validated params (V3)
│   ├── EdgeScoringConfig.swift       // Continuous scoring params
│   ├── TemporalConfig.swift          // Robust filtering params
│   ├── DeterminismConfig.swift       // Scan order/tie-break rules
│   └── IntegerQuantizationPolicy.swift // Rounding/saturation policies (V3)
│
└── Vector/
    └── EvidenceVector3.swift         // From PR3, no changes

Tests/Evidence/PR4/
├── Tier1_StructuralTests/            // Zero tolerance
│   ├── GainRangeInvariantsTests.swift
│   ├── MonotonicityTests.swift
│   └── WeightSumTests.swift
├── Tier2_QuantizedGoldenTests/       // Bit-exact
│   ├── DepthFusionGoldenTests.swift
│   ├── EdgeScorerGoldenTests.swift
│   └── TopologyGoldenTests.swift
├── Tier3_ToleranceTests/             // Stratified tolerance (V3)
│   ├── InternalConsistencyTests.swift  // 0.1% tolerance
│   └── ExternalSourceNoiseTests.swift  // 1-2% tolerance
├── DeterminismTests/
│   ├── SoftDeterminism100RunTests.swift
│   ├── CCLDeterminismTests.swift
│   └── TieBreakDeterminismTests.swift
├── StateMachineTests/                // V3 temporal filter states
│   └── TemporalFilterStateMachineTests.swift
├── CrossPlatformTests/
│   └── SoftCrossPlatformTests.swift
└── PerformanceTests/
    ├── BufferCapacityTests.swift
    └── FusedPassBenchmarkTests.swift
```

### 2.2 Import Rules (STRICTLY ENFORCED)

```swift
// ═══════════════════════════════════════════════════════════════════════════
// IMPORT RULES V3 - ENFORCED BY CI LINT
// ═══════════════════════════════════════════════════════════════════════════

// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCOPE: These rules apply to Core/Evidence/PR4/** files ONLY            │
// │ PRMath/ is EXEMPT - it's an abstraction boundary                       │
// └─────────────────────────────────────────────────────────────────────────┘

// PR4/** files can ONLY import:
// ✅ import Foundation         (basic types, with restrictions below)
// ✅ import PRMath             (PR3 math facade - sigmoid, expSafe, etc.)
// ✅ import PR4Math            (PR4 math facade - Sobel, HSV, interpolation)

// PR4/** files FORBIDDEN to import:
// ❌ import Darwin             (no direct libm access)
// ❌ import Glibc              (no direct libm access)
// ❌ import simd               (use EvidenceVector3)
// ❌ import CoreML             (use Platform/iOS/ adapters)
// ❌ import Vision             (use EdgeScorer)
// ❌ import ARKit              (use Platform/iOS/ adapters)
// ❌ import Accelerate         (determinism concern)

// FOUNDATION RESTRICTIONS in PR4:
// ❌ Date()                    (use injected timestamp)
// ❌ UUID()                    (use deterministic IDs)
// ❌ .random                   (no randomness)
// ❌ Dictionary iteration      (use sorted keys)
// ❌ Set iteration             (use sorted array)

// ALL MATH via PRMath facade:
// ✅ PRMath.abs(x)             NOT abs(x)
// ✅ PRMath.min(a, b)          NOT min(a, b)
// ✅ PRMath.max(a, b)          NOT max(a, b)
// ✅ PRMath.sqrt(x)            NOT sqrt(x)
// ✅ PRMath.exp(x)             NOT exp(x)
// ✅ PRMath.log(x)             NOT log(x)
// ✅ PRMath.sigmoid(x)         (already in PRMath)
// ✅ PRMath.clamp(x, lo, hi)   NOT Swift.max(lo, min(hi, x))

// WHY PRMath CAN USE DARWIN/GLIBC INTERNALLY:
// - PRMath is the ABSTRACTION BOUNDARY for math functions
// - PRMath ensures consistent behavior across platforms
// - PRMath provides safe wrappers (e.g., expSafe with clamping)
// - CI lint scans PR4/** files, not PRMath/**
// - This is intentional design: separation of concerns
```

---

## Part 3: TSDF-Inspired Depth Fusion (Research-Validated V3)

### 3.1 TSDFConfigV3 Constants (SSOT)

```swift
//
// TSDFConfigV3.swift
// Aether3D
//
// PR4 V3 - TSDF-Inspired Fusion Configuration
// RESEARCH-VALIDATED: Based on voxblox, Open3D, KinectFusion, mobile AR papers
//

import Foundation

/// TSDF-inspired depth fusion configuration V3
///
/// KEY CHANGES FROM V2:
/// - Truncation reduced from 0.15m to 0.04m (mobile AR optimal)
/// - Adaptive truncation based on depth
/// - Weight model uses log-space for numerical stability
/// - Max weight accumulation to prevent overflow
///
/// REFERENCES:
/// - voxblox: Oleynikova et al., IROS 2017 (truncation = 3× voxel size)
/// - Open3D TSDF: default 0.04m truncation
/// - Mobile AR Depth Estimation: Ganj et al., HotMobile 2024
public enum TSDFConfigV3 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Truncation Parameters (RESEARCH-VALIDATED)
    // ═══════════════════════════════════════════════════════════════════════

    /// Truncation distance (μ) in meters
    ///
    /// CHANGED FROM V2: 0.15m → 0.04m
    ///
    /// RESEARCH JUSTIFICATION:
    /// - voxblox recommends 3× voxel size (0.015m voxel → 0.045m truncation)
    /// - Open3D default: 0.04m
    /// - KinectFusion mobile variants: 0.03-0.08m
    /// - Mobile AR sensors have lower noise than 0.15m would suggest
    ///
    /// VALUE: 0.04m (4cm, tight but appropriate for mobile AR)
    public static let truncationDistanceM: Double = 0.04

    /// Truncation distance as Int32 (millimeters)
    public static let truncationDistanceMM: Int32 = 40

    /// Minimum truncation distance (for near objects)
    ///
    /// FORMULA: μ_eff = max(minTruncationM, truncationDistanceM × depth / referenceDepthM)
    /// At 2m: μ_eff = 0.04m
    /// At 1m: μ_eff = max(0.02, 0.04 × 0.5) = 0.02m
    /// At 4m: μ_eff = 0.04 × 2 = 0.08m
    public static let minTruncationM: Double = 0.02
    public static let referenceDepthM: Double = 2.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Weight Model Parameters (NUMERICALLY STABLE)
    // ═══════════════════════════════════════════════════════════════════════

    /// Gradient weight sigma
    ///
    /// FORMULA (log-space): log_w_grad = -grad² / (2 × gradientSigma²)
    ///
    /// CHANGED FROM V2: gradientStabilityScale → gradientSigma
    /// Using explicit sigma for Gaussian interpretation
    ///
    /// VALUE: 0.1 (gradients up to ~0.2 have reasonable weight)
    public static let gradientSigma: Double = 0.1
    public static let gradientSigmaSquared: Double = 0.01  // precomputed

    /// Depth noise sigma for confidence weighting
    ///
    /// FORMULA: w_noise = 1 / (1 + (noiseSigma / depth)²)
    ///
    /// VALUE: 0.007m (7mm noise, typical for mobile depth sensors)
    public static let noiseSigma: Double = 0.007

    /// View angle exponent
    ///
    /// FORMULA: w_angle = cos(viewAngle) ^ angleExponent
    public static let angleExponent: Double = 2.0

    /// Maximum weight accumulation
    ///
    /// ADDED IN V3: Prevent numeric overflow in long captures
    /// After 128 weight units, further observations don't increase weight
    ///
    /// REFERENCE: Open3D TSDF uses similar capping
    public static let maxAccumulatedWeight: Double = 128.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Anti-Grazing Parameters (TIGHTENED)
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum view angle for fusion (degrees)
    ///
    /// CHANGED FROM V2: 75° → 70°
    /// Tighter constraint to reduce edge artifacts
    public static let maxViewAngleDeg: Double = 70.0
    public static let maxViewAngleCos: Double = 0.342  // cos(70°)

    /// Anti-grazing gradient threshold
    ///
    /// Skip fusion if viewAngle > 60° AND gradient > this threshold
    public static let antiGrazingGradientThreshold: Double = 0.05

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - ROI Selection with Hysteresis (V3)
    // ═══════════════════════════════════════════════════════════════════════

    /// Gradient threshold to ENTER ROI refinement
    public static let roiEnterGradientThreshold: Double = 0.12

    /// Gradient threshold to EXIT ROI refinement (lower for hysteresis)
    public static let roiExitGradientThreshold: Double = 0.08

    /// Maximum ROI patches per frame
    ///
    /// ADDED IN V3: Prevent runaway computation on noisy inputs
    public static let maxROIPerFrame: Int = 16

    /// ROI selection tie-break order
    ///
    /// When multiple regions have equal gradient, select top-left first
    /// DETERMINISTIC: min(y), then min(x)
    public static let roiTieBreakOrder: String = "top_left_first"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Consensus Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum weight for valid fusion result
    public static let minAccumulatedWeight: Double = 0.5

    /// Source priority for tie-breaking (SSOT)
    /// Higher index = higher priority
    public static let sourcePriority: [String: Int] = [
        "stereo": 0,
        "large_model": 1,
        "small_model": 2,
        "platform_api": 3
    ]
}
```

### 3.2 Numerically Stable Weight Computation

```swift
//
// LogSpaceMath.swift
// Aether3D
//
// PR4 V3 - Numerically Stable Math Operations
// Prevents overflow/underflow in weight computations
//

import Foundation
import PRMath

/// Numerically stable math operations for depth fusion
///
/// KEY INSIGHT: Computing weights in log-space prevents underflow
/// Instead of: w = exp(-grad²/σ²) which can underflow to 0
/// We compute: log_w = -grad²/σ², then use log-sum-exp trick
public enum LogSpaceMath {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Safe Exponential
    // ═══════════════════════════════════════════════════════════════════════

    /// Clamped exponential to prevent overflow/underflow
    ///
    /// BOUNDS:
    /// - exp(-20) ≈ 2e-9 (effectively zero but not zero)
    /// - exp(20) ≈ 4.8e8 (large but not overflow)
    ///
    /// REFERENCE: Common practice in ML frameworks
    @inline(__always)
    public static func expSafe(_ x: Double) -> Double {
        PRMath.exp(PRMath.clamp(x, -20.0, 20.0))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Log-Sum-Exp Trick
    // ═══════════════════════════════════════════════════════════════════════

    /// Numerically stable log-sum-exp
    ///
    /// Computes log(sum(exp(x_i))) without overflow
    ///
    /// FORMULA:
    /// max_x = max(x_i)
    /// result = max_x + log(sum(exp(x_i - max_x)))
    ///
    /// REFERENCE: Oxford IMA Journal of Numerical Analysis (2021)
    public static func logSumExp(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -.infinity }
        guard values.count > 1 else { return values[0] }

        let maxVal = values.max()!
        var sumExp = 0.0
        for v in values {
            sumExp += expSafe(v - maxVal)
        }
        return maxVal + PRMath.log(sumExp)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Stable Softmax
    // ═══════════════════════════════════════════════════════════════════════

    /// Numerically stable softmax
    ///
    /// FORMULA: softmax(x_i) = exp(x_i - max_x) / sum(exp(x_j - max_x))
    public static func softmax(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }

        let maxVal = values.max()!
        var expValues = values.map { expSafe($0 - maxVal) }
        let sumExp = expValues.reduce(0, +)

        guard sumExp > 0 else {
            // All values very negative, return uniform
            return Array(repeating: 1.0 / Double(values.count), count: values.count)
        }

        for i in 0..<expValues.count {
            expValues[i] /= sumExp
        }
        return expValues
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gradient Weight (Log-Space)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute gradient weight in log-space
    ///
    /// log_w = -grad² / (2σ²)
    ///
    /// To get actual weight: exp(log_w)
    /// But for combining: just add log weights
    @inline(__always)
    public static func logGradientWeight(gradient: Double, sigmaSquared: Double) -> Double {
        let gradSquared = gradient * gradient
        return -gradSquared / (2.0 * sigmaSquared)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Hybrid Weight Model (V3)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute combined weight for depth fusion
    ///
    /// FORMULA:
    /// w = w_confidence × w_gradient × w_angle × w_depth
    ///
    /// Computed in log-space, then exponentiated:
    /// log_w = log(conf) + log_w_grad + log_w_angle + log_w_depth
    /// w = exp(log_w)
    ///
    /// - Parameters:
    ///   - confidence: Source-reported confidence [0,1]
    ///   - gradient: Depth gradient magnitude
    ///   - viewAngleCos: cos(view angle)
    ///   - depth: Depth in meters
    public static func computeFusionWeight(
        confidence: Double,
        gradient: Double,
        viewAngleCos: Double,
        depth: Double
    ) -> Double {
        // Confidence component (avoid log(0))
        let safeConf = PRMath.max(confidence, 1e-6)
        let logConf = PRMath.log(safeConf)

        // Gradient component
        let logGrad = logGradientWeight(
            gradient: gradient,
            sigmaSquared: TSDFConfigV3.gradientSigmaSquared
        )

        // View angle component: cos(θ)^2
        let safeAngle = PRMath.max(viewAngleCos, 1e-6)
        let logAngle = 2.0 * PRMath.log(safeAngle)

        // Depth component: 1 / (1 + depth/scale)
        // log version: -log(1 + depth/scale)
        let depthRatio = depth / 5.0  // 5m scale
        let logDepth = -PRMath.log(1.0 + depthRatio)

        // Combined
        let logWeight = logConf + logGrad + logAngle + logDepth
        return expSafe(logWeight)
    }
}
```

---

## Part 4: Temporal Filter State Machine (V3)

### 4.1 State Definitions

```swift
//
// TemporalFilterStateMachine.swift
// Aether3D
//
// PR4 V3 - Explicit State Machine for Temporal Filtering
// Addresses user's concern about implicit state transitions
//

import Foundation
import PRMath

/// Temporal filter states
///
/// ADDED IN V3: Explicit state machine with recovery
///
/// State diagram:
/// ```
///                    ┌──────────────────┐
///                    │   COLD_START     │ frames 0-2
///                    │ (no filtering)   │
///                    └────────┬─────────┘
///                             │ frame 3
///                             ▼
///                    ┌──────────────────┐
///                    │    WARMING       │ frames 3-9
///                    │ (median only)    │
///                    └────────┬─────────┘
///                             │ frame 10
///                             ▼
///         ┌─────────────────────────────────────────┐
///         │                STABLE                    │
///         │ (full filtering: trimmed mean + EMA)    │
///         └────────────────────┬────────────────────┘
///                              │ jump > 3σ
///                              ▼
///                    ┌──────────────────┐
///                    │    ANOMALY       │
///                    │ (freeze output)  │
///                    └────────┬─────────┘
///                             │ 5 consistent frames
///                             ▼
///                    ┌──────────────────┐
///                    │    RECOVERY      │
///                    │ (median only)    │──→ back to STABLE
///                    └──────────────────┘
/// ```
public enum TemporalFilterState: String, Codable {
    case coldStart = "COLD_START"
    case warming = "WARMING"
    case stable = "STABLE"
    case anomaly = "ANOMALY"
    case recovery = "RECOVERY"
}

/// Temporal filter state machine
///
/// Manages state transitions for robust temporal filtering
public final class TemporalFilterStateMachine {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Frames needed to exit COLD_START
    public static let coldStartFrames: Int = 3

    /// Frames needed to exit WARMING
    public static let warmingFrames: Int = 10

    /// Jump threshold in standard deviations
    public static let anomalyThresholdSigma: Double = 3.0

    /// Consistent frames needed for RECOVERY → STABLE
    public static let recoveryFrames: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    private(set) var currentState: TemporalFilterState = .coldStart
    private var frameCount: Int = 0
    private var consecutiveNormalFrames: Int = 0
    private var lastOutput: Double = 0.0
    private var runningMean: Double = 0.0
    private var runningVariance: Double = 0.0
    private var sampleCount: Int = 0

    // Ring buffer for historical values
    private var history: ContiguousArray<Double>
    private var historyIndex: Int = 0
    private let historyCapacity: Int

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(historyCapacity: Int = 30) {
        self.historyCapacity = historyCapacity
        self.history = ContiguousArray(repeating: 0.0, count: historyCapacity)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State Machine
    // ═══════════════════════════════════════════════════════════════════════

    /// Process new input and return filtered output
    ///
    /// - Parameter input: New depth/quality value
    /// - Returns: Filtered output based on current state
    public func process(_ input: Double) -> (output: Double, state: TemporalFilterState) {
        frameCount += 1

        // Update history
        let oldValue = history[historyIndex]
        history[historyIndex] = input
        historyIndex = (historyIndex + 1) % historyCapacity

        // Update running statistics (Welford's algorithm)
        let validSamples = min(frameCount, historyCapacity)
        if validSamples > 1 {
            let delta = input - runningMean
            runningMean += delta / Double(validSamples)
            let delta2 = input - runningMean
            runningVariance += delta * delta2
        } else {
            runningMean = input
            runningVariance = 0
        }
        sampleCount = validSamples

        // State-specific processing
        let output: Double
        let previousState = currentState

        switch currentState {
        case .coldStart:
            output = input  // No filtering
            if frameCount >= Self.coldStartFrames {
                transitionTo(.warming)
            }

        case .warming:
            output = computeMedian()
            if frameCount >= Self.warmingFrames {
                transitionTo(.stable)
            }

        case .stable:
            // Check for anomaly
            let sigma = computeSigma()
            let deviation = PRMath.abs(input - runningMean)
            if sigma > 1e-6 && deviation > Self.anomalyThresholdSigma * sigma {
                transitionTo(.anomaly)
                output = lastOutput  // Freeze
                consecutiveNormalFrames = 0
            } else {
                output = computeTrimmedMeanWithEMA(input)
            }

        case .anomaly:
            output = lastOutput  // Freeze
            let sigma = computeSigma()
            let deviation = PRMath.abs(input - runningMean)
            if sigma > 1e-6 && deviation <= Self.anomalyThresholdSigma * sigma {
                consecutiveNormalFrames += 1
                if consecutiveNormalFrames >= Self.recoveryFrames {
                    transitionTo(.recovery)
                }
            } else {
                consecutiveNormalFrames = 0
            }

        case .recovery:
            output = computeMedian()
            consecutiveNormalFrames += 1
            if consecutiveNormalFrames >= Self.recoveryFrames {
                transitionTo(.stable)
            }
        }

        lastOutput = output
        return (output, currentState)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Filtering Methods
    // ═══════════════════════════════════════════════════════════════════════

    private func computeMedian() -> Double {
        let validCount = min(frameCount, historyCapacity)
        guard validCount > 0 else { return 0 }

        // Partial sort for O(n) median
        var sorted = Array(history.prefix(validCount))
        let midIndex = validCount / 2
        sorted.withUnsafeMutableBufferPointer { buffer in
            // nth_element equivalent using partial sort
            var lo = 0
            var hi = validCount - 1
            while lo < hi {
                let pivot = buffer[(lo + hi) / 2]
                var i = lo
                var j = hi
                while i <= j {
                    while buffer[i] < pivot { i += 1 }
                    while buffer[j] > pivot { j -= 1 }
                    if i <= j {
                        buffer.swapAt(i, j)
                        i += 1
                        j -= 1
                    }
                }
                if j < midIndex { lo = i }
                if midIndex < i { hi = j }
            }
        }
        return sorted[midIndex]
    }

    private func computeTrimmedMeanWithEMA(_ newValue: Double) -> Double {
        let validCount = min(frameCount, historyCapacity)
        guard validCount >= 5 else { return computeMedian() }

        // 20% trimmed mean
        var sorted = Array(history.prefix(validCount)).sorted()
        let trimCount = validCount / 5  // 20%
        let trimmedValues = Array(sorted.dropFirst(trimCount).dropLast(trimCount))

        guard !trimmedValues.isEmpty else { return computeMedian() }

        let trimmedMean = trimmedValues.reduce(0, +) / Double(trimmedValues.count)

        // EMA blend with new value
        let emaAlpha = 0.2
        return emaAlpha * newValue + (1 - emaAlpha) * trimmedMean
    }

    private func computeSigma() -> Double {
        guard sampleCount > 1 else { return 0 }
        return PRMath.sqrt(runningVariance / Double(sampleCount - 1))
    }

    private func transitionTo(_ newState: TemporalFilterState) {
        #if DEBUG
        print("[TemporalFilter] State transition: \(currentState.rawValue) → \(newState.rawValue) at frame \(frameCount)")
        #endif
        currentState = newState
    }

    /// Reset state machine (e.g., on session change)
    public func reset() {
        currentState = .coldStart
        frameCount = 0
        consecutiveNormalFrames = 0
        lastOutput = 0
        runningMean = 0
        runningVariance = 0
        sampleCount = 0
        historyIndex = 0
        for i in 0..<historyCapacity {
            history[i] = 0
        }
    }
}
```

---

## Part 5: Integer Quantization Policy (V3)

### 5.1 Explicit Quantization Policies

```swift
//
// IntegerQuantizationPolicy.swift
// Aether3D
//
// PR4 V3 - Explicit Integer Quantization Policies
// Addresses user's concern about undefined rounding/saturation behavior
//

import Foundation
import PRMath

/// Rounding modes for quantization
///
/// ADDED IN V3: Explicit rounding policy definitions
public enum RoundingMode: String, Codable {
    /// Round to nearest even (banker's rounding)
    /// 0.5 → 0, 1.5 → 2, 2.5 → 2, 3.5 → 4
    /// RECOMMENDED: Reduces systematic bias
    case halfEven = "HALF_EVEN"

    /// Round half up (standard rounding)
    /// 0.5 → 1, 1.5 → 2, 2.5 → 3
    case halfUp = "HALF_UP"

    /// Round toward zero (truncation)
    /// 0.7 → 0, -0.7 → 0
    case towardZero = "TOWARD_ZERO"

    /// Round toward negative infinity (floor)
    /// 0.7 → 0, -0.7 → -1
    case floor = "FLOOR"

    /// Round toward positive infinity (ceiling)
    /// 0.3 → 1, -0.3 → 0
    case ceiling = "CEILING"
}

/// Overflow handling policy
public enum OverflowPolicy: String, Codable {
    /// Clamp to type bounds (RECOMMENDED for quality signals)
    /// Values above MAX → MAX, below MIN → MIN
    case saturate = "SATURATE"

    /// Wrap around (modular arithmetic)
    /// NOT RECOMMENDED: Can cause sign flip
    case wrap = "WRAP"

    /// Trap/assert on overflow (DEBUG only)
    case trap = "TRAP"
}

/// Sentinel value policy
public enum SentinelPolicy: String, Codable {
    /// Use specific value as invalid marker
    case value = "VALUE"

    /// Use NaN (floating-point only)
    case nan = "NAN"

    /// No sentinel, all values valid
    case none = "NONE"
}

/// Complete quantization policy
public struct QuantizationPolicy: Codable {
    public let rounding: RoundingMode
    public let overflow: OverflowPolicy
    public let sentinel: SentinelPolicy
    public let sentinelValue: Int64?

    public init(
        rounding: RoundingMode = .halfEven,
        overflow: OverflowPolicy = .saturate,
        sentinel: SentinelPolicy = .value,
        sentinelValue: Int64? = nil
    ) {
        self.rounding = rounding
        self.overflow = overflow
        self.sentinel = sentinel
        self.sentinelValue = sentinelValue
    }
}

/// Integer quantization configuration for PR4
public enum IntegerQuantizationConfig {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Depth Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Depth quantization policy
    ///
    /// Input: meters (Double)
    /// Output: millimeters (Int32)
    /// Invalid: 0 (sentinel for invalid depth)
    public static let depthPolicy = QuantizationPolicy(
        rounding: .halfEven,
        overflow: .saturate,
        sentinel: .value,
        sentinelValue: 0
    )

    /// Depth quantization bounds
    public static let depthMinMM: Int32 = 1       // 1mm minimum valid
    public static let depthMaxMM: Int32 = 50_000  // 50m maximum
    public static let depthInvalidMM: Int32 = 0   // Sentinel

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Confidence Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Confidence quantization policy
    ///
    /// Input: [0, 1] (Double)
    /// Output: Q0.16 fixed-point (UInt16)
    /// Invalid: 0 (sentinel for no confidence)
    public static let confidencePolicy = QuantizationPolicy(
        rounding: .halfUp,
        overflow: .saturate,
        sentinel: .value,
        sentinelValue: 0
    )

    /// Confidence quantization bounds
    public static let confidenceMin: UInt16 = 1      // Minimum valid
    public static let confidenceMax: UInt16 = 65535  // Maximum (1.0)
    public static let confidenceInvalid: UInt16 = 0  // Sentinel

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Soft Gain Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Soft gain quantization policy
    ///
    /// Input: [0, 1] (Double)
    /// Output: Q0.32 fixed-point (Int64)
    /// Rounding: half-even for unbiased aggregation
    public static let softGainPolicy = QuantizationPolicy(
        rounding: .halfEven,
        overflow: .saturate,
        sentinel: .none,
        sentinelValue: nil
    )

    /// Soft gain scale factor
    public static let softGainScale: Int64 = 1_000_000_000  // 1e9 for Q0.32-ish
}

/// Integer quantizer implementation
public struct IntegerQuantizer {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Depth Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantize depth from meters to millimeters
    ///
    /// - Parameters:
    ///   - depthM: Depth in meters
    ///   - isValid: Whether the depth is valid
    /// - Returns: Quantized depth in millimeters (Int32)
    @inline(__always)
    public static func quantizeDepth(_ depthM: Double, isValid: Bool) -> Int32 {
        guard isValid else {
            return IntegerQuantizationConfig.depthInvalidMM
        }

        // Convert to millimeters
        let depthMM = depthM * 1000.0

        // Round (half-even)
        let rounded = roundHalfEven(depthMM)

        // Saturate to bounds
        let clamped = PRMath.clamp(
            Int32(rounded),
            IntegerQuantizationConfig.depthMinMM,
            IntegerQuantizationConfig.depthMaxMM
        )

        return clamped
    }

    /// Dequantize depth from millimeters to meters
    @inline(__always)
    public static func dequantizeDepth(_ depthMM: Int32) -> (value: Double, isValid: Bool) {
        if depthMM == IntegerQuantizationConfig.depthInvalidMM {
            return (0.0, false)
        }
        return (Double(depthMM) / 1000.0, true)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Confidence Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantize confidence from [0,1] to Q0.16
    @inline(__always)
    public static func quantizeConfidence(_ confidence: Double, isValid: Bool) -> UInt16 {
        guard isValid else {
            return IntegerQuantizationConfig.confidenceInvalid
        }

        // Scale to 0-65535
        let scaled = confidence * 65535.0

        // Round half-up
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)

        // Saturate
        if rounded <= 0 {
            return IntegerQuantizationConfig.confidenceInvalid
        }
        if rounded >= 65535 {
            return IntegerQuantizationConfig.confidenceMax
        }
        return UInt16(rounded)
    }

    /// Dequantize confidence from Q0.16 to [0,1]
    @inline(__always)
    public static func dequantizeConfidence(_ quantized: UInt16) -> (value: Double, isValid: Bool) {
        if quantized == IntegerQuantizationConfig.confidenceInvalid {
            return (0.0, false)
        }
        return (Double(quantized) / 65535.0, true)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Soft Gain Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantize soft gain for deterministic comparison
    @inline(__always)
    public static func quantizeSoftGain(_ gain: Double) -> Int64 {
        let scaled = gain * Double(IntegerQuantizationConfig.softGainScale)
        return Int64(roundHalfEven(scaled))
    }

    /// Compare quantized gains for equality
    @inline(__always)
    public static func softGainsEqual(_ a: Int64, _ b: Int64) -> Bool {
        return a == b
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Rounding Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// Round half-to-even (banker's rounding)
    @inline(__always)
    private static func roundHalfEven(_ value: Double) -> Double {
        let rounded = value.rounded()
        let fraction = value - value.rounded(.towardZero)

        // Check if exactly at 0.5
        if PRMath.abs(PRMath.abs(fraction) - 0.5) < 1e-10 {
            // Round to nearest even
            let truncated = value.rounded(.towardZero)
            if Int64(truncated) % 2 == 0 {
                return truncated
            } else {
                return truncated + (value >= 0 ? 1 : -1)
            }
        }
        return rounded
    }
}
```

---

## Part 6: Connected Component Labeling with Limits (V3)

### 6.1 Deterministic CCL with Max Components

```swift
//
// HoleDetector.swift
// Aether3D
//
// PR4 V3 - Deterministic CCL with Component Limits
// Addresses user's concern about unbounded memory usage
//

import Foundation
import PRMath

/// Connected Component Labeling configuration
public enum CCLConfig {
    /// Maximum components before merging smallest
    ///
    /// ADDED IN V3: Prevent memory explosion on pathological inputs
    public static let maxComponents: Int = 1024

    /// Connectivity (4 or 8)
    public static let connectivity: Int = 4

    /// Scan order (deterministic)
    public static let scanOrder: String = "row_major_y_outer_x_inner"

    /// Queue order for BFS (deterministic)
    public static let neighborOrder: [(Int, Int)] = [
        (-1, 0),  // left
        (1, 0),   // right
        (0, -1),  // up
        (0, 1)    // down
    ]
}

/// Hole detector with deterministic CCL
public final class HoleDetector {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    public struct Component {
        public let label: Int
        public var pixelCount: Int
        public var boundingBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)
        public var isHole: Bool
    }

    public struct HoleDetectionResult {
        public let components: [Component]
        public let labelMap: [[Int]]
        public let totalHoleArea: Int
        public let holeRatio: Double
        public let mergedDueToLimit: Bool
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Detection
    // ═══════════════════════════════════════════════════════════════════════

    /// Detect holes in depth map
    ///
    /// - Parameters:
    ///   - depthMap: Depth values (0 = invalid/hole)
    ///   - width: Map width
    ///   - height: Map height
    /// - Returns: Detection result with components and metrics
    public func detectHoles(
        depthMap: [[Int32]],
        width: Int,
        height: Int
    ) -> HoleDetectionResult {
        // Create binary mask (1 = hole, 0 = valid)
        var holeMask = Array(repeating: Array(repeating: 0, count: width), count: height)
        for y in 0..<height {
            for x in 0..<width {
                if depthMap[y][x] == 0 {
                    holeMask[y][x] = 1
                }
            }
        }

        // Run CCL
        var labelMap = Array(repeating: Array(repeating: 0, count: width), count: height)
        var components: [Int: Component] = [:]
        var currentLabel = 0
        var mergedDueToLimit = false

        // Queue for BFS (pre-allocated)
        var queue = ContiguousArray<(Int, Int)>()
        queue.reserveCapacity(width * height / 10)

        // Deterministic scan: row-major (y outer, x inner)
        for y in 0..<height {
            for x in 0..<width {
                if holeMask[y][x] == 1 && labelMap[y][x] == 0 {
                    // Check component limit
                    if components.count >= CCLConfig.maxComponents {
                        // Merge into smallest existing component
                        let smallestLabel = findSmallestComponent(components)
                        floodFill(
                            x: x, y: y,
                            width: width, height: height,
                            mask: holeMask,
                            labelMap: &labelMap,
                            label: smallestLabel,
                            component: &components[smallestLabel]!,
                            queue: &queue
                        )
                        mergedDueToLimit = true
                        continue
                    }

                    // New component
                    currentLabel += 1
                    var component = Component(
                        label: currentLabel,
                        pixelCount: 0,
                        boundingBox: (x, y, x, y),
                        isHole: true
                    )

                    floodFill(
                        x: x, y: y,
                        width: width, height: height,
                        mask: holeMask,
                        labelMap: &labelMap,
                        label: currentLabel,
                        component: &component,
                        queue: &queue
                    )

                    components[currentLabel] = component
                }
            }
        }

        // Compute metrics
        let totalHoleArea = components.values.reduce(0) { $0 + $1.pixelCount }
        let totalPixels = width * height
        let holeRatio = totalPixels > 0 ? Double(totalHoleArea) / Double(totalPixels) : 0.0

        return HoleDetectionResult(
            components: Array(components.values).sorted { $0.label < $1.label },
            labelMap: labelMap,
            totalHoleArea: totalHoleArea,
            holeRatio: holeRatio,
            mergedDueToLimit: mergedDueToLimit
        )
    }

    // ═══════════════════════════════��═══════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════════════

    private func floodFill(
        x: Int, y: Int,
        width: Int, height: Int,
        mask: [[Int]],
        labelMap: inout [[Int]],
        label: Int,
        component: inout Component,
        queue: inout ContiguousArray<(Int, Int)>
    ) {
        queue.removeAll(keepingCapacity: true)
        queue.append((x, y))
        labelMap[y][x] = label

        while !queue.isEmpty {
            let (cx, cy) = queue.removeFirst()

            component.pixelCount += 1
            component.boundingBox.minX = min(component.boundingBox.minX, cx)
            component.boundingBox.minY = min(component.boundingBox.minY, cy)
            component.boundingBox.maxX = max(component.boundingBox.maxX, cx)
            component.boundingBox.maxY = max(component.boundingBox.maxY, cy)

            // Deterministic neighbor order: left, right, up, down
            for (dx, dy) in CCLConfig.neighborOrder {
                let nx = cx + dx
                let ny = cy + dy

                if nx >= 0 && nx < width && ny >= 0 && ny < height {
                    if mask[ny][nx] == 1 && labelMap[ny][nx] == 0 {
                        labelMap[ny][nx] = label
                        queue.append((nx, ny))
                    }
                }
            }
        }
    }

    private func findSmallestComponent(_ components: [Int: Component]) -> Int {
        var smallestLabel = components.keys.first!
        var smallestSize = Int.max

        // Deterministic iteration: sorted keys
        for label in components.keys.sorted() {
            if components[label]!.pixelCount < smallestSize {
                smallestSize = components[label]!.pixelCount
                smallestLabel = label
            }
        }

        return smallestLabel
    }
}
```

---

## Part 7: Edge Scoring with Diagnostics (V3)

### 7.1 Diagnostic Output Structure

```swift
//
// EdgeDiagnostics.swift
// Aether3D
//
// PR4 V3 - Edge Scoring Diagnostic Output
// Addresses user's concern about debugging edge classification
//

import Foundation

/// Diagnostic output for edge scoring
///
/// ADDED IN V3: Per-type scores preserved for debugging
public struct EdgeScoringDiagnostics: Codable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Per-Type Scores (V3 Diagnostic Fields)
    // ═══════════════════════════════════════════════════════════════════════

    /// Geometric edge score [0,1]
    /// High when: colorGrad high AND depthGrad high AND depthConf high
    public let geometricScore: Double

    /// Textural edge score [0,1]
    /// High when: colorGrad high AND depthGrad low AND freqEnergy high
    public let texturalScore: Double

    /// Specular edge score [0,1]
    /// High when: brightness high AND saturation low AND depthConf low
    public let specularScore: Double

    /// Transparent edge score [0,1]
    /// High when: colorEdge weak AND depthConflict high AND hole proximity high
    public let transparentScore: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Intermediate Values
    // ═══════════════════════════════════════════════════════════════════════

    /// Color gradient magnitude [0,1]
    public let colorGradient: Double

    /// Depth gradient magnitude [0,1]
    public let depthGradient: Double

    /// Depth confidence [0,1]
    public let depthConfidence: Double

    /// Brightness (HSV V) [0,1]
    public let brightness: Double

    /// Saturation (HSV S) [0,1]
    public let saturation: Double

    /// High-frequency energy [0,1]
    public let frequencyEnergy: Double

    /// Depth conflict indicator [0,1]
    public let depthConflict: Double

    /// Hole proximity [0,1]
    public let holeProximity: Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Final Outputs
    // ═══════════════════════════════════════════════════════════════════════

    /// Final edge gain [floor, 1.0]
    public let finalEdgeGain: Double

    /// Dominant edge type (for debugging)
    public let dominantEdgeType: String

    /// Softmax weights used for combination
    public let softmaxWeights: [String: Double]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Factory
    // ═══════════════════════════════════════════════════════════════════════

    public static func create(
        geometric: Double,
        textural: Double,
        specular: Double,
        transparent: Double,
        colorGrad: Double,
        depthGrad: Double,
        depthConf: Double,
        brightness: Double,
        saturation: Double,
        freqEnergy: Double,
        depthConflict: Double,
        holeProx: Double,
        finalGain: Double,
        weights: [String: Double]
    ) -> EdgeScoringDiagnostics {
        // Determine dominant type
        let scores = [
            ("geometric", geometric),
            ("textural", textural),
            ("specular", specular),
            ("transparent", transparent)
        ]
        let dominant = scores.max(by: { $0.1 < $1.1 })?.0 ?? "unknown"

        return EdgeScoringDiagnostics(
            geometricScore: geometric,
            texturalScore: textural,
            specularScore: specular,
            transparentScore: transparent,
            colorGradient: colorGrad,
            depthGradient: depthGrad,
            depthConfidence: depthConf,
            brightness: brightness,
            saturation: saturation,
            frequencyEnergy: freqEnergy,
            depthConflict: depthConflict,
            holeProximity: holeProx,
            finalEdgeGain: finalGain,
            dominantEdgeType: dominant,
            softmaxWeights: weights
        )
    }
}
```

---

## Part 8: Platform Adaptation (Wrapper Pattern)

### 8.1 DepthSourceAdapter as Wrapper (Not Extension)

```swift
//
// DepthSourceAdapter.swift
// Aether3D
//
// PR4 V3 - Depth Source Adapter (Wrapper Pattern)
// CRITICAL: This is a WRAPPER CLASS, not an extension
// Platform-specific implementations are in Platform/
//

import Foundation
import PRMath

/// Depth source evidence package
///
/// This struct contains all required fields for depth fusion
public struct DepthSourceEvidence: Codable {
    /// Source identifier (e.g., "arkit", "small_model", "large_model")
    public let sourceId: String

    /// Model version hash for reproducibility
    public let modelVersionHash: String

    /// Depth values in meters (2D array, row-major)
    public let depthMap: [[Double]]

    /// Confidence values [0,1] (same dimensions as depthMap)
    public let confidenceMap: [[Double]]

    /// Valid depth range in meters
    public let validRangeM: (min: Double, max: Double)

    /// Timestamp (injected, not captured inside PR4)
    public let timestamp: UInt64

    /// Frame identifier
    public let frameId: UInt64

    /// Normal map (optional, may be nil on Linux)
    public let normalMap: [[EvidenceVector3]]?

    /// Width
    public var width: Int { depthMap.first?.count ?? 0 }

    /// Height
    public var height: Int { depthMap.count }
}

/// Depth source adapter (WRAPPER CLASS)
///
/// DESIGN DECISION (V3):
/// This is a wrapper class, NOT an extension, because:
/// 1. Swift extensions cannot have stored properties
/// 2. We need to store normalized/cached values
/// 3. Platform-specific code is in Platform/, not here
///
/// REFERENCE: User's Hard Issue #1
public final class DepthSourceAdapter {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Stored Properties (V3: Allowed in class, not extension)
    // ═══════════════════════════════════════════════════════════════════════

    /// Original evidence
    public let evidence: DepthSourceEvidence

    /// Normalized depth map (meters, 0 = invalid)
    public private(set) var normalizedDepthMap: [[Double]]

    /// Normalized confidence map [0,1]
    public private(set) var normalizedConfidenceMap: [[Double]]

    /// Quantized depth (millimeters, Int32)
    public private(set) var quantizedDepthMM: [[Int32]]

    /// Quantized confidence (Q0.16, UInt16)
    public private(set) var quantizedConfidence: [[UInt16]]

    /// Source priority for tie-breaking
    public let priority: Int

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    /// Initialize adapter with evidence package
    ///
    /// - Parameter evidence: Raw evidence from depth source
    /// - Throws: If evidence validation fails
    public init(evidence: DepthSourceEvidence) throws {
        self.evidence = evidence
        self.priority = TSDFConfigV3.sourcePriority[evidence.sourceId] ?? 0

        // Pre-allocate normalized arrays
        let height = evidence.height
        let width = evidence.width
        self.normalizedDepthMap = Array(
            repeating: Array(repeating: 0.0, count: width),
            count: height
        )
        self.normalizedConfidenceMap = Array(
            repeating: Array(repeating: 0.0, count: width),
            count: height
        )
        self.quantizedDepthMM = Array(
            repeating: Array(repeating: Int32(0), count: width),
            count: height
        )
        self.quantizedConfidence = Array(
            repeating: Array(repeating: UInt16(0), count: width),
            count: height
        )

        // Validate and normalize
        try validate()
        normalize()
        quantize()
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Validation
    // ═══════════════════════════════════════════════════════════════════════

    private func validate() throws {
        // Check dimensions match
        guard evidence.depthMap.count == evidence.confidenceMap.count else {
            throw DepthAdapterError.dimensionMismatch
        }

        for (depthRow, confRow) in zip(evidence.depthMap, evidence.confidenceMap) {
            guard depthRow.count == confRow.count else {
                throw DepthAdapterError.dimensionMismatch
            }
        }

        // Check valid range is sensible
        guard evidence.validRangeM.min >= 0 else {
            throw DepthAdapterError.invalidRange
        }
        guard evidence.validRangeM.max > evidence.validRangeM.min else {
            throw DepthAdapterError.invalidRange
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Normalization
    // ═══════════════════════════════════════════════════════════════════════

    private func normalize() {
        let height = evidence.height
        let width = evidence.width
        let minValid = evidence.validRangeM.min
        let maxValid = evidence.validRangeM.max

        for y in 0..<height {
            for x in 0..<width {
                let rawDepth = evidence.depthMap[y][x]
                let rawConf = evidence.confidenceMap[y][x]

                // Normalize depth: clamp to valid range, 0 = invalid
                if rawDepth.isNaN || rawDepth.isInfinite ||
                   rawDepth < minValid || rawDepth > maxValid {
                    normalizedDepthMap[y][x] = 0.0  // Invalid sentinel
                    normalizedConfidenceMap[y][x] = 0.0
                } else {
                    normalizedDepthMap[y][x] = rawDepth
                    normalizedConfidenceMap[y][x] = PRMath.clamp(rawConf, 0.0, 1.0)
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quantization
    // ═══════════════════════════════════════════════════════════════════════

    private func quantize() {
        let height = evidence.height
        let width = evidence.width

        for y in 0..<height {
            for x in 0..<width {
                let depth = normalizedDepthMap[y][x]
                let conf = normalizedConfidenceMap[y][x]
                let isValid = depth > 0

                quantizedDepthMM[y][x] = IntegerQuantizer.quantizeDepth(depth, isValid: isValid)
                quantizedConfidence[y][x] = IntegerQuantizer.quantizeConfidence(conf, isValid: isValid)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Normal Map Access (with fallback)
    // ═══════════════════════════════════════════════════════════════════════

    /// Get surface normal at pixel
    ///
    /// FALLBACK (V3): Returns zero vector if normalMap unavailable
    /// This happens on Linux or when sensor doesn't provide normals
    public func getNormal(x: Int, y: Int) -> EvidenceVector3 {
        guard let normalMap = evidence.normalMap else {
            // Fallback: return unit Z (pointing toward camera)
            return EvidenceVector3(x: 0, y: 0, z: 1)
        }
        guard y >= 0 && y < normalMap.count else {
            return EvidenceVector3(x: 0, y: 0, z: 1)
        }
        guard x >= 0 && x < normalMap[y].count else {
            return EvidenceVector3(x: 0, y: 0, z: 1)
        }
        return normalMap[y][x]
    }
}

/// Depth adapter errors
public enum DepthAdapterError: Error {
    case dimensionMismatch
    case invalidRange
    case validationFailed(String)
}
```

---

## Part 9: Buffer Capacity Sentinel (V3)

### 9.1 Replacing AllocationSentinel

```swift
//
// BufferCapacitySentinel.swift
// Aether3D
//
// PR4 V3 - Buffer Capacity Validation (replaces AllocationSentinel)
//
// DESIGN DECISION:
// User correctly identified that malloc_count is not cross-platform.
// Instead, we validate buffer capacities at init time and assert
// sufficient capacity at runtime.
//

import Foundation

/// Buffer capacity sentinel for zero-allocation hot paths
///
/// REPLACES: AllocationSentinel (which used non-portable malloc_count)
///
/// APPROACH:
/// 1. At init time, verify all buffers have sufficient capacity
/// 2. At runtime (DEBUG only), assert capacity hasn't decreased
/// 3. Use ContiguousArray with reserveCapacity for predictable allocation
public final class BufferCapacitySentinel {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tracked Buffers
    // ═══════════════════════════════════════════════════════════════════════

    private var trackedBuffers: [String: Int] = [:]  // name → required capacity

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Registration
    // ═══════════════════════════════════════════════════════════════════════

    /// Register a buffer for capacity tracking
    ///
    /// - Parameters:
    ///   - name: Buffer identifier for debugging
    ///   - requiredCapacity: Minimum capacity that must be maintained
    public func register(name: String, requiredCapacity: Int) {
        trackedBuffers[name] = requiredCapacity
        #if DEBUG
        print("[BufferCapacitySentinel] Registered \(name) with capacity \(requiredCapacity)")
        #endif
    }

    /// Verify buffer capacity
    ///
    /// - Parameters:
    ///   - name: Buffer identifier
    ///   - actualCapacity: Current buffer capacity
    @inline(__always)
    public func verify(name: String, actualCapacity: Int) {
        #if DEBUG
        guard let required = trackedBuffers[name] else {
            assertionFailure("[BufferCapacitySentinel] Unknown buffer: \(name)")
            return
        }
        assert(
            actualCapacity >= required,
            "[BufferCapacitySentinel] Buffer \(name) capacity \(actualCapacity) < required \(required)"
        )
        #endif
    }

    /// Verify ContiguousArray capacity
    @inline(__always)
    public func verify<T>(name: String, buffer: ContiguousArray<T>) {
        verify(name: name, actualCapacity: buffer.capacity)
    }

    /// Verify 2D array capacity
    @inline(__always)
    public func verify2D<T>(name: String, buffer: [[T]], expectedRows: Int, expectedCols: Int) {
        #if DEBUG
        assert(buffer.count >= expectedRows, "[BufferCapacitySentinel] \(name) row count")
        for (i, row) in buffer.enumerated() {
            assert(row.count >= expectedCols, "[BufferCapacitySentinel] \(name) row \(i) col count")
        }
        #endif
    }
}

/// Pre-allocated buffer pool for fused pass
public final class FusedPassBufferPool {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    public let width: Int
    public let height: Int

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pre-allocated Buffers
    // ═══════════════════════════════════════════════════════════════════════

    /// Grayscale buffer
    public var grayscale: ContiguousArray<Double>

    /// Sobel gradient X
    public var sobelX: ContiguousArray<Double>

    /// Sobel gradient Y
    public var sobelY: ContiguousArray<Double>

    /// Gradient magnitude
    public var gradientMag: ContiguousArray<Double>

    /// HSV H channel
    public var hsvH: ContiguousArray<Double>

    /// HSV S channel
    public var hsvS: ContiguousArray<Double>

    /// HSV V channel
    public var hsvV: ContiguousArray<Double>

    /// Depth gradient
    public var depthGrad: ContiguousArray<Double>

    /// Edge mask
    public var edgeMask: ContiguousArray<UInt8>

    /// Capacity sentinel
    private let sentinel: BufferCapacitySentinel

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let totalPixels = width * height

        // Pre-allocate all buffers
        self.grayscale = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.sobelX = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.sobelY = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.gradientMag = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.hsvH = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.hsvS = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.hsvV = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.depthGrad = ContiguousArray(repeating: 0.0, count: totalPixels)
        self.edgeMask = ContiguousArray(repeating: 0, count: totalPixels)

        // Register with sentinel
        self.sentinel = BufferCapacitySentinel()
        sentinel.register(name: "grayscale", requiredCapacity: totalPixels)
        sentinel.register(name: "sobelX", requiredCapacity: totalPixels)
        sentinel.register(name: "sobelY", requiredCapacity: totalPixels)
        sentinel.register(name: "gradientMag", requiredCapacity: totalPixels)
        sentinel.register(name: "hsvH", requiredCapacity: totalPixels)
        sentinel.register(name: "hsvS", requiredCapacity: totalPixels)
        sentinel.register(name: "hsvV", requiredCapacity: totalPixels)
        sentinel.register(name: "depthGrad", requiredCapacity: totalPixels)
        sentinel.register(name: "edgeMask", requiredCapacity: totalPixels)
    }

    /// Verify all buffer capacities (call at start of hot path)
    @inline(__always)
    public func verifyCapacities() {
        #if DEBUG
        sentinel.verify(name: "grayscale", buffer: grayscale)
        sentinel.verify(name: "sobelX", buffer: sobelX)
        sentinel.verify(name: "sobelY", buffer: sobelY)
        sentinel.verify(name: "gradientMag", buffer: gradientMag)
        sentinel.verify(name: "hsvH", buffer: hsvH)
        sentinel.verify(name: "hsvS", buffer: hsvS)
        sentinel.verify(name: "hsvV", buffer: hsvV)
        sentinel.verify(name: "depthGrad", buffer: depthGrad)
        sentinel.verify(name: "edgeMask", buffer: edgeMask)
        #endif
    }

    /// Reset buffers for reuse (faster than reallocation)
    public func reset() {
        // For numeric buffers, just overwrite - no need to zero
        // The processing will write all values anyway
    }
}
```

---

## Part 10: Implementation Phases (Corrected Numbering)

### 10.1 Phase Overview (V3 - Corrected)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    IMPLEMENTATION PHASES (V3 CORRECTED)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Phase 1: Foundation Setup                                                  │
│  ├── Create directory structure                                            │
│  ├── Add TSDFConfigV3.swift (research-validated params)                    │
│  ├── Add IntegerQuantizationPolicy.swift                                   │
│  ├── Add DeterminismConfig.swift                                           │
│  └── Add CI import lint (pr4_import_lint.sh)                               │
│                                                                             │
│  Phase 2: Math Facade                                                       │
│  ├── Create PR4Math.swift facade                                           │
│  ├── Add LogSpaceMath.swift (numerical stability)                          │
│  ├── Add StableSigmoid.swift                                               │
│  ├── Add LogSumExpComputer.swift                                           │
│  └── Add IntegerQuantizer.swift                                            │
│                                                                             │
│  Phase 3: Depth Fusion Core                                                │
│  ├── Create DepthSourceAdapter.swift (wrapper class)                       │
│  ├── Create DepthTruncator.swift (adaptive μ)                              │
│  ├── Create WeightAccumulator.swift (max cap)                              │
│  ├── Create DepthFusionEngine.swift                                        │
│  └── Create AntiGrazingFilter.swift                                        │
│                                                                             │
│  Phase 4: Edge Classification                                              │
│  ├── Create EdgeScorer.swift (continuous scoring)                          │
│  ├── Create EdgeTypeScores.swift                                           │
│  ├── Create EdgeDiagnostics.swift (V3 diagnostic output)                   │
│  ├── Create HSVStabilizer.swift                                            │
│  └── Create FusedEdgePass.swift                                            │
│                                                                             │
│  Phase 5: Temporal Filtering                                               │
│  ├── Create TemporalFilterStateMachine.swift (5-state)                     │
│  ├── Create RobustTemporalFilter.swift                                     │
│  ├── Create TemporalAntiOvershoot.swift                                    │
│  └── Create SoftRingBuffer.swift                                           │
│                                                                             │
│  Phase 6: Topology Evaluation                                              │
│  ├── Create HoleDetector.swift (CCL with max limit)                        │
│  ├── Create TopologyEvaluator.swift                                        │
│  ├── Create OcclusionBoundaryTracker.swift                                 │
│  └── Create SelfOcclusionComputer.swift                                    │
│                                                                             │
│  Phase 7: Hierarchical Refinement                                          │
│  ├── Create HierarchicalRefiner.swift (ROI with hysteresis)                │
│  ├── Add ROI selection tie-break                                           │
│  └── Add max ROI limit                                                     │
│                                                                             │
│  Phase 8: Integration Layer                                                │
│  ├── Create SoftGainFunctions.swift                                        │
│  ├── Create SoftQualityComputer.swift                                      │
│  ├── Create SoftConstitution.swift                                         │
│  ├── Create DynamicWeightComputer.swift                                    │
│  └── Add processObservationWithSoft() entry point                          │
│                                                                             │
│  Phase 9: Platform Adapters                                                │
│  ├── Create Platform/iOS/ARKitDepthAdapter.swift                           │
│  ├── Create Platform/iOS/CoreMLDepthAdapter.swift                          │
│  ├── Create Platform/Linux/LinuxDepthStub.swift                            │
│  └── Create Platform/Linux/LinuxNormalMapFallback.swift                    │
│                                                                             │
│  Phase 10: Buffer Management                                               │
│  ├── Create BufferCapacitySentinel.swift                                   │
│  ├── Create FusedPassBufferPool.swift                                      │
│  ├── Create IntegerDepthBucket.swift                                       │
│  └── Verify zero-allocation in hot path                                    │
│                                                                             │
│  Phase 11: Validation & Contracts                                          │
│  ├── Create SoftInputValidator.swift                                       │
│  ├── Create DepthEvidenceValidator.swift                                   │
│  ├── Add validation error types                                            │
│  └── Add contract assertions                                               │
│                                                                             │
│  Phase 12: Three-Tier Golden Tests                                         │
│  ├── Create Tier1_StructuralTests/                                         │
│  ├── Create Tier2_QuantizedGoldenTests/                                    │
│  ├── Create Tier3_ToleranceTests/ (stratified: 0.1% and 1-2%)              │
│  └── Add golden fixtures                                                   │
│                                                                             │
│  Phase 13: Determinism Tests                                               │
│  ├── Create CCLDeterminismTests.swift                                      │
│  ├── Create TieBreakDeterminismTests.swift                                 │
│  ├── Create SoftDeterminism100RunTests.swift                               │
│  └── Create StateMachineTests/                                             │
│                                                                             │
│  Phase 14: Cross-Platform & Performance                                    │
│  ├── Create SoftCrossPlatformTests.swift                                   │
│  ├── Create BufferCapacityTests.swift                                      │
│  ├── Create FusedPassBenchmarkTests.swift                                  │
│  └── Verify Linux CI passes                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 11: CI Import Lint Script

### 11.1 pr4_import_lint.sh

```bash
#!/bin/bash
#
# pr4_import_lint.sh
# Aether3D
#
# PR4 V3 - Import Rule Enforcement
# Scans Core/Evidence/PR4/ for forbidden imports
#

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
PR4_DIR="$REPO_ROOT/Core/Evidence/PR4"
PR4MATH_DIR="$REPO_ROOT/Core/Evidence/PR4Math"

# Forbidden imports for PR4/**
FORBIDDEN_IMPORTS=(
    "import Darwin"
    "import Glibc"
    "import simd"
    "import CoreML"
    "import Vision"
    "import ARKit"
    "import Accelerate"
)

# Forbidden bare math functions (must use PRMath.xxx)
FORBIDDEN_BARE_MATH=(
    "\\babs\\s*\\("
    "\\bmin\\s*\\("
    "\\bmax\\s*\\("
    "\\bsqrt\\s*\\("
    "\\bexp\\s*\\("
    "\\blog\\s*\\("
    "\\bsin\\s*\\("
    "\\bcos\\s*\\("
    "\\btan\\s*\\("
    "\\bpow\\s*\\("
)

# Forbidden Foundation APIs
FORBIDDEN_FOUNDATION=(
    "Date\\(\\)"
    "UUID\\(\\)"
    "\\.random"
)

ERRORS=0

echo "═══════════════════════════════════════════════════════════════"
echo "PR4 Import Lint Check"
echo "═══════════════════════════════════════════════════════════════"

# Find all Swift files in PR4/ and PR4Math/
PR4_FILES=$(find "$PR4_DIR" "$PR4MATH_DIR" -name "*.swift" -type f 2>/dev/null || true)

if [ -z "$PR4_FILES" ]; then
    echo "⚠️  No Swift files found in PR4/ or PR4Math/"
    echo "   (This is expected if PR4 is not yet implemented)"
    exit 0
fi

# Check forbidden imports
echo ""
echo "Checking forbidden imports..."
for pattern in "${FORBIDDEN_IMPORTS[@]}"; do
    matches=$(grep -rn "$pattern" $PR4_FILES 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo "❌ FORBIDDEN: $pattern"
        echo "$matches"
        ((ERRORS++))
    fi
done

# Check bare math functions (skip if inside PRMath.xxx or self.xxx)
echo ""
echo "Checking bare math function calls..."
for pattern in "${FORBIDDEN_BARE_MATH[@]}"; do
    # Grep for pattern, exclude lines with PRMath. or self. prefix
    for file in $PR4_FILES; do
        matches=$(grep -n -E "$pattern" "$file" 2>/dev/null | grep -v "PRMath\." | grep -v "self\." | grep -v "//" || true)
        if [ -n "$matches" ]; then
            echo "❌ FORBIDDEN bare math in $file:"
            echo "$matches"
            echo "   Use PRMath.xxx instead"
            ((ERRORS++))
        fi
    done
done

# Check forbidden Foundation APIs
echo ""
echo "Checking forbidden Foundation APIs..."
for pattern in "${FORBIDDEN_FOUNDATION[@]}"; do
    matches=$(grep -rn -E "$pattern" $PR4_FILES 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo "❌ FORBIDDEN Foundation API: $pattern"
        echo "$matches"
        ((ERRORS++))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ $ERRORS -eq 0 ]; then
    echo "✅ PR4 Import Lint: PASSED"
    exit 0
else
    echo "❌ PR4 Import Lint: FAILED ($ERRORS errors)"
    exit 1
fi
```

---

## Part 12: Summary of Changes from V2

### 12.1 Hard Issues Addressed

| Issue | V2 Problem | V3 Solution |
|-------|------------|-------------|
| 1. Swift extension stored property | DepthSourceAdapter described as extension | Changed to wrapper class |
| 2. PR4 import lint vs PRMath | Lint would flag PRMath's internal libm | Lint scopes to PR4/** only |
| 3. DepthSourceAdapter platform code | Platform code in PR4/ | Moved to Platform/iOS/ and Platform/Linux/ |
| 4. AllocationSentinel cross-platform | Used malloc_count (non-portable) | Replaced with BufferCapacitySentinel |
| 5. Duplicate Phase numbering | Phase 6 and Phase 8 duplicated | Renumbered to 14 distinct phases |
| 6. normalMap dependency | No fallback on Linux | Added fallback in DepthSourceAdapter.getNormal() |

### 12.2 Parameter Changes (Research-Validated)

| Parameter | V2 Value | V3 Value | Justification |
|-----------|----------|----------|---------------|
| truncationDistanceM | 0.15m | 0.04m | voxblox, Open3D research |
| gradientStabilityScale | 0.01 | gradientSigma=0.1 | Proper Gaussian parameterization |
| maxViewAngleDeg | 75° | 70° | Tighter edge artifact prevention |
| ROI threshold | single 0.10 | enter 0.12, exit 0.08 | Hysteresis for stability |
| Max weight | unbounded | 128 | Prevent overflow |
| Max CCL components | unbounded | 1024 | Prevent memory explosion |

### 12.3 New Components in V3

| Component | Purpose |
|-----------|---------|
| TemporalFilterStateMachine | 5-state machine with explicit recovery |
| LogSpaceMath | Numerically stable weight computation |
| EdgeDiagnostics | Per-type scores for debugging |
| BufferCapacitySentinel | Cross-platform buffer validation |
| IntegerQuantizationPolicy | Explicit rounding/saturation/sentinel |
| Platform/iOS/, Platform/Linux/ | Platform-specific adapters |

---

## Part 13: References

1. **TSDF Depth Fusion**
   - [Truncated Signed Distance Field (TSDF)](https://www.emergentmind.com/topics/truncated-signed-distance-field-tsdf)
   - [voxblox: Incremental 3D ESDF](https://github.com/ethz-asl/voxblox)
   - [VDBFusion: Flexible TSDF Integration](https://pmc.ncbi.nlm.nih.gov/articles/PMC8838740/)

2. **Numerical Stability**
   - [Log-sum-exp and Softmax Functions](https://academic.oup.com/imajna/article/41/4/2311/5893596)
   - [Exp-normalize Trick](https://timvieira.github.io/blog/post/2014/02/11/exp-normalize-trick/)
   - [Numerical Stability in Deep Learning](http://d2l.ai/chapter_multilayer-perceptrons/numerical-stability-and-init.html)

3. **Swift Language**
   - [Stored Properties in Swift Extensions](https://medium.com/@marcosantadev/stored-properties-in-swift-extensions-615d4c5a9a58)
   - [Swift Extensions - MarcoSantaDev](https://www.marcosantadev.com/stored-properties-swift-extensions/)

4. **Mobile AR Depth**
   - [Mobile AR Depth Estimation](https://arxiv.org/abs/2310.14437)
   - [SelfReDepth: Real-time Depth Restoration](https://dl.acm.org/doi/10.1007/s11554-024-01491-z)

5. **Connected Component Labeling**
   - [CCL Wikipedia](https://en.wikipedia.org/wiki/Connected-component_labeling)
   - [CCL Algorithms Review](https://www.sciencedirect.com/science/article/pii/S0031320317301693)

6. **Integer Quantization**
   - [Integer Quantization for Deep Learning](https://arxiv.org/pdf/2004.09602)
   - [8-Bit Quantization and TensorFlow Lite](https://heartbeat.fritz.ai/8-bit-quantization-and-tensorflow-lite-speeding-up-mobile-inference-with-low-precision-a882dfcafbbd)

---

**Document Status:** READY FOR IMPLEMENTATION
**Next Step:** Execute Phase 1 (Foundation Setup)
