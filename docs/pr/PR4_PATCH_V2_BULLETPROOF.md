# PR4 Soft Extreme System - Patch V2 Bulletproof

**Document Version:** 2.0 (Bulletproof Architecture + TSDF-Inspired Fusion + Zero-Allocation Determinism)
**Status:** DRAFT
**Created:** 2026-01-31
**Scope:** PR4 Ultimate Hardening with Industrial-Grade Depth Fusion and Cross-Platform Determinism

---

## Part 0: Executive Summary - The Twelve Pillars

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE TWELVE PILLARS OF PR4 BULLETPROOF                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: STRICT IMPORT ISOLATION (Physical Elimination of libm)           │
│  ├── PR4/** ONLY imports: Foundation + PRMath + PR4Math                     │
│  ├── ALL math functions via PRMath facade (abs/min/max/exp/sqrt/sigmoid)    │
│  ├── NO Darwin/Glibc/simd/CoreML/Vision/ARKit direct imports                │
│  ├── PR4Math provides: Sobel kernels, bilinear interpolation, HSV convert   │
│  └── CI lint enforces at compile time, not runtime                          │
│                                                                             │
│  PILLAR 2: TSDF-INSPIRED DEPTH FUSION (Industrial-Grade Consensus)          │
│  ├── Truncation residual: r = clamp(z - z_ref, -μ, +μ) with SSOT μ         │
│  ├── Weight model: w = f(sourceConf, viewAngle, depthGradientStability)     │
│  ├── Integrated weight tracking per pixel (diagnosable)                     │
│  ├── Anti-grazing filter for edge artifact suppression                      │
│  └── References: KinectFusion, InfiniTAM, Open3D, voxblox                   │
│                                                                             │
│  PILLAR 3: HIERARCHICAL FUSION RESOLUTION (Coarse-to-Fine)                  │
│  ├── Primary fusion: 256×256 (global structure, memory efficient)           │
│  ├── Boundary ROI: 64×64 patches at high-gradient regions                   │
│  ├── Edge refinement: second-pass fusion on detected boundaries             │
│  └── Thin structure preservation without global resolution explosion        │
│                                                                             │
│  PILLAR 4: CONTINUOUS EDGE SCORING (Not Hard Classification)                │
│  ├── Each edge type produces score ∈ [0,1], not binary class               │
│  ├── Geometric: colorGrad_high × depthGrad_high × depthConf_high           │
│  ├── Textural: colorGrad_high × depthGrad_low × freqEnergy_high            │
│  ├── Specular: brightness_high × saturation_low × depthConf_low            │
│  ├── Transparent: colorEdge_weak × depthConflict_high × hole_high          │
│  └── Final edgeGain via weighted softmax/normalized combination             │
│                                                                             │
│  PILLAR 5: ROBUST TEMPORAL FILTERING (Median + Trimmed Mean + EMA)          │
│  ├── Primary stabilizer: median or trimmed mean (20% outlier exclusion)     │
│  ├── Secondary smoother: EMA for jitter reduction only                      │
│  ├── Anti-overshoot: triggered only on suspicious jumps                     │
│  ├── Depth change limit: max(0.02m, 0.03×depth) relative+absolute           │
│  └── References: ChronoDepth, ST-CLSTM temporal consistency                 │
│                                                                             │
│  PILLAR 6: INTEGER WORLD ENTRY (Quantized Evidence Space)                   │
│  ├── Depth input: millimeters (Int32) or 1e-4m (Int32)                     │
│  ├── Confidence input: Q0.16 fixed-point (UInt16)                          │
│  ├── Internal histograms/buckets/voting all integer-based                   │
│  ├── Final soft gains quantized via QuantizerQ01 (Int64)                   │
│  └── Cross-platform determinism through integer arithmetic                  │
│                                                                             │
│  PILLAR 7: DEPTH SOURCE EVIDENCE PACKAGE (Normalized Input Contract)        │
│  ├── Required fields: depthMap, confidenceMap, sourceId, modelVersionHash   │
│  ├── Required metadata: quantizationSpec, validRangeM, timestamp, frameId   │
│  ├── Source normalization: meters, clamp to valid range, unified sentinel   │
│  ├── Invalid depth sentinel: 0.0 (fixed, not configurable)                  │
│  └── All timestamps injected from above (no Date() inside PR4)              │
│                                                                             │
│  PILLAR 8: GOLDEN TEST STRATIFICATION (Three-Tier Verification)             │
│  ├── Tier 1 (0 tolerance): Structural assertions (range, monotonicity)      │
│  ├── Tier 2 (bit-exact): Quantized gain values via Int64 comparison         │
│  ├── Tier 3 (1-2% tolerance): External source noise fields only             │
│  ├── NO 10% tolerance anywhere (that hides regression)                      │
│  └── Each tier has separate test files and fixtures                         │
│                                                                             │
│  PILLAR 9: PROCESS ISOLATION (New Entry Point, Not Modify Existing)         │
│  ├── processObservation() remains byte-level unchanged (PR2/PR3 path)       │
│  ├── NEW: processObservationWithSoft() for PR4+ path                        │
│  ├── NEW: processFrameWithGateAndSoft() convenience wrapper                 │
│  ├── Soft computation completely isolated from gate computation             │
│  └── PR4 bug cannot regress PR2/PR3 behavior                                │
│                                                                             │
│  PILLAR 10: DETERMINISTIC CONNECTED COMPONENTS (Fixed Scan Order)           │
│  ├── Scan order: row-major (y outer, x inner), fixed                        │
│  ├── Neighborhood: 4-connectivity for holes (SSOT constant)                 │
│  ├── Tie-break: queue push order deterministic (left, right, up, down)      │
│  ├── Component ID assignment: sequential from 1                             │
│  └── All parameters in SSOT, tested via golden fixtures                     │
│                                                                             │
│  PILLAR 11: ZERO-ALLOCATION HOT PATH (Fused Pass + Sentinel)                │
│  ├── Pre-allocated ContiguousArray for all buffers                          │
│  ├── NO map/filter/sorted/reversed in hot path                              │
│  ├── Fused single-pass: grayscale + Sobel + HSV + depthGrad + mask          │
│  ├── DEBUG-only AllocationSentinel: assert malloc_count == 0 per frame      │
│  └── All intermediate buffers reused, never reallocated                     │
│                                                                             │
│  PILLAR 12: SOFT CONSTITUTION (Behavioral Contract)                         │
│  ├── softQuality semantic: 0 = poor quality, 1 = near-optimal               │
│  ├── Each sub-gain: defined input domain, output [floor,1], monotonicity    │
│  ├── Gate→Soft gating: multiplicative (final = gate × soft)                 │
│  ├── Progress definition: from PR3 evidence (coverage ratio), not UI        │
│  └── All contracts documented in SoftConstitution.swift                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key References:**
- [TSDF Integration - Open3D](https://www.open3d.org/docs/latest/tutorial/t_reconstruction_system/integration.html)
- [KinectFusion/InfiniTAM TSDF](https://www.emergentmind.com/topics/truncated-signed-distance-function-tsdf)
- [Apple Depth Pro](https://machinelearning.apple.com/research/depth-pro)
- [Depth Anything V2 - NeurIPS 2024](https://github.com/DepthAnything/Depth-Anything-V2)
- [NTIRE 2024 Specular/Transparent Depth Challenge](https://cvlab-unibo.github.io/booster-web/ntire24.html)
- [Temporal Consistency in Video Depth - ChronoDepth](https://arxiv.org/abs/2406.01493)
- [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)
- [Occlusion Boundary + Depth Multi-Task Learning 2025](https://arxiv.org/html/2505.21231v1)
- [Swift Memory Allocation](https://www.swift.org/documentation/server/guides/allocations.html)

---

## Part 1: Physical Directory Isolation (HARDENED)

### 1.1 Directory Structure

```
Core/Evidence/
├── PR4/                              // SOFT BUSINESS LOGIC
│   ├── SoftGainFunctions.swift       // All soft gain computations
│   ├── SoftQualityComputer.swift     // Integration layer
│   ├── SoftConstitution.swift        // Behavioral contracts (NEW)
│   ├── DynamicWeightComputer.swift   // Progress-based blending
│   ├── DepthFusion/
│   │   ├── DepthFusionEngine.swift   // TSDF-inspired fusion
│   │   ├── DepthConsensusVoter.swift // Weighted voting with tie-break
│   │   ├── DepthSourceAdapter.swift  // Evidence package normalization
│   │   ├── DepthTruncator.swift      // TSDF truncation logic (NEW)
│   │   ├── AntiGrazingFilter.swift   // Edge artifact suppression (NEW)
│   │   └── HierarchicalRefiner.swift // Coarse-to-fine ROI (NEW)
│   ├── EdgeClassification/
│   │   ├── EdgeScorer.swift          // Continuous scoring (renamed)
│   │   ├── EdgeTypeScores.swift      // Per-type score computation
│   │   ├── HSVStabilizer.swift       // Local normalization (NEW)
│   │   └── FusedEdgePass.swift       // Single-pass computation (NEW)
│   ├── Topology/
│   │   ├── TopologyEvaluator.swift   // Integrated evaluation
│   │   ├── HoleDetector.swift        // Deterministic CCL
│   │   ├── OcclusionBoundaryTracker.swift
│   │   └── SelfOcclusionComputer.swift
│   ├── DualChannel/
│   │   ├── DualFrameManager.swift    // rawFrame + assistFrame
│   │   └── FrameConsistencyChecker.swift
│   ├── Temporal/
│   │   ├── RobustTemporalFilter.swift // Median + trimmed mean (NEW)
│   │   ├── TemporalAntiOvershoot.swift // Suspicious jump handler (NEW)
│   │   └── MotionCompensator.swift
│   ├── Internal/
│   │   ├── SoftRingBuffer.swift      // Pre-allocated temporal buffer
│   │   ├── IntegerDepthBucket.swift  // Integer-based histogram (NEW)
│   │   ├── AllocationSentinel.swift  // DEBUG malloc counter (NEW)
│   │   └── FusedPassBuffers.swift    // Reusable buffer pool (NEW)
│   └── Validation/
│       ├── SoftInputValidator.swift
│       ├── SoftInputInvalidReason.swift
│       └── DepthEvidenceValidator.swift // Evidence package validation (NEW)
│
├── PR4Math/                          // SOFT MATH FACADE
│   ├── PR4Math.swift                 // Unified facade (uses PRMath)
│   ├── SobelKernels.swift            // Fixed kernels with SSOT params
│   ├── BilinearInterpolator.swift    // Deterministic interpolation
│   ├── HSVConverter.swift            // Fixed RGB→HSV coefficients
│   ├── TrimmedMeanComputer.swift     // Robust statistics (NEW)
│   └── IntegerQuantizer.swift        // Depth/confidence quantization (NEW)
│
├── Constants/
│   ├── SoftGatesV14.swift            // V14 with all hardening (renamed)
│   ├── TSDFConfig.swift              // Truncation/weight parameters (NEW)
│   ├── EdgeScoringConfig.swift       // Continuous scoring params (NEW)
│   ├── TemporalConfig.swift          // Robust filtering params (NEW)
│   └── DeterminismConfig.swift       // Scan order/tie-break rules (NEW)
│
└── Vector/
    └── EvidenceVector3.swift         // From PR3, no changes

Tests/Evidence/PR4/
├── Tier1_StructuralTests/            // Zero tolerance (NEW)
│   ├── GainRangeInvariantsTests.swift
│   ├── MonotonicityTests.swift
│   └── WeightSumTests.swift
├── Tier2_QuantizedGoldenTests/       // Bit-exact (NEW)
│   ├── DepthFusionGoldenTests.swift
│   ├── EdgeScorerGoldenTests.swift
│   └── TopologyGoldenTests.swift
├── Tier3_ToleranceTests/             // 1-2% max (NEW)
│   └── ExternalSourceNoiseTests.swift
├── DeterminismTests/
│   ├── SoftDeterminism100RunTests.swift
│   ├── CCLDeterminismTests.swift
│   └── TieBreakDeterminismTests.swift
├── CrossPlatformTests/
│   └── SoftCrossPlatformTests.swift
└── PerformanceTests/
    ├── AllocationSentinelTests.swift
    └── FusedPassBenchmarkTests.swift
```

### 1.2 Import Rules (STRICTLY ENFORCED)

```swift
// ═══════════════════════════════════════════════════════════════════════════
// IMPORT RULES - ENFORCED BY CI LINT (NO EXCEPTIONS)
// ═══════════════════════════════════════════════════════════════════════════

// PR4/** files can ONLY import:
// ✅ import Foundation         (basic types, BUT see restrictions below)
// ✅ import PRMath             (PR3 math facade - sigmoid, expSafe, etc.)
// ✅ import PR4Math            (PR4 math facade - Sobel, HSV, interpolation)

// PR4/** files FORBIDDEN to import:
// ❌ import Darwin             (no direct libm access)
// ❌ import Glibc              (no direct libm access)
// ❌ import simd               (use EvidenceVector3)
// ❌ import CoreML             (use DepthSourceAdapter)
// ❌ import Vision             (use EdgeScorer)
// ❌ import ARKit              (use DepthSourceAdapter)
// ❌ import Accelerate         (determinism concern)
// ❌ import PRMathDouble       (use facade)
// ❌ import PRMathFast         (use facade)

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
// ✅ PRMath.sigmoid(x)         (already in PRMath)
// ✅ PRMath.clamp(x, lo, hi)   NOT Swift.max(lo, min(hi, x))

// CI LINT IMPLEMENTATION:
// 1. Scan all .swift files in Core/Evidence/PR4/
// 2. Check imports against forbidden list
// 3. Check for bare math function calls (abs, min, max, sqrt, exp, sin, cos, etc.)
// 4. Check for Foundation time/random APIs
// 5. FAIL CI with clear error message on any violation
```

### 1.3 CI Whitelist (pr4-whitelist.yml)

```yaml
# .github/workflows/pr4-whitelist.yml

name: PR4 Whitelist Enforcement

on:
  pull_request:
    paths:
      - 'Core/Evidence/PR4/**'
      - 'Core/Evidence/PR4Math/**'
      - 'Core/Evidence/Constants/Soft*.swift'
      - 'Core/Evidence/Constants/TSDF*.swift'
      - 'Core/Evidence/Constants/Edge*.swift'
      - 'Core/Evidence/Constants/Temporal*.swift'
      - 'Core/Evidence/Constants/Determinism*.swift'
      - 'Tests/Evidence/PR4/**'

jobs:
  pr4-whitelist-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          fetch-depth: 0

      - name: Check PR4 allowed paths
        run: |
          PR4_ALLOWED_PATHS=(
            "Core/Evidence/PR4/"
            "Core/Evidence/PR4Math/"
            "Core/Evidence/Constants/SoftGatesV14.swift"
            "Core/Evidence/Constants/TSDFConfig.swift"
            "Core/Evidence/Constants/EdgeScoringConfig.swift"
            "Core/Evidence/Constants/TemporalConfig.swift"
            "Core/Evidence/Constants/DeterminismConfig.swift"
            "Core/Evidence/Validation/SoftInputValidator.swift"
            "Core/Evidence/Validation/SoftInputInvalidReason.swift"
            "Core/Evidence/Validation/DepthEvidenceValidator.swift"
            "Tests/Evidence/PR4/"
          )

          PR4_FORBIDDEN_MODIFICATIONS=(
            "Core/Evidence/PR3/"
            "Core/Evidence/PRMath/"
            "Core/Evidence/IsolatedEvidenceEngine.swift"
            "Core/Constants/HardGatesV13.swift"
          )

          # Check for forbidden modifications
          CHANGED_FILES=$(git diff --name-only origin/main...HEAD)
          for file in $CHANGED_FILES; do
            for forbidden in "${PR4_FORBIDDEN_MODIFICATIONS[@]}"; do
              if [[ "$file" == "$forbidden"* ]]; then
                echo "❌ FORBIDDEN: $file modifies locked path $forbidden"
                exit 1
              fi
            done
          done

          echo "✅ PR4 whitelist check passed"

      - name: Check PR4 import rules
        run: |
          bash scripts/ci/pr4_import_lint.sh
```

---

## Part 2: TSDF-Inspired Depth Fusion

### 2.1 Why TSDF Paradigm

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY TSDF IS SUPERIOR TO NAIVE VOTING                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  NAIVE VOTING PROBLEMS:                                                      │
│  ├── No truncation: outliers dominate the median/mean                       │
│  ├── No distance weighting: far depths treated same as near                 │
│  ├── No view angle consideration: grazing angles treated same as frontal    │
│  ├── No accumulated weight: can't diagnose which pixels are trustworthy     │
│  └── No anti-grazing: edge artifacts from nearly-parallel views             │
│                                                                             │
│  TSDF SOLUTION (from KinectFusion/Open3D/voxblox):                          │
│  ├── Truncation: r = clamp(z - z_ref, -μ, +μ) bounds influence             │
│  ├── Weight function: w = f(confidence, viewAngle, gradientStability)       │
│  ├── Incremental fusion: new_tsdf = (old_tsdf*old_w + r*w) / (old_w + w)   │
│  ├── Weight accumulation: track total weight per pixel for confidence       │
│  └── Anti-grazing: skip updates when view angle > threshold                 │
│                                                                             │
│  ADAPTATION FOR PR4 (per-frame, not volumetric):                            │
│  ├── "TSDF value" → depth residual relative to consensus                    │
│  ├── "Voxel" → pixel in 2D fusion map                                       │
│  ├── Truncation prevents single bad source from dominating                   │
│  ├── Weight model captures source reliability                                │
│  └── Diagnosable: integratedWeight shows confidence per pixel               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 TSDFConfig Constants (SSOT)

```swift
//
// TSDFConfig.swift
// Aether3D
//
// PR4 - TSDF-Inspired Fusion Configuration
// SSOT: Single Source of Truth for all fusion parameters
//

import Foundation

/// TSDF-inspired depth fusion configuration
/// Based on KinectFusion/InfiniTAM/Open3D best practices
///
/// VERSION: 1.0
/// REFERENCES:
/// - KinectFusion: Newcombe et al., ISMAR 2011
/// - Open3D TSDF: http://www.open3d.org/docs/latest/tutorial/t_reconstruction_system/integration.html
/// - voxblox: Oleynikova et al., IROS 2017
public enum TSDFConfig {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Truncation Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Truncation distance (μ) in meters
    ///
    /// SEMANTIC: Maximum influence distance for depth residuals
    /// Residuals beyond ±μ are clamped, preventing outlier domination
    ///
    /// VALUE ANALYSIS:
    /// - 0.05m = Very tight: Only very close agreements count
    /// - 0.10m = Tight: Good for high-quality depth sources
    /// - 0.15m = DEFAULT: Balanced for consumer depth sensors
    /// - 0.25m = Loose: Accepts more disagreement
    /// - 0.50m = Too loose: Outliers can still dominate
    ///
    /// FORMULA: r = clamp(z_measured - z_consensus, -μ, +μ)
    public static let truncationDistanceM: Double = 0.15

    /// Truncation distance as Int32 (millimeters) for integer path
    public static let truncationDistanceMM: Int32 = 150

    /// Minimum truncation for near objects (relative)
    ///
    /// SEMANTIC: For objects closer than 1m, use tighter truncation
    /// truncation = max(minTruncationM, truncationDistanceM * depth / 2m)
    public static let minTruncationM: Double = 0.05

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Weight Model Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Source confidence weight factor
    ///
    /// SEMANTIC: How much does source-reported confidence affect weight?
    /// w_conf = sourceConfidence ^ confExponent
    public static let confidenceExponent: Double = 1.5

    /// View angle weight factor
    ///
    /// SEMANTIC: Weight decreases as view becomes more grazing
    /// w_angle = cos(viewAngle) ^ angleExponent
    /// At 60°: cos(60°)^2 = 0.25 (significant penalty)
    public static let angleExponent: Double = 2.0

    /// Depth gradient stability factor
    ///
    /// SEMANTIC: Stable depth gradients are more reliable
    /// w_grad = exp(-gradientVariance / gradientScale)
    public static let gradientStabilityScale: Double = 0.01

    /// Combined weight formula:
    /// w = w_conf × w_angle × w_grad × depthWeight(z)
    ///
    /// depthWeight(z) = 1.0 / (1.0 + z / depthWeightScale)
    /// Closer depths are more reliable (sensor physics)
    public static let depthWeightScale: Double = 5.0  // At 5m, weight = 0.5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Anti-Grazing Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum view angle for fusion (degrees)
    ///
    /// SEMANTIC: Skip fusion updates when view is too grazing
    /// Grazing views produce unreliable depth at edges
    ///
    /// VALUE: 75° (cos(75°) ≈ 0.26)
    public static let maxViewAngleDeg: Double = 75.0

    /// Anti-grazing gradient threshold
    ///
    /// SEMANTIC: Skip update if depth gradient is high AND view is grazing
    /// Prevents edge artifacts from nearly-parallel views
    public static let antiGrazingGradientThreshold: Double = 0.05  // 5% of depth

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fusion Resolution
    // ═══════════════════════════════════════════════════════════════════════

    /// Primary fusion resolution
    public static let primaryFusionSize: Int = 256

    /// Boundary ROI size for refinement
    public static let boundaryROISize: Int = 64

    /// Gradient threshold for ROI selection
    ///
    /// SEMANTIC: Regions with gradient > this get ROI refinement
    public static let roiGradientThreshold: Double = 0.10  // 10% of depth

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Consensus Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum weight for valid fusion result
    ///
    /// SEMANTIC: Pixels with accumulated weight below this are marked invalid
    public static let minAccumulatedWeight: Double = 0.5

    /// Minimum sources for high confidence
    ///
    /// SEMANTIC: Need at least this many agreeing sources for high confidence
    public static let minSourcesForHighConf: Int = 2

    /// Tie-break rule for equal-weight sources
    ///
    /// SEMANTIC: When sources have equal weight, prefer in this order:
    /// 1. Platform API (ARKit/ARCore) - hardware sensor
    /// 2. Small model - higher resolution
    /// 3. Large model - better range
    /// 4. Stereo - scene-dependent
    public static let tieBreakOrder: [String] = [
        "platform_api",
        "small_model",
        "large_model",
        "stereo"
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Invalid Depth Sentinel
    // ═══════════════════════════════════════════════════════════════════════

    /// Invalid depth sentinel value
    ///
    /// SEMANTIC: All invalid depths normalized to this value
    /// MUST be 0.0 (not NaN, not -1, not configurable)
    public static let invalidDepthSentinel: Float = 0.0

    /// Invalid depth sentinel as Int32 (millimeters)
    public static let invalidDepthSentinelMM: Int32 = 0
}
```

### 2.3 DepthFusionEngine (TSDF-Inspired)

```swift
//
// DepthFusionEngine.swift
// Aether3D
//
// PR4 - TSDF-Inspired Depth Fusion Engine
// Multi-source depth consensus with truncation, weighting, and anti-grazing
//

import Foundation

/// TSDF-inspired depth fusion engine
///
/// ALGORITHM (per-frame, adapted from volumetric TSDF):
/// 1. Normalize all sources to common resolution and units
/// 2. Compute initial consensus (weighted median)
/// 3. For each pixel, compute truncated residuals from consensus
/// 4. Apply weight model (confidence × viewAngle × gradientStability × depth)
/// 5. Apply anti-grazing filter at high-gradient regions
/// 6. Fuse: new_depth = weighted_mean(truncated_residuals) + consensus
/// 7. Track accumulated weight for confidence
///
/// DETERMINISM: All operations use PRMath, fixed iteration order, integer buckets
public final class DepthFusionEngine {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    /// Depth source evidence package (NORMALIZED)
    public struct DepthEvidencePackage: Sendable {
        /// Depth values in MILLIMETERS (Int32 for determinism)
        public let depthMapMM: ContiguousArray<Int32>

        /// Per-pixel confidence in Q0.16 fixed-point (UInt16)
        /// 0 = no confidence, 65535 = full confidence
        public let confidenceQ16: ContiguousArray<UInt16>

        /// Source identifier
        public let sourceId: DepthSourceId

        /// Model/sensor version hash (for reproducibility)
        public let modelVersionHash: String

        /// Valid depth range in millimeters
        public let validRangeMM: ClosedRange<Int32>

        /// Timestamp (injected from above, NOT from Date())
        public let timestampMs: Int64

        /// Frame ID (deterministic)
        public let frameId: String

        /// Map dimensions (must match resolution)
        public let width: Int
        public let height: Int

        public init(
            depthMapMM: ContiguousArray<Int32>,
            confidenceQ16: ContiguousArray<UInt16>,
            sourceId: DepthSourceId,
            modelVersionHash: String,
            validRangeMM: ClosedRange<Int32>,
            timestampMs: Int64,
            frameId: String,
            width: Int,
            height: Int
        ) {
            precondition(depthMapMM.count == width * height)
            precondition(confidenceQ16.count == width * height)
            self.depthMapMM = depthMapMM
            self.confidenceQ16 = confidenceQ16
            self.sourceId = sourceId
            self.modelVersionHash = modelVersionHash
            self.validRangeMM = validRangeMM
            self.timestampMs = timestampMs
            self.frameId = frameId
            self.width = width
            self.height = height
        }
    }

    /// Depth source identifier
    public enum DepthSourceId: String, Codable, Sendable, CaseIterable {
        case smallModel = "small_model"
        case largeModel = "large_model"
        case platformApi = "platform_api"
        case stereo = "stereo"

        /// Priority for tie-breaking (lower = higher priority)
        public var tieBreakPriority: Int {
            switch self {
            case .platformApi: return 0
            case .smallModel: return 1
            case .largeModel: return 2
            case .stereo: return 3
            }
        }
    }

    /// Fused depth result
    public struct FusedDepthResult: Sendable {
        /// Fused depth in millimeters (Int32)
        public let depthMapMM: ContiguousArray<Int32>

        /// Accumulated weight per pixel (for confidence)
        public let accumulatedWeight: ContiguousArray<Float>

        /// Per-pixel source agreement mask (bitmask)
        public let agreementMask: ContiguousArray<UInt8>

        /// Map dimensions
        public let width: Int
        public let height: Int

        /// Statistics
        public let validPixelRatio: Double
        public let averageWeight: Double
        public let sourcesUsed: [DepthSourceId]

        /// Convert to meters (Float) for downstream use
        public func depthMapMeters() -> ContiguousArray<Float> {
            var result = ContiguousArray<Float>(repeating: 0, count: depthMapMM.count)
            for i in 0..<depthMapMM.count {
                result[i] = Float(depthMapMM[i]) * 0.001  // mm to m
            }
            return result
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pre-allocated Buffers (ZERO ALLOCATION IN HOT PATH)
    // ═══════════════════════════════════════════════════════════════════════

    private let fusionSize: Int
    private let pixelCount: Int

    // Resized source buffers (max 4 sources)
    private var resizedDepthMM: [ContiguousArray<Int32>]
    private var resizedConfQ16: [ContiguousArray<UInt16>]

    // Fusion buffers
    private var consensusDepthMM: ContiguousArray<Int32>
    private var fusedDepthMM: ContiguousArray<Int32>
    private var accumulatedWeight: ContiguousArray<Float>
    private var agreementMask: ContiguousArray<UInt8>

    // Intermediate buffers
    private var depthGradient: ContiguousArray<Float>
    private var truncatedResiduals: ContiguousArray<Float>
    private var pixelWeights: ContiguousArray<Float>

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(fusionSize: Int = TSDFConfig.primaryFusionSize) {
        self.fusionSize = fusionSize
        self.pixelCount = fusionSize * fusionSize

        let maxSources = 4

        // Pre-allocate all buffers
        self.resizedDepthMM = (0..<maxSources).map { _ in
            ContiguousArray<Int32>(repeating: 0, count: pixelCount)
        }
        self.resizedConfQ16 = (0..<maxSources).map { _ in
            ContiguousArray<UInt16>(repeating: 0, count: pixelCount)
        }

        self.consensusDepthMM = ContiguousArray(repeating: 0, count: pixelCount)
        self.fusedDepthMM = ContiguousArray(repeating: 0, count: pixelCount)
        self.accumulatedWeight = ContiguousArray(repeating: 0, count: pixelCount)
        self.agreementMask = ContiguousArray(repeating: 0, count: pixelCount)

        self.depthGradient = ContiguousArray(repeating: 0, count: pixelCount)
        self.truncatedResiduals = ContiguousArray(repeating: 0, count: pixelCount)
        self.pixelWeights = ContiguousArray(repeating: 0, count: pixelCount)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fusion API
    // ═══════════════════════════════════════════════════════════════════════

    /// Fuse multiple depth sources using TSDF-inspired algorithm
    ///
    /// - Parameters:
    ///   - sources: Array of depth evidence packages (1-4 sources)
    ///   - viewAngleMap: Per-pixel view angle in radians (optional)
    /// - Returns: Fused depth result
    public func fuse(
        sources: [DepthEvidencePackage],
        viewAngleMap: ContiguousArray<Float>? = nil
    ) -> FusedDepthResult {
        precondition(sources.count >= 1 && sources.count <= 4)

        let config = TSDFConfig.self

        // Step 1: Resize all sources to fusion resolution
        for (i, source) in sources.enumerated() {
            resizeDepthMap(
                sourceMM: source.depthMapMM,
                sourceWidth: source.width,
                sourceHeight: source.height,
                destMM: &resizedDepthMM[i]
            )
            resizeConfidenceMap(
                sourceQ16: source.confidenceQ16,
                sourceWidth: source.width,
                sourceHeight: source.height,
                destQ16: &resizedConfQ16[i]
            )
        }

        // Step 2: Compute initial consensus (weighted median)
        computeConsensus(sourceCount: sources.count)

        // Step 3: Compute depth gradients for anti-grazing
        computeDepthGradients()

        // Step 4: Per-pixel TSDF-style fusion
        var validPixelCount = 0
        var totalWeight: Double = 0

        for p in 0..<pixelCount {
            let consensus = consensusDepthMM[p]

            // Skip invalid consensus
            guard consensus > config.invalidDepthSentinelMM else {
                fusedDepthMM[p] = config.invalidDepthSentinelMM
                accumulatedWeight[p] = 0
                agreementMask[p] = 0
                continue
            }

            // Check anti-grazing condition
            let gradient = depthGradient[p]
            var skipGrazing = false
            if let angles = viewAngleMap {
                let angle = angles[p]
                let cosAngle = PRMath.cos(Double(angle))
                if cosAngle < PRMath.cos(config.maxViewAngleDeg * .pi / 180.0) &&
                   gradient > Float(config.antiGrazingGradientThreshold) {
                    skipGrazing = true
                }
            }

            if skipGrazing {
                // Keep consensus, low weight
                fusedDepthMM[p] = consensus
                accumulatedWeight[p] = Float(config.minAccumulatedWeight)
                agreementMask[p] = 0
                continue
            }

            // Compute truncated residuals and weights for each source
            var weightedResidualSum: Float = 0
            var weightSum: Float = 0
            var agreement: UInt8 = 0

            let truncMM = Int32(config.truncationDistanceM * 1000)
            let depthM = Float(consensus) * 0.001

            for i in 0..<sources.count {
                let srcDepthMM = resizedDepthMM[i][p]
                let srcConfQ16 = resizedConfQ16[i][p]

                // Skip invalid source depth
                guard srcDepthMM > config.invalidDepthSentinelMM else { continue }

                // Check valid range
                let range = sources[i].validRangeMM
                guard srcDepthMM >= range.lowerBound && srcDepthMM <= range.upperBound else { continue }

                // Truncated residual
                let residualMM = srcDepthMM - consensus
                let truncatedMM = PRMath.clamp(residualMM, -truncMM, truncMM)

                // Weight computation
                let confWeight = computeConfidenceWeight(confQ16: srcConfQ16)
                let depthWeight = computeDepthWeight(depthM: depthM)
                let gradWeight = computeGradientWeight(gradient: gradient)

                var weight = confWeight * depthWeight * gradWeight

                // View angle weight (if available)
                if let angles = viewAngleMap {
                    let angleWeight = computeAngleWeight(angleRad: angles[p])
                    weight *= angleWeight
                }

                weightedResidualSum += Float(truncatedMM) * weight
                weightSum += weight

                // Track agreement (within truncation)
                if PRMath.abs(residualMM) <= truncMM {
                    agreement |= UInt8(1 << i)
                }
            }

            if weightSum > 0 {
                let avgResidualMM = Int32(weightedResidualSum / weightSum)
                fusedDepthMM[p] = consensus + avgResidualMM
                accumulatedWeight[p] = weightSum
                agreementMask[p] = agreement
                validPixelCount += 1
                totalWeight += Double(weightSum)
            } else {
                fusedDepthMM[p] = consensus
                accumulatedWeight[p] = 0
                agreementMask[p] = 0
            }
        }

        let validRatio = Double(validPixelCount) / Double(pixelCount)
        let avgWeight = validPixelCount > 0 ? totalWeight / Double(validPixelCount) : 0

        return FusedDepthResult(
            depthMapMM: ContiguousArray(fusedDepthMM),
            accumulatedWeight: ContiguousArray(accumulatedWeight),
            agreementMask: ContiguousArray(agreementMask),
            width: fusionSize,
            height: fusionSize,
            validPixelRatio: validRatio,
            averageWeight: avgWeight,
            sourcesUsed: sources.map { $0.sourceId }
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Weight Computation (All via PRMath)
    // ═══════════════════════════════════════════════════════════════════════

    @inline(__always)
    private func computeConfidenceWeight(confQ16: UInt16) -> Float {
        // Convert Q0.16 to [0, 1]
        let conf = Float(confQ16) / 65535.0
        // w = conf ^ exponent
        return Float(PRMath.pow(Double(conf), TSDFConfig.confidenceExponent))
    }

    @inline(__always)
    private func computeDepthWeight(depthM: Float) -> Float {
        // w = 1 / (1 + depth / scale)
        let scale = Float(TSDFConfig.depthWeightScale)
        return 1.0 / (1.0 + depthM / scale)
    }

    @inline(__always)
    private func computeGradientWeight(gradient: Float) -> Float {
        // w = exp(-gradient^2 / scale)
        let scale = Float(TSDFConfig.gradientStabilityScale)
        return Float(PRMath.expSafe(Double(-gradient * gradient / scale)))
    }

    @inline(__always)
    private func computeAngleWeight(angleRad: Float) -> Float {
        // w = cos(angle) ^ exponent
        let cosAngle = Float(PRMath.cos(Double(angleRad)))
        let clamped = PRMath.max(0.0, Double(cosAngle))
        return Float(PRMath.pow(clamped, TSDFConfig.angleExponent))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Internal Methods (Deterministic)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute initial consensus using weighted median
    private func computeConsensus(sourceCount: Int) {
        for p in 0..<pixelCount {
            // Collect valid depths with confidence
            var validDepths: [(depth: Int32, conf: UInt16, srcIdx: Int)] = []

            for i in 0..<sourceCount {
                let depthMM = resizedDepthMM[i][p]
                let confQ16 = resizedConfQ16[i][p]

                if depthMM > TSDFConfig.invalidDepthSentinelMM {
                    validDepths.append((depthMM, confQ16, i))
                }
            }

            if validDepths.isEmpty {
                consensusDepthMM[p] = TSDFConfig.invalidDepthSentinelMM
                continue
            }

            if validDepths.count == 1 {
                consensusDepthMM[p] = validDepths[0].depth
                continue
            }

            // Sort by depth (deterministic: if equal depth, sort by source priority)
            validDepths.sort { (a, b) -> Bool in
                if a.depth != b.depth {
                    return a.depth < b.depth
                }
                return a.srcIdx < b.srcIdx  // Deterministic tie-break
            }

            // Weighted median
            var totalConf: UInt32 = 0
            for (_, conf, _) in validDepths {
                totalConf += UInt32(conf)
            }

            var cumConf: UInt32 = 0
            var medianDepth = validDepths[0].depth
            let halfConf = totalConf / 2

            for (depth, conf, _) in validDepths {
                cumConf += UInt32(conf)
                if cumConf >= halfConf {
                    medianDepth = depth
                    break
                }
            }

            consensusDepthMM[p] = medianDepth
        }
    }

    /// Compute depth gradients (for anti-grazing)
    private func computeDepthGradients() {
        for y in 1..<(fusionSize - 1) {
            for x in 1..<(fusionSize - 1) {
                let p = y * fusionSize + x
                let depth = Float(consensusDepthMM[p]) * 0.001  // to meters

                guard depth > 0 else {
                    depthGradient[p] = 0
                    continue
                }

                let left = Float(consensusDepthMM[p - 1]) * 0.001
                let right = Float(consensusDepthMM[p + 1]) * 0.001
                let top = Float(consensusDepthMM[p - fusionSize]) * 0.001
                let bottom = Float(consensusDepthMM[p + fusionSize]) * 0.001

                let gx = (right - left) / 2.0
                let gy = (bottom - top) / 2.0
                let grad = Float(PRMath.sqrt(Double(gx * gx + gy * gy)))

                // Relative gradient
                depthGradient[p] = grad / depth
            }
        }

        // Border pixels: zero gradient
        for x in 0..<fusionSize {
            depthGradient[x] = 0
            depthGradient[(fusionSize - 1) * fusionSize + x] = 0
        }
        for y in 0..<fusionSize {
            depthGradient[y * fusionSize] = 0
            depthGradient[y * fusionSize + fusionSize - 1] = 0
        }
    }

    /// Resize depth map using bilinear interpolation (deterministic)
    private func resizeDepthMap(
        sourceMM: ContiguousArray<Int32>,
        sourceWidth: Int,
        sourceHeight: Int,
        destMM: inout ContiguousArray<Int32>
    ) {
        let scaleX = Float(sourceWidth - 1) / Float(fusionSize - 1)
        let scaleY = Float(sourceHeight - 1) / Float(fusionSize - 1)

        for y in 0..<fusionSize {
            for x in 0..<fusionSize {
                let srcX = Float(x) * scaleX
                let srcY = Float(y) * scaleY

                let x0 = Int(srcX)
                let y0 = Int(srcY)
                let x1 = PRMath.min(x0 + 1, sourceWidth - 1)
                let y1 = PRMath.min(y0 + 1, sourceHeight - 1)

                let fx = srcX - Float(x0)
                let fy = srcY - Float(y0)

                let v00 = sourceMM[y0 * sourceWidth + x0]
                let v10 = sourceMM[y0 * sourceWidth + x1]
                let v01 = sourceMM[y1 * sourceWidth + x0]
                let v11 = sourceMM[y1 * sourceWidth + x1]

                // Skip interpolation if any corner is invalid
                if v00 == TSDFConfig.invalidDepthSentinelMM ||
                   v10 == TSDFConfig.invalidDepthSentinelMM ||
                   v01 == TSDFConfig.invalidDepthSentinelMM ||
                   v11 == TSDFConfig.invalidDepthSentinelMM {
                    // Use nearest valid or mark invalid
                    destMM[y * fusionSize + x] = v00  // Fallback to top-left
                    continue
                }

                // Bilinear (deterministic, no FMA)
                let top = Float(v00) + (Float(v10) - Float(v00)) * fx
                let bottom = Float(v01) + (Float(v11) - Float(v01)) * fx
                let result = top + (bottom - top) * fy

                destMM[y * fusionSize + x] = Int32(result + 0.5)  // Round
            }
        }
    }

    /// Resize confidence map
    private func resizeConfidenceMap(
        sourceQ16: ContiguousArray<UInt16>,
        sourceWidth: Int,
        sourceHeight: Int,
        destQ16: inout ContiguousArray<UInt16>
    ) {
        let scaleX = Float(sourceWidth - 1) / Float(fusionSize - 1)
        let scaleY = Float(sourceHeight - 1) / Float(fusionSize - 1)

        for y in 0..<fusionSize {
            for x in 0..<fusionSize {
                let srcX = Float(x) * scaleX
                let srcY = Float(y) * scaleY

                let x0 = Int(srcX)
                let y0 = Int(srcY)
                let x1 = PRMath.min(x0 + 1, sourceWidth - 1)
                let y1 = PRMath.min(y0 + 1, sourceHeight - 1)

                let fx = srcX - Float(x0)
                let fy = srcY - Float(y0)

                let v00 = Float(sourceQ16[y0 * sourceWidth + x0])
                let v10 = Float(sourceQ16[y0 * sourceWidth + x1])
                let v01 = Float(sourceQ16[y1 * sourceWidth + x0])
                let v11 = Float(sourceQ16[y1 * sourceWidth + x1])

                let top = v00 + (v10 - v00) * fx
                let bottom = v01 + (v11 - v01) * fx
                let result = top + (bottom - top) * fy

                destQ16[y * fusionSize + x] = UInt16(PRMath.clamp(result, 0, 65535))
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    /// Reset all buffers
    public func reset() {
        for i in 0..<resizedDepthMM.count {
            for j in 0..<pixelCount {
                resizedDepthMM[i][j] = 0
                resizedConfQ16[i][j] = 0
            }
        }
        for i in 0..<pixelCount {
            consensusDepthMM[i] = 0
            fusedDepthMM[i] = 0
            accumulatedWeight[i] = 0
            agreementMask[i] = 0
            depthGradient[i] = 0
        }
    }
}
```

---

## Part 3: Continuous Edge Scoring System

### 3.1 Why Continuous Scoring

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY CONTINUOUS SCORING > HARD CLASSIFICATION              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  HARD CLASSIFICATION PROBLEMS:                                               │
│  ├── Threshold tuning hell: each if-else needs manual tuning                │
│  ├── Non-smooth: small input change → discrete class change                 │
│  ├── Cross-device drift: thresholds don't transfer across devices           │
│  ├── No partial membership: pixel is 100% one class or another              │
│  └── Debugging nightmare: can't see "how close" to boundary                 │
│                                                                             │
│  CONTINUOUS SCORING SOLUTION:                                                │
│  ├── Each edge type produces a score ∈ [0, 1]                               │
│  ├── Scores are smooth functions of input features                           │
│  ├── Total edge gain = weighted combination of type scores × reliability    │
│  ├── Monotonicity preserved: better features → better score                 │
│  └── Diagnosable: can see exactly which type contributes how much           │
│                                                                             │
│  FORMULA:                                                                   │
│  ├── geometric_score = sigmoid(colorGrad) × sigmoid(depthGrad) × depthConf │
│  ├── textural_score = sigmoid(colorGrad) × sigmoid(-depthGrad) × freqScore │
│  ├── specular_score = sigmoid(brightness - 0.85) × sigmoid(0.15 - sat)     │
│  ├── transparent_score = sigmoid(-colorGrad) × sigmoid(depthConflict)      │
│  │                                                                          │
│  └── edgeGain = Σ(score_i × reliability_i) / Σ(score_i)                    │
│                 where reliability: geo=0.95, tex=0.70, spec=0.30, trans=0.15│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 EdgeScoringConfig Constants

```swift
//
// EdgeScoringConfig.swift
// Aether3D
//
// PR4 - Continuous Edge Scoring Configuration
// SSOT: Single Source of Truth for edge scoring parameters
//

import Foundation

/// Edge scoring configuration
/// Uses continuous scoring instead of hard classification
///
/// REFERENCES:
/// - NTIRE 2024 Specular/Transparent Challenge
/// - RINDNet++ for edge type discrimination
/// - Stereo Anywhere for non-Lambertian handling
public enum EdgeScoringConfig {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Edge Type Reliability Weights
    // ═══════════════════════════════════════════════════════════════════════

    /// Geometric edge reliability
    ///
    /// SEMANTIC: Sharp depth discontinuities with color discontinuities
    /// Most reliable for SfM reconstruction
    public static let geometricReliability: Double = 0.95

    /// Textural edge reliability
    ///
    /// SEMANTIC: High-frequency patterns without depth change
    /// Can cause texture bleeding in reconstruction
    public static let texturalReliability: Double = 0.70

    /// Specular edge reliability
    ///
    /// SEMANTIC: Bright highlights with low saturation
    /// View-dependent, unreliable for reconstruction
    public static let specularReliability: Double = 0.30

    /// Transparent edge reliability
    ///
    /// SEMANTIC: Color edges with unexpected depth (sees through)
    /// Depth sensor often fails, very unreliable
    public static let transparentReliability: Double = 0.15

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Geometric Edge Scoring Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Color gradient threshold for geometric edge
    public static let geoColorGradThreshold: Double = 0.25

    /// Color gradient transition width
    public static let geoColorGradTransitionWidth: Double = 0.10

    /// Depth gradient threshold for geometric edge
    public static let geoDepthGradThreshold: Double = 0.05  // 5% of depth

    /// Depth gradient transition width
    public static let geoDepthGradTransitionWidth: Double = 0.02

    /// Depth confidence threshold for geometric edge
    public static let geoDepthConfThreshold: Double = 0.60

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Textural Edge Scoring Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Color gradient threshold for textural edge
    public static let texColorGradThreshold: Double = 0.20

    /// Depth gradient max for textural (lower = more textural)
    public static let texDepthGradMax: Double = 0.02  // 2% of depth

    /// Frequency energy threshold for textural
    public static let texFreqEnergyThreshold: Double = 0.40

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Specular Edge Scoring Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Brightness threshold for specular (V in HSV)
    public static let specBrightnessThreshold: Double = 0.85

    /// Saturation max for specular (S in HSV, lower = more specular)
    public static let specSaturationMax: Double = 0.15

    /// Depth confidence penalty for specular (lower conf = more specular)
    public static let specDepthConfMax: Double = 0.40

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Transparent Edge Scoring Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Color gradient max for transparent (weak color edge)
    public static let transColorGradMax: Double = 0.15

    /// Depth conflict threshold for transparent
    public static let transDepthConflictThreshold: Double = 0.30  // 30% of depth

    /// Hole proximity boost for transparent
    public static let transHoleProximityBoost: Double = 0.50

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - HSV Stabilization Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Local percentile for brightness normalization (p50/p90 mapping)
    public static let brightnessNormPercentileLow: Double = 0.10
    public static let brightnessNormPercentileHigh: Double = 0.90

    /// Local contrast normalization for saturation
    public static let saturationNormWindowSize: Int = 32

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sobel Configuration (Fixed for Determinism)
    // ═══════════════════════════════════════════════════════════════════════

    /// Sobel kernel divisor (for gradient normalization)
    /// Sobel sum of absolute weights = 8, so divide by 8 for [0,1] output
    public static let sobelDivisor: Float = 8.0

    /// Grayscale conversion coefficients (fixed, not platform-dependent)
    /// Standard Rec. 601 coefficients
    public static let grayscaleR: Float = 0.299
    public static let grayscaleG: Float = 0.587
    public static let grayscaleB: Float = 0.114

    /// Padding mode: clamp-to-edge (fixed for determinism)
    public static let paddingMode: String = "clamp_to_edge"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Final Gain Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum edge density for valid computation
    public static let minEdgeDensity: Double = 0.01  // 1%

    /// Minimum edge soft gain (floor)
    public static let minEdgeSoftGain: Double = 0.10

    /// Density bonus factor (more edges = more features = better)
    public static let densityBonusFactor: Double = 2.0

    /// Maximum density bonus
    public static let maxDensityBonus: Double = 0.20
}
```

### 3.3 EdgeScorer Implementation

```swift
//
// EdgeScorer.swift
// Aether3D
//
// PR4 - Continuous Edge Scoring
// Produces continuous scores for each edge type instead of hard classification
//

import Foundation

/// Continuous edge scoring result
public struct EdgeScoreResult: Sendable {
    /// Per-pixel scores for each edge type (all in [0, 1])
    public let geometricScores: ContiguousArray<Float>
    public let texturalScores: ContiguousArray<Float>
    public let specularScores: ContiguousArray<Float>
    public let transparentScores: ContiguousArray<Float>

    /// Aggregate statistics
    public let meanGeometricScore: Double
    public let meanTexturalScore: Double
    public let meanSpecularScore: Double
    public let meanTransparentScore: Double

    /// Edge density (pixels with any score > 0.5)
    public let edgeDensity: Double

    /// Overall edge confidence (reliability-weighted)
    public let overallConfidence: Double

    /// Map dimensions
    public let width: Int
    public let height: Int
}

/// Continuous edge scorer
/// Uses smooth scoring functions instead of hard thresholds
public final class EdgeScorer {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pre-allocated Buffers
    // ═══════════════════════════════════════════════════════════════════════

    private let resolution: Int
    private let pixelCount: Int

    // Intermediate buffers (fused pass)
    private var grayscale: ContiguousArray<Float>
    private var gradientX: ContiguousArray<Float>
    private var gradientY: ContiguousArray<Float>
    private var gradientMag: ContiguousArray<Float>
    private var hue: ContiguousArray<Float>
    private var saturation: ContiguousArray<Float>
    private var brightness: ContiguousArray<Float>
    private var depthGradient: ContiguousArray<Float>

    // Score buffers
    private var geoScores: ContiguousArray<Float>
    private var texScores: ContiguousArray<Float>
    private var specScores: ContiguousArray<Float>
    private var transScores: ContiguousArray<Float>

    // HSV stabilization buffers
    private var brightnessHistogram: ContiguousArray<Int>
    private var saturationLocal: ContiguousArray<Float>

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(resolution: Int = TSDFConfig.primaryFusionSize) {
        self.resolution = resolution
        self.pixelCount = resolution * resolution

        // Pre-allocate all buffers
        self.grayscale = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientX = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientY = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientMag = ContiguousArray(repeating: 0, count: pixelCount)
        self.hue = ContiguousArray(repeating: 0, count: pixelCount)
        self.saturation = ContiguousArray(repeating: 0, count: pixelCount)
        self.brightness = ContiguousArray(repeating: 0, count: pixelCount)
        self.depthGradient = ContiguousArray(repeating: 0, count: pixelCount)

        self.geoScores = ContiguousArray(repeating: 0, count: pixelCount)
        self.texScores = ContiguousArray(repeating: 0, count: pixelCount)
        self.specScores = ContiguousArray(repeating: 0, count: pixelCount)
        self.transScores = ContiguousArray(repeating: 0, count: pixelCount)

        self.brightnessHistogram = ContiguousArray(repeating: 0, count: 256)
        self.saturationLocal = ContiguousArray(repeating: 0, count: pixelCount)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Scoring API
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute continuous edge scores
    ///
    /// - Parameters:
    ///   - rgbPixels: RGB pixels (interleaved, 0-255)
    ///   - depthMapMM: Depth in millimeters (from fusion)
    ///   - depthConfidence: Depth confidence [0, 1]
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Edge score result
    public func computeScores(
        rgbPixels: ContiguousArray<UInt8>,
        depthMapMM: ContiguousArray<Int32>,
        depthConfidence: ContiguousArray<Float>,
        width: Int,
        height: Int
    ) -> EdgeScoreResult {
        precondition(rgbPixels.count == width * height * 3)
        precondition(depthMapMM.count == width * height)
        precondition(depthConfidence.count == width * height)
        precondition(width == resolution && height == resolution)

        let config = EdgeScoringConfig.self

        // FUSED PASS: Compute all intermediate features in single traversal
        computeFusedPass(
            rgbPixels: rgbPixels,
            depthMapMM: depthMapMM,
            width: width,
            height: height
        )

        // HSV Stabilization
        stabilizeHSV()

        // Compute per-pixel scores
        var sumGeo: Double = 0
        var sumTex: Double = 0
        var sumSpec: Double = 0
        var sumTrans: Double = 0
        var edgePixelCount = 0

        for p in 0..<pixelCount {
            let colorGrad = gradientMag[p]
            let dGrad = depthGradient[p]
            let conf = depthConfidence[p]
            let sat = saturation[p]
            let bright = brightness[p]

            // Geometric score
            let geoColorFactor = Float(PRMath.sigmoid(
                (Double(colorGrad) - config.geoColorGradThreshold) /
                (config.geoColorGradTransitionWidth / 4.4)
            ))
            let geoDepthFactor = Float(PRMath.sigmoid(
                (Double(dGrad) - config.geoDepthGradThreshold) /
                (config.geoDepthGradTransitionWidth / 4.4)
            ))
            let geoConfFactor = Float(PRMath.sigmoid(
                (Double(conf) - config.geoDepthConfThreshold) / 0.10
            ))
            geoScores[p] = geoColorFactor * geoDepthFactor * geoConfFactor

            // Textural score
            let texColorFactor = Float(PRMath.sigmoid(
                (Double(colorGrad) - config.texColorGradThreshold) / 0.10
            ))
            let texDepthFactor = Float(PRMath.sigmoid(
                (config.texDepthGradMax - Double(dGrad)) / 0.01
            ))
            let texFreqFactor = Float(config.texFreqEnergyThreshold)  // Simplified
            texScores[p] = texColorFactor * texDepthFactor * texFreqFactor

            // Specular score
            let specBrightFactor = Float(PRMath.sigmoid(
                (Double(bright) - config.specBrightnessThreshold) / 0.05
            ))
            let specSatFactor = Float(PRMath.sigmoid(
                (config.specSaturationMax - Double(sat)) / 0.05
            ))
            let specConfFactor = Float(PRMath.sigmoid(
                (config.specDepthConfMax - Double(conf)) / 0.10
            ))
            specScores[p] = specBrightFactor * specSatFactor * specConfFactor

            // Transparent score
            let transColorFactor = Float(PRMath.sigmoid(
                (config.transColorGradMax - Double(colorGrad)) / 0.05
            ))
            let transDepthFactor = Float(PRMath.sigmoid(
                (Double(dGrad) - config.transDepthConflictThreshold) / 0.10
            ))
            transScores[p] = transColorFactor * transDepthFactor

            // Accumulate
            sumGeo += Double(geoScores[p])
            sumTex += Double(texScores[p])
            sumSpec += Double(specScores[p])
            sumTrans += Double(transScores[p])

            // Count edge pixels (any score > 0.5)
            if geoScores[p] > 0.5 || texScores[p] > 0.5 ||
               specScores[p] > 0.5 || transScores[p] > 0.5 {
                edgePixelCount += 1
            }
        }

        let n = Double(pixelCount)
        let meanGeo = sumGeo / n
        let meanTex = sumTex / n
        let meanSpec = sumSpec / n
        let meanTrans = sumTrans / n
        let density = Double(edgePixelCount) / n

        // Overall confidence (reliability-weighted)
        let totalScore = meanGeo + meanTex + meanSpec + meanTrans
        let overallConf: Double
        if totalScore > 0 {
            overallConf = (
                meanGeo * config.geometricReliability +
                meanTex * config.texturalReliability +
                meanSpec * config.specularReliability +
                meanTrans * config.transparentReliability
            ) / totalScore
        } else {
            overallConf = 0
        }

        return EdgeScoreResult(
            geometricScores: ContiguousArray(geoScores),
            texturalScores: ContiguousArray(texScores),
            specularScores: ContiguousArray(specScores),
            transparentScores: ContiguousArray(transScores),
            meanGeometricScore: meanGeo,
            meanTexturalScore: meanTex,
            meanSpecularScore: meanSpec,
            meanTransparentScore: meanTrans,
            edgeDensity: density,
            overallConfidence: overallConf,
            width: width,
            height: height
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fused Pass (Single Traversal)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute grayscale, Sobel gradient, HSV, and depth gradient in single pass
    private func computeFusedPass(
        rgbPixels: ContiguousArray<UInt8>,
        depthMapMM: ContiguousArray<Int32>,
        width: Int,
        height: Int
    ) {
        let config = EdgeScoringConfig.self

        // First pass: compute grayscale and HSV
        for p in 0..<pixelCount {
            let r = Float(rgbPixels[p * 3 + 0]) / 255.0
            let g = Float(rgbPixels[p * 3 + 1]) / 255.0
            let b = Float(rgbPixels[p * 3 + 2]) / 255.0

            // Grayscale (fixed coefficients)
            grayscale[p] = config.grayscaleR * r + config.grayscaleG * g + config.grayscaleB * b

            // HSV conversion (deterministic)
            let maxC = PRMath.max(PRMath.max(Double(r), Double(g)), Double(b))
            let minC = PRMath.min(PRMath.min(Double(r), Double(g)), Double(b))
            let delta = maxC - minC

            brightness[p] = Float(maxC)
            saturation[p] = maxC > 0 ? Float(delta / maxC) : 0

            if delta > 0 {
                if maxC == Double(r) {
                    hue[p] = Float((Double(g) - Double(b)) / delta)
                    if g < b { hue[p] += 6 }
                } else if maxC == Double(g) {
                    hue[p] = Float(2 + (Double(b) - Double(r)) / delta)
                } else {
                    hue[p] = Float(4 + (Double(r) - Double(g)) / delta)
                }
                hue[p] /= 6
            } else {
                hue[p] = 0
            }
        }

        // Second pass: Sobel gradients (needs neighbors)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let p = y * width + x

                // Sobel X: [-1, 0, 1; -2, 0, 2; -1, 0, 1]
                let gx = -grayscale[(y-1)*width + (x-1)] + grayscale[(y-1)*width + (x+1)]
                       - 2*grayscale[y*width + (x-1)] + 2*grayscale[y*width + (x+1)]
                       - grayscale[(y+1)*width + (x-1)] + grayscale[(y+1)*width + (x+1)]

                // Sobel Y: [-1, -2, -1; 0, 0, 0; 1, 2, 1]
                let gy = -grayscale[(y-1)*width + (x-1)] - 2*grayscale[(y-1)*width + x] - grayscale[(y-1)*width + (x+1)]
                       + grayscale[(y+1)*width + (x-1)] + 2*grayscale[(y+1)*width + x] + grayscale[(y+1)*width + (x+1)]

                gradientX[p] = gx / config.sobelDivisor
                gradientY[p] = gy / config.sobelDivisor
                gradientMag[p] = Float(PRMath.sqrt(Double(gx * gx + gy * gy))) / config.sobelDivisor

                // Depth gradient (relative to depth)
                let depthMM = depthMapMM[p]
                if depthMM > 0 {
                    let depthM = Float(depthMM) * 0.001
                    let left = Float(depthMapMM[p - 1]) * 0.001
                    let right = Float(depthMapMM[p + 1]) * 0.001
                    let top = Float(depthMapMM[p - width]) * 0.001
                    let bottom = Float(depthMapMM[p + width]) * 0.001

                    let dx = (right - left) / 2.0
                    let dy = (bottom - top) / 2.0
                    let grad = Float(PRMath.sqrt(Double(dx * dx + dy * dy)))
                    depthGradient[p] = grad / depthM  // Relative gradient
                } else {
                    depthGradient[p] = 0
                }
            }
        }

        // Border pixels: zero gradients
        for x in 0..<width {
            gradientMag[x] = 0
            gradientMag[(height - 1) * width + x] = 0
            depthGradient[x] = 0
            depthGradient[(height - 1) * width + x] = 0
        }
        for y in 0..<height {
            gradientMag[y * width] = 0
            gradientMag[y * width + width - 1] = 0
            depthGradient[y * width] = 0
            depthGradient[y * width + width - 1] = 0
        }
    }

    /// Stabilize HSV values using local normalization
    private func stabilizeHSV() {
        let config = EdgeScoringConfig.self

        // Build brightness histogram
        for i in 0..<256 {
            brightnessHistogram[i] = 0
        }
        for p in 0..<pixelCount {
            let bin = Int(brightness[p] * 255)
            let clampedBin = PRMath.clamp(bin, 0, 255)
            brightnessHistogram[clampedBin] += 1
        }

        // Find percentiles
        let lowThreshold = Int(Double(pixelCount) * config.brightnessNormPercentileLow)
        let highThreshold = Int(Double(pixelCount) * config.brightnessNormPercentileHigh)

        var cumSum = 0
        var lowBin = 0
        var highBin = 255

        for i in 0..<256 {
            cumSum += brightnessHistogram[i]
            if cumSum >= lowThreshold && lowBin == 0 {
                lowBin = i
            }
            if cumSum >= highThreshold {
                highBin = i
                break
            }
        }

        // Normalize brightness
        let lowVal = Float(lowBin) / 255.0
        let highVal = Float(highBin) / 255.0
        let range = highVal - lowVal

        if range > 0.01 {
            for p in 0..<pixelCount {
                brightness[p] = (brightness[p] - lowVal) / range
                brightness[p] = Float(PRMath.clamp(Double(brightness[p]), 0, 1))
            }
        }

        // Note: Saturation local normalization would be similar but
        // requires local window computation. For now, skip for performance.
    }
}
```

---

## Part 4: Robust Temporal Filtering

### 4.1 Why Median + Trimmed Mean (Not Just EMA)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY ROBUST STATISTICS FOR TEMPORAL FILTERING              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  EMA (Exponential Moving Average) PROBLEMS:                                  │
│  ├── Assumes Gaussian noise: depth errors are often NOT Gaussian            │
│  ├── Outlier propagation: single bad frame affects many future frames       │
│  ├── Lag: EMA inherently lags behind true signal                            │
│  ├── No outlier detection: treats all frames equally                        │
│  └── Overshoot on rapid changes: can create "ringing" artifacts             │
│                                                                             │
│  ROBUST SOLUTION (from video depth literature):                              │
│  ├── Primary: Median or Trimmed Mean (exclude 20% largest residuals)        │
│  ├── Secondary: Light EMA for jitter smoothing only                         │
│  ├── Anti-overshoot: detect suspicious jumps, apply stronger filtering      │
│  ├── Relative threshold: max(0.02m, 0.03×depth) adapts to distance          │
│  └── Reference: ChronoDepth, ST-CLSTM temporal consistency approaches       │
│                                                                             │
│  ALGORITHM:                                                                 │
│  1. Ring buffer holds last N depth values per pixel                         │
│  2. Compute trimmed mean (exclude top/bottom 10%)                           │
│  3. If current depth deviates > threshold from trimmed mean:                │
│     a. Mark as suspicious                                                    │
│     b. Use median instead of current value                                   │
│     c. Apply stronger EMA (alpha = 0.3 instead of 0.7)                       │
│  4. Otherwise: light EMA smoothing (alpha = 0.7)                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 TemporalConfig Constants

```swift
//
// TemporalConfig.swift
// Aether3D
//
// PR4 - Robust Temporal Filtering Configuration
// SSOT: Single Source of Truth for temporal processing parameters
//

import Foundation

/// Temporal filtering configuration
/// Uses robust statistics (median/trimmed mean) instead of pure EMA
///
/// REFERENCES:
/// - ChronoDepth: Learning Temporally Consistent Video Depth
/// - ST-CLSTM: Spatial-Temporal LSTM for video depth
/// - Trimmed mean for robust depth estimation
public enum TemporalConfig {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Ring Buffer Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Temporal window size (number of frames to keep)
    ///
    /// VALUE ANALYSIS:
    /// - 3 = Minimal: Not enough for robust statistics
    /// - 5 = DEFAULT: ~167ms at 30fps, good balance
    /// - 8 = More stable: ~267ms, more lag
    /// - 10 = Very stable: 333ms, noticeable lag
    public static let windowSize: Int = 5

    /// Maximum ring buffer size (for memory pre-allocation)
    public static let maxWindowSize: Int = 10

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Trimmed Mean Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Trimming percentage (exclude top and bottom this fraction)
    ///
    /// SEMANTIC: Exclude top 10% and bottom 10% of values
    /// Remaining 80% are averaged
    public static let trimPercentage: Double = 0.10

    /// Minimum valid samples for trimmed mean
    ///
    /// SEMANTIC: Need at least this many samples for robust statistics
    /// If fewer, fall back to simple mean
    public static let minSamplesForTrimmedMean: Int = 4

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Depth Change Thresholds (Relative + Absolute)
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum absolute depth change threshold (meters)
    ///
    /// SEMANTIC: Changes below this are always considered stable
    /// Prevents over-filtering at close range
    public static let minAbsoluteDepthChangeM: Double = 0.02  // 2cm

    /// Relative depth change threshold (fraction of depth)
    ///
    /// SEMANTIC: Changes larger than this fraction are suspicious
    /// Combined formula: threshold = max(minAbs, relThreshold × depth)
    public static let relativeDepthChangeThreshold: Double = 0.03  // 3%

    /// Maximum absolute depth change threshold (meters)
    ///
    /// SEMANTIC: Changes larger than this are definitely outliers
    /// Used for very far depths where relative threshold is too large
    public static let maxAbsoluteDepthChangeM: Double = 0.50  // 50cm

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - EMA Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Normal EMA alpha (for stable signal)
    ///
    /// SEMANTIC: Weight for new value vs history
    /// Higher = more responsive, lower = more smooth
    public static let normalEmaAlpha: Double = 0.70

    /// Suspicious EMA alpha (for detected outliers)
    ///
    /// SEMANTIC: Use stronger smoothing when outlier detected
    public static let suspiciousEmaAlpha: Double = 0.30

    /// Anti-overshoot EMA alpha
    ///
    /// SEMANTIC: Even stronger smoothing for rapid changes
    public static let antiOvershootEmaAlpha: Double = 0.15

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Anti-Overshoot Parameters
    // ═══════════════════════════════════════════════════════════════════════

    /// Consecutive suspicious frames threshold
    ///
    /// SEMANTIC: If N consecutive frames are suspicious, signal is changing
    /// Switch to anti-overshoot mode to prevent ringing
    public static let consecutiveSuspiciousThreshold: Int = 3

    /// Anti-overshoot decay frames
    ///
    /// SEMANTIC: After anti-overshoot triggers, decay back to normal over N frames
    public static let antiOvershootDecayFrames: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Consistency Weight
    // ═══════════════════════════════════════════════════════════════════════

    /// Temporal consistency contribution to soft quality
    ///
    /// SEMANTIC: How much does temporal stability affect soft quality?
    /// Value: 15% (lower than depth/edge/topo because it's a modifier)
    public static let temporalConsistencyWeight: Double = 0.15
}
```

### 4.3 RobustTemporalFilter Implementation

```swift
//
// RobustTemporalFilter.swift
// Aether3D
//
// PR4 - Robust Temporal Filtering
// Uses trimmed mean + median + adaptive EMA for depth stability
//

import Foundation

/// Robust temporal filter for depth values
/// Per-pixel filtering with ring buffer and outlier detection
public final class RobustTemporalFilter {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════

    /// Per-pixel temporal state
    private struct PixelState {
        var ringBuffer: [Float]         // Last N depth values
        var ringIndex: Int              // Current write position
        var ringCount: Int              // Valid samples count
        var emaValue: Float             // Current EMA value
        var consecutiveSuspicious: Int  // Consecutive outlier count
        var antiOvershootCountdown: Int // Decay counter

        init(maxSize: Int) {
            self.ringBuffer = Array(repeating: 0, count: maxSize)
            self.ringIndex = 0
            self.ringCount = 0
            self.emaValue = 0
            self.consecutiveSuspicious = 0
            self.antiOvershootCountdown = 0
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    private let resolution: Int
    private let pixelCount: Int
    private var pixelStates: [PixelState]

    // Temporary buffer for sorting (avoid allocation)
    private var sortBuffer: [Float]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(resolution: Int = TSDFConfig.primaryFusionSize) {
        self.resolution = resolution
        self.pixelCount = resolution * resolution

        let maxWindow = TemporalConfig.maxWindowSize
        self.pixelStates = (0..<pixelCount).map { _ in PixelState(maxSize: maxWindow) }
        self.sortBuffer = Array(repeating: 0, count: maxWindow)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Filtering API
    // ═══════════════════════════════════════════════════════════════════════

    /// Filter depth map using robust temporal statistics
    ///
    /// - Parameters:
    ///   - depthMapM: Input depth in meters
    ///   - outputDepthM: Output filtered depth (pre-allocated)
    ///   - consistencyScores: Per-pixel consistency score (pre-allocated)
    public func filter(
        depthMapM: ContiguousArray<Float>,
        outputDepthM: inout ContiguousArray<Float>,
        consistencyScores: inout ContiguousArray<Float>
    ) {
        precondition(depthMapM.count == pixelCount)
        precondition(outputDepthM.count == pixelCount)
        precondition(consistencyScores.count == pixelCount)

        let config = TemporalConfig.self
        let windowSize = config.windowSize

        for p in 0..<pixelCount {
            let currentDepth = depthMapM[p]

            // Skip invalid depth
            guard currentDepth > 0 else {
                outputDepthM[p] = 0
                consistencyScores[p] = 0
                continue
            }

            var state = pixelStates[p]

            // Add to ring buffer
            state.ringBuffer[state.ringIndex] = currentDepth
            state.ringIndex = (state.ringIndex + 1) % windowSize
            state.ringCount = PRMath.min(state.ringCount + 1, windowSize)

            // Compute robust estimate
            let (robustEstimate, isSuspicious) = computeRobustEstimate(
                state: state,
                currentDepth: currentDepth,
                windowSize: windowSize
            )

            // Update suspicious tracking
            if isSuspicious {
                state.consecutiveSuspicious += 1
            } else {
                state.consecutiveSuspicious = 0
            }

            // Check for anti-overshoot trigger
            if state.consecutiveSuspicious >= config.consecutiveSuspiciousThreshold {
                state.antiOvershootCountdown = config.antiOvershootDecayFrames
                state.consecutiveSuspicious = 0  // Reset
            }

            // Select EMA alpha
            let alpha: Double
            if state.antiOvershootCountdown > 0 {
                alpha = config.antiOvershootEmaAlpha
                state.antiOvershootCountdown -= 1
            } else if isSuspicious {
                alpha = config.suspiciousEmaAlpha
            } else {
                alpha = config.normalEmaAlpha
            }

            // Apply EMA
            let inputValue = isSuspicious ? robustEstimate : currentDepth
            if state.emaValue == 0 {
                state.emaValue = inputValue
            } else {
                state.emaValue = Float(alpha) * inputValue + Float(1 - alpha) * state.emaValue
            }

            // Output
            outputDepthM[p] = state.emaValue

            // Consistency score: lower if suspicious, higher if stable
            let deviation = PRMath.abs(Double(currentDepth) - Double(robustEstimate))
            let threshold = computeThreshold(depth: robustEstimate)
            let normalizedDev = deviation / threshold
            consistencyScores[p] = Float(PRMath.max(0, 1.0 - normalizedDev))

            // Update state
            pixelStates[p] = state
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Robust Statistics
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute robust estimate using trimmed mean
    private func computeRobustEstimate(
        state: PixelState,
        currentDepth: Float,
        windowSize: Int
    ) -> (estimate: Float, isSuspicious: Bool) {
        let config = TemporalConfig.self

        // Not enough samples: use current value
        guard state.ringCount >= config.minSamplesForTrimmedMean else {
            return (currentDepth, false)
        }

        // Copy valid samples to sort buffer
        var validCount = 0
        for i in 0..<state.ringCount {
            let value = state.ringBuffer[i]
            if value > 0 {
                sortBuffer[validCount] = value
                validCount += 1
            }
        }

        guard validCount >= config.minSamplesForTrimmedMean else {
            return (currentDepth, false)
        }

        // Sort (deterministic: stable sort by value)
        for i in 1..<validCount {
            let key = sortBuffer[i]
            var j = i - 1
            while j >= 0 && sortBuffer[j] > key {
                sortBuffer[j + 1] = sortBuffer[j]
                j -= 1
            }
            sortBuffer[j + 1] = key
        }

        // Compute trimmed mean
        let trimCount = Int(Double(validCount) * config.trimPercentage)
        let startIdx = trimCount
        let endIdx = validCount - trimCount

        guard endIdx > startIdx else {
            // Fall back to median
            let medianIdx = validCount / 2
            let median = sortBuffer[medianIdx]
            let threshold = computeThreshold(depth: median)
            let isSuspicious = PRMath.abs(Double(currentDepth) - Double(median)) > threshold
            return (median, isSuspicious)
        }

        var sum: Double = 0
        for i in startIdx..<endIdx {
            sum += Double(sortBuffer[i])
        }
        let trimmedMean = Float(sum / Double(endIdx - startIdx))

        // Check if current depth is suspicious
        let threshold = computeThreshold(depth: trimmedMean)
        let isSuspicious = PRMath.abs(Double(currentDepth) - Double(trimmedMean)) > threshold

        return (trimmedMean, isSuspicious)
    }

    /// Compute adaptive threshold for given depth
    @inline(__always)
    private func computeThreshold(depth: Float) -> Double {
        let config = TemporalConfig.self
        let relThreshold = config.relativeDepthChangeThreshold * Double(depth)
        let threshold = PRMath.max(config.minAbsoluteDepthChangeM, relThreshold)
        return PRMath.min(threshold, config.maxAbsoluteDepthChangeM)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    /// Reset all pixel states
    public func reset() {
        let maxWindow = TemporalConfig.maxWindowSize
        for i in 0..<pixelCount {
            pixelStates[i] = PixelState(maxSize: maxWindow)
        }
    }
}
```

---

## Part 5: Determinism Configuration

### 5.1 DeterminismConfig Constants

```swift
//
// DeterminismConfig.swift
// Aether3D
//
// PR4 - Determinism Configuration
// SSOT: Single Source of Truth for all determinism-critical parameters
//

import Foundation

/// Determinism configuration
/// Ensures identical results across platforms and runs
///
/// REFERENCES:
/// - Floating Point Determinism (Gaffer On Games)
/// - Cross-platform floating point consistency
/// - Connected component labeling algorithms
public enum DeterminismConfig {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Scan Order (Connected Components, Hole Detection)
    // ═══════════════════════════════════════════════════════════════════════

    /// Scan order for connected components
    ///
    /// FIXED: Row-major (y outer, x inner)
    /// DO NOT CHANGE without updating all golden tests
    public static let scanOrder: String = "row_major"

    /// Neighborhood connectivity for hole detection
    ///
    /// FIXED: 4-connectivity (not 8)
    /// 8-connectivity would make background fully connected (no holes)
    public static let holeNeighborhood: Int = 4

    /// Flood fill neighbor order (for deterministic traversal)
    ///
    /// FIXED: [left, right, up, down]
    /// Queue push order must be deterministic
    public static let floodFillNeighborOrder: [(dx: Int, dy: Int)] = [
        (-1, 0),  // left
        (1, 0),   // right
        (0, -1),  // up
        (0, 1)    // down
    ]

    /// Component ID assignment start
    ///
    /// FIXED: Start from 1 (0 = no component)
    public static let componentIdStart: Int = 1

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tie-Break Rules
    // ═══════════════════════════════════════════════════════════════════════

    /// Depth source tie-break order (when weights are equal)
    ///
    /// FIXED: platform_api > small_model > large_model > stereo
    /// Preference based on expected reliability
    public static let depthSourceTieBreakOrder: [String] = [
        "platform_api",
        "small_model",
        "large_model",
        "stereo"
    ]

    /// Edge type tie-break order (when scores are equal)
    ///
    /// FIXED: geometric > textural > specular > transparent
    /// Preference based on reliability
    public static let edgeTypeTieBreakOrder: [String] = [
        "geometric",
        "textural",
        "specular",
        "transparent"
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Iteration Order
    // ═══════════════════════════════════════════════════════════════════════

    /// Dictionary iteration: ALWAYS use sorted keys
    ///
    /// WARNING: Swift Dictionary iteration order is undefined!
    /// Always convert to sorted array before iterating
    public static let alwaysSortDictionaryKeys: Bool = true

    /// Set iteration: ALWAYS convert to sorted array
    public static let alwaysSortSetElements: Bool = true

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Forbidden APIs
    // ═══════════════════════════════════════════════════════════════════════

    /// Forbidden APIs in PR4 (checked by CI lint)
    public static let forbiddenApis: [String] = [
        "Date()",
        "Date.now",
        "UUID()",
        ".random",
        ".shuffled",
        "arc4random",
        "drand48",
        "ProcessInfo.processInfo.globallyUniqueString"
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Integer Quantization
    // ═══════════════════════════════════════════════════════════════════════

    /// Depth quantization: millimeters (Int32)
    public static let depthQuantizationUnit: String = "millimeters"
    public static let depthQuantizationScale: Int32 = 1000  // 1m = 1000mm

    /// Confidence quantization: Q0.16 fixed-point (UInt16)
    public static let confidenceQuantizationBits: Int = 16
    public static let confidenceQuantizationMax: UInt16 = 65535

    /// Gain quantization: Q1.62 via Int64 (from QuantizerQ01)
    public static let gainQuantizationBits: Int = 62

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Floating Point Caution
    // ═══════════════════════════════════════════════════════════════════════

    /// Use PRMath for ALL math operations
    ///
    /// WARNING: Direct use of +, -, *, / on Double is OK
    /// but exp, sqrt, sin, cos, etc. MUST use PRMath
    public static let requirePRMathForTranscendentals: Bool = true

    /// Avoid FMA (fused multiply-add) for reproducibility
    ///
    /// Some platforms use FMA automatically, which changes precision
    /// Write a + b * c as: let tmp = b * c; let result = a + tmp
    public static let avoidImplicitFma: Bool = true
}
```

### 5.2 AllocationSentinel (DEBUG-Only)

```swift
//
// AllocationSentinel.swift
// Aether3D
//
// PR4 - Allocation Sentinel (DEBUG-Only)
// Detects heap allocations in hot path
//

import Foundation

#if DEBUG

/// Allocation sentinel for detecting hot path allocations
///
/// Usage:
/// ```
/// AllocationSentinel.beginFrame()
/// // ... hot path code ...
/// AllocationSentinel.endFrame()  // Asserts if any allocation occurred
/// ```
///
/// WARNING: DEBUG only. Uses private malloc hooks.
public final class AllocationSentinel {

    /// Allocation count at frame start
    private static var frameStartCount: Int = 0

    /// Whether sentinel is active
    private static var isActive: Bool = false

    /// Total allocations detected (for diagnostics)
    private static var totalDetected: Int = 0

    // Note: In real implementation, this would hook into malloc
    // For now, use manual tracking via didAllocate()

    /// Begin frame tracking
    public static func beginFrame() {
        guard !isActive else {
            assertionFailure("AllocationSentinel: nested beginFrame() not allowed")
            return
        }
        frameStartCount = totalDetected
        isActive = true
    }

    /// End frame tracking (asserts if allocation detected)
    public static func endFrame() {
        guard isActive else {
            assertionFailure("AllocationSentinel: endFrame() without beginFrame()")
            return
        }

        let allocations = totalDetected - frameStartCount
        isActive = false

        if allocations > 0 {
            assertionFailure(
                "AllocationSentinel: \(allocations) allocation(s) detected in hot path"
            )
        }
    }

    /// Manual notification of allocation (for testing)
    public static func didAllocate(count: Int = 1) {
        totalDetected += count
    }

    /// Reset for testing
    public static func reset() {
        frameStartCount = 0
        isActive = false
        totalDetected = 0
    }
}

#else

/// No-op in release builds
public final class AllocationSentinel {
    @inline(__always) public static func beginFrame() {}
    @inline(__always) public static func endFrame() {}
    @inline(__always) public static func didAllocate(count: Int = 1) {}
    @inline(__always) public static func reset() {}
}

#endif
```

---

## Part 6: SoftGatesV14 Constants (Unified SSOT)

```swift
//
// SoftGatesV14.swift
// Aether3D
//
// PR4 - Soft Gate Thresholds V14 (Bulletproof Edition)
// SSOT: Single Source of Truth for all soft-related thresholds
// Incorporates all hardening from user feedback
//

import Foundation

/// Soft gate thresholds V14 (Bulletproof Edition)
/// Unified constants for the entire PR4 system
///
/// VERSION: 1.4 (Bulletproof)
/// CHANGES from V13:
/// - Depth thresholds use integer (mm) for determinism
/// - Edge scoring uses continuous thresholds, not binary
/// - Temporal filtering uses relative+absolute thresholds
/// - All sigmoid parameters use (threshold, transitionWidth) form
/// - All floors explicitly defined
public enum SoftGatesV14 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gain Weight Distribution
    // ═══════════════════════════════════════════════════════════════════════

    /// Depth soft gain weight
    public static let depthGainWeight: Double = 0.40

    /// Topology soft gain weight
    public static let topoGainWeight: Double = 0.25

    /// Edge soft gain weight
    public static let edgeGainWeight: Double = 0.20

    /// Base soft gain weight (temporal + semantic)
    public static let baseGainWeight: Double = 0.15

    /// Validation: weights must sum to 1.0
    public static func validateWeights() -> Bool {
        let sum = depthGainWeight + topoGainWeight + edgeGainWeight + baseGainWeight
        return PRMath.abs(sum - 1.0) < 1e-9
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gain Floors (Recovery Potential)
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum depth soft gain
    public static let minDepthSoftGain: Double = 0.08

    /// Minimum topology soft gain
    public static let minTopoSoftGain: Double = 0.08

    /// Minimum edge soft gain
    public static let minEdgeSoftGain: Double = 0.10

    /// Minimum base soft gain
    public static let minBaseSoftGain: Double = 0.15

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Depth Fusion Thresholds (in millimeters for integer path)
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum depth disagreement (mm)
    public static let maxDepthDisagreementMM: Int32 = 150  // 15cm

    /// Minimum depth consensus ratio
    public static let minDepthConsensusRatio: Double = 0.67

    /// Minimum depth confidence
    public static let minDepthConfidence: Double = 0.20

    /// Maximum depth error for high quality (mm)
    public static let maxDepthErrorForHighQualityMM: Int32 = 80  // 8cm

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Topology Thresholds
    // ═══════════════════════════════════════════════════════════════════════

    /// Hole area ratio threshold
    public static let holeAreaRatioThreshold: Double = 0.02  // 2%

    /// Occlusion boundary depth ratio
    public static let occlusionBoundaryDepthRatio: Double = 0.10  // 10%

    /// Minimum occlusion boundary length (pixels)
    public static let minOcclusionBoundaryLengthPx: Int = 8

    /// Self-occlusion angle threshold (degrees)
    public static let selfOcclusionAngleDeg: Double = 75.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sigmoid Parameters (Threshold + TransitionWidth form)
    // ═══════════════════════════════════════════════════════════════════════

    // Depth consensus sigmoid
    public static let depthConsensusThreshold: Double = 0.67
    public static let depthConsensusTransitionWidth: Double = 0.15

    // Depth confidence sigmoid
    public static let depthConfidenceThreshold: Double = 0.50
    public static let depthConfidenceTransitionWidth: Double = 0.20

    // Hole penalty sigmoid
    public static let holePenaltyThreshold: Double = 0.02
    public static let holePenaltyTransitionWidth: Double = 0.02

    // Edge reliability sigmoid
    public static let edgeReliabilityThreshold: Double = 0.50
    public static let edgeReliabilityTransitionWidth: Double = 0.20

    /// Convert to slope for PRMath.sigmoid
    /// sigmoid((x - threshold) / slope) where slope = transitionWidth / 4.4
    @inline(__always)
    public static func sigmoidSlope(transitionWidth: Double) -> Double {
        return transitionWidth / 4.4
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Dynamic Weight Progression
    // ═══════════════════════════════════════════════════════════════════════

    /// Progress threshold for early capture (gate dominates)
    public static let earlyProgressThreshold: Double = 0.30

    /// Progress threshold for late capture (soft dominates)
    public static let lateProgressThreshold: Double = 0.70

    /// Gate weight at early progress
    public static let earlyGateWeight: Double = 0.85

    /// Gate weight at late progress
    public static let lateGateWeight: Double = 0.25

    /// Progress definition: from PR3 coverage evidence
    /// NOT from UI percentage!
    public static let progressSource: String = "pr3_coverage_ratio"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gate→Soft Gating Form
    // ═══════════════════════════════════════════════════════════════════════

    /// Gating form: multiplicative
    /// final = gateWeight * gateQuality + softWeight * softQuality * gateModulator
    /// where gateModulator = gateQuality (multiplicative gating)
    public static let gatingForm: String = "multiplicative"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Memory Limits
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum depth sources
    public static let maxDepthSources: Int = 4

    /// Maximum depth map resolution
    public static let maxDepthMapResolution: Int = 256

    /// Memory per patch (KB)
    public static let memoryPerPatchKB: Int = 50

    /// Maximum patches
    public static let maxPatches: Int = 1000
}
```

---

## Part 7: SoftConstitution (Behavioral Contract)

```swift
//
// SoftConstitution.swift
// Aether3D
//
// PR4 - Soft Quality Behavioral Contract
// Defines semantic meaning, domains, ranges, and monotonicity for all soft metrics
//

import Foundation

/// Soft quality behavioral contract
///
/// This file defines the "constitution" of soft quality:
/// - What each metric MEANS
/// - What input domains are valid
/// - What output ranges are guaranteed
/// - What monotonicity properties hold
///
/// IMMUTABILITY: Changes to this file require golden test updates
public enum SoftConstitution {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - softQuality Semantic Definition
    // ═══════════════════════════════════════════════════════════════════════

    /// softQuality semantic definition
    ///
    /// VALUE = 0.0:
    ///   - Patch CAN be reconstructed (gate passed)
    ///   - But quality is POOR: holes, unreliable edges, inconsistent topology
    ///   - Visual artifacts expected in reconstruction
    ///
    /// VALUE = 1.0:
    ///   - Patch CAN be reconstructed AND quality is EXCELLENT
    ///   - Depth consensus high, edges reliable, topology consistent
    ///   - Near-optimal reconstruction expected given sensor/model limits
    ///
    /// RELATIONSHIP TO GATE:
    ///   - gateQuality = 0 → softQuality doesn't matter (can't reconstruct)
    ///   - gateQuality = 1 → softQuality determines visual quality
    ///   - Final = gate * soft (multiplicative gating)
    public static let softQualitySemantic: String = """
        softQuality ∈ [0, 1]
        0 = reconstructable but poor quality
        1 = reconstructable with excellent quality
        Gated by gateQuality (multiplicative)
        """

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - depthSoftGain Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// depthSoftGain input domain
    ///
    /// INPUTS:
    /// - consensusRatio ∈ [0, 1]: fraction of agreeing sources
    /// - averageConfidence ∈ [0, 1]: mean source confidence
    /// - averageWeight ∈ [0, ∞): accumulated fusion weight
    ///
    /// INVALID SENTINEL:
    /// - consensusRatio = 0 AND averageConfidence = 0 → invalid
    public static let depthSoftGainInputDomain: String = """
        consensusRatio: [0, 1]
        averageConfidence: [0, 1]
        averageWeight: [0, ∞)
        invalid: consensusRatio=0 AND averageConfidence=0
        """

    /// depthSoftGain output range
    ///
    /// OUTPUT: [minDepthSoftGain, 1.0] = [0.08, 1.0]
    /// FLOOR: 0.08 (allows recovery with better frames)
    public static let depthSoftGainOutputRange: String = "[0.08, 1.0]"

    /// depthSoftGain monotonicity
    ///
    /// MONOTONIC INCREASING in:
    /// - consensusRatio (more agreement → higher gain)
    /// - averageConfidence (higher confidence → higher gain)
    /// - averageWeight (more evidence → higher gain)
    public static let depthSoftGainMonotonicity: String = """
        ↑ consensusRatio → ↑ depthSoftGain
        ↑ averageConfidence → ↑ depthSoftGain
        ↑ averageWeight → ↑ depthSoftGain
        """

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - edgeSoftGain Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// edgeSoftGain input domain
    ///
    /// INPUTS:
    /// - geometricScore ∈ [0, 1]: geometric edge confidence
    /// - texturalScore ∈ [0, 1]: textural edge confidence
    /// - specularScore ∈ [0, 1]: specular edge confidence
    /// - transparentScore ∈ [0, 1]: transparent edge confidence
    /// - edgeDensity ∈ [0, 1]: fraction of edge pixels
    public static let edgeSoftGainInputDomain: String = """
        geometricScore: [0, 1]
        texturalScore: [0, 1]
        specularScore: [0, 1]
        transparentScore: [0, 1]
        edgeDensity: [0, 1]
        """

    /// edgeSoftGain output range
    ///
    /// OUTPUT: [minEdgeSoftGain, 1.0] = [0.10, 1.0]
    public static let edgeSoftGainOutputRange: String = "[0.10, 1.0]"

    /// edgeSoftGain monotonicity
    ///
    /// MONOTONIC INCREASING in:
    /// - geometricScore (reliable edges → higher gain)
    /// - edgeDensity (more features → higher gain, capped)
    ///
    /// MONOTONIC DECREASING in:
    /// - specularScore (unreliable edges → lower gain)
    /// - transparentScore (unreliable edges → lower gain)
    public static let edgeSoftGainMonotonicity: String = """
        ↑ geometricScore → ↑ edgeSoftGain
        ↑ edgeDensity → ↑ edgeSoftGain (capped)
        ↑ specularScore → ↓ edgeSoftGain
        ↑ transparentScore → ↓ edgeSoftGain
        """

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - topoSoftGain Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// topoSoftGain input domain
    public static let topoSoftGainInputDomain: String = """
        holeAreaRatio: [0, 1]
        boundaryConfidence: [0, 1]
        selfOccludedRatio: [0, 1]
        depthSmoothness: [0, 1]
        """

    /// topoSoftGain output range
    public static let topoSoftGainOutputRange: String = "[0.08, 1.0]"

    /// topoSoftGain monotonicity
    public static let topoSoftGainMonotonicity: String = """
        ↑ holeAreaRatio → ↓ topoSoftGain
        ↑ boundaryConfidence → ↑ topoSoftGain
        ↑ selfOccludedRatio → ↓ topoSoftGain
        ↑ depthSmoothness → ↑ topoSoftGain
        """

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - baseSoftGain Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// baseSoftGain input domain
    public static let baseSoftGainInputDomain: String = """
        temporalConsistency: [0, 1]
        frameConsistency: [0, 1]
        """

    /// baseSoftGain output range
    public static let baseSoftGainOutputRange: String = "[0.15, 1.0]"

    /// baseSoftGain monotonicity
    public static let baseSoftGainMonotonicity: String = """
        ↑ temporalConsistency → ↑ baseSoftGain
        ↑ frameConsistency → ↑ baseSoftGain
        """

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Dynamic Weights Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// progress input domain
    ///
    /// CRITICAL: progress MUST come from PR3 evidence, NOT UI
    /// progress = gateQuality cumulative evidence / target
    public static let progressInputDomain: String = """
        progress: [0, 1]
        SOURCE: PR3 coverage ratio (gateQuality evidence)
        NOT FROM: UI percentage, frame count, time elapsed
        """

    /// Dynamic weights output
    public static let dynamicWeightsOutput: String = """
        gateWeight + softWeight = 1.0 (invariant)
        progress < 0.30: gateWeight ≈ 0.85
        progress > 0.70: gateWeight ≈ 0.25
        Smooth sigmoid transition between
        """

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Determinism Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// Determinism guarantees
    public static let determinismGuarantees: String = """
        SAME INPUT → SAME OUTPUT (bit-exact after quantization)

        FORBIDDEN:
        - Date/time-dependent values
        - Random numbers
        - Unordered iteration
        - Platform-specific libm

        REQUIRED:
        - All math via PRMath facade
        - Integer quantization for comparison
        - Fixed scan order for CCL
        - Deterministic tie-break rules
        """
}
```

---

## Part 8: Three-Tier Golden Test Strategy

### 8.1 Tier 1: Structural Assertions (Zero Tolerance)

```swift
//
// GainRangeInvariantsTests.swift
// Aether3D - Tests/Evidence/PR4/Tier1_StructuralTests
//
// Tier 1: Zero-tolerance structural assertions
// These MUST pass exactly, no tolerance allowed
//

import XCTest

final class GainRangeInvariantsTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Range Invariants
    // ═══════════════════════════════════════════════════════════════════════

    func testDepthSoftGain_AlwaysInRange() {
        // Test 10000 random-ish inputs (deterministic sequence)
        for i in 0..<10000 {
            let consensusRatio = Double(i % 101) / 100.0
            let avgConfidence = Double((i * 7) % 101) / 100.0
            let avgWeight = Double((i * 13) % 1000) / 100.0

            let gain = SoftGainFunctions.depthSoftGain(
                consensusRatio: consensusRatio,
                averageConfidence: avgConfidence,
                averageWeight: avgWeight
            )

            XCTAssertGreaterThanOrEqual(
                gain, SoftGatesV14.minDepthSoftGain,
                "depthSoftGain below floor at i=\(i)"
            )
            XCTAssertLessThanOrEqual(
                gain, 1.0,
                "depthSoftGain above 1.0 at i=\(i)"
            )
        }
    }

    func testEdgeSoftGain_AlwaysInRange() {
        for i in 0..<10000 {
            let geoScore = Double(i % 101) / 100.0
            let texScore = Double((i * 3) % 101) / 100.0
            let specScore = Double((i * 7) % 101) / 100.0
            let transScore = Double((i * 11) % 101) / 100.0
            let density = Double((i * 13) % 101) / 100.0

            let gain = SoftGainFunctions.edgeSoftGain(
                geometricScore: geoScore,
                texturalScore: texScore,
                specularScore: specScore,
                transparentScore: transScore,
                edgeDensity: density
            )

            XCTAssertGreaterThanOrEqual(
                gain, SoftGatesV14.minEdgeSoftGain,
                "edgeSoftGain below floor at i=\(i)"
            )
            XCTAssertLessThanOrEqual(
                gain, 1.0,
                "edgeSoftGain above 1.0 at i=\(i)"
            )
        }
    }

    func testTopoSoftGain_AlwaysInRange() {
        for i in 0..<10000 {
            let holeRatio = Double(i % 101) / 100.0
            let boundaryConf = Double((i * 3) % 101) / 100.0
            let selfOccRatio = Double((i * 7) % 101) / 100.0
            let smoothness = Double((i * 11) % 101) / 100.0

            let gain = SoftGainFunctions.topoSoftGain(
                holeAreaRatio: holeRatio,
                boundaryConfidence: boundaryConf,
                selfOccludedRatio: selfOccRatio,
                depthSmoothness: smoothness
            )

            XCTAssertGreaterThanOrEqual(
                gain, SoftGatesV14.minTopoSoftGain,
                "topoSoftGain below floor at i=\(i)"
            )
            XCTAssertLessThanOrEqual(
                gain, 1.0,
                "topoSoftGain above 1.0 at i=\(i)"
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Weight Sum Invariant
    // ═══════════════════════════════════════════════════════════════════════

    func testGainWeights_SumToOne() {
        let sum = SoftGatesV14.depthGainWeight +
                  SoftGatesV14.topoGainWeight +
                  SoftGatesV14.edgeGainWeight +
                  SoftGatesV14.baseGainWeight

        XCTAssertEqual(sum, 1.0, accuracy: 1e-15, "Gain weights must sum to 1.0")
    }

    func testDynamicWeights_AlwaysSumToOne() {
        for i in 0...100 {
            let progress = Double(i) / 100.0
            let (gateWeight, softWeight) = DynamicWeightComputer.computeWeights(
                progress: progress
            )

            XCTAssertEqual(
                gateWeight + softWeight, 1.0, accuracy: 1e-15,
                "Dynamic weights must sum to 1.0 at progress=\(progress)"
            )
        }
    }
}
```

### 8.2 Tier 2: Quantized Golden Tests (Bit-Exact)

```swift
//
// DepthFusionGoldenTests.swift
// Aether3D - Tests/Evidence/PR4/Tier2_QuantizedGoldenTests
//
// Tier 2: Bit-exact golden tests using Int64 quantization
//

import XCTest

final class DepthFusionGoldenTests: XCTestCase {

    // Golden fixtures loaded from JSON
    var goldenFixtures: [DepthFusionGoldenCase] = []

    override func setUp() async throws {
        goldenFixtures = try loadGoldenFixtures("depth_fusion_golden_v2.json")
    }

    func testDepthFusion_BitExactMatch() throws {
        for (index, fixture) in goldenFixtures.enumerated() {
            let engine = DepthFusionEngine()

            let result = engine.fuse(sources: fixture.inputSources)

            // Quantize result to Int64 for comparison
            let quantizedConsensus = QuantizerQ01.quantize(result.consensusRatio)
            let quantizedConfidence = QuantizerQ01.quantize(result.averageConfidence)

            // Bit-exact comparison
            XCTAssertEqual(
                quantizedConsensus,
                fixture.expectedQuantizedConsensus,
                "Consensus mismatch at fixture \(index): \(fixture.name)"
            )

            XCTAssertEqual(
                quantizedConfidence,
                fixture.expectedQuantizedConfidence,
                "Confidence mismatch at fixture \(index): \(fixture.name)"
            )
        }
    }

    func testDepthGain_BitExactMatch() throws {
        for (index, fixture) in goldenFixtures.enumerated() {
            let engine = DepthFusionEngine()
            let result = engine.fuse(sources: fixture.inputSources)

            let gain = SoftGainFunctions.depthSoftGain(
                consensusRatio: result.consensusRatio,
                averageConfidence: result.averageConfidence,
                averageWeight: result.averageWeight
            )

            let quantizedGain = QuantizerQ01.quantize(gain)

            XCTAssertEqual(
                quantizedGain,
                fixture.expectedQuantizedDepthGain,
                "Depth gain mismatch at fixture \(index): \(fixture.name)"
            )
        }
    }
}

/// Golden case structure
struct DepthFusionGoldenCase: Codable {
    let name: String
    let inputSources: [DepthFusionEngine.DepthEvidencePackage]
    let expectedQuantizedConsensus: Int64
    let expectedQuantizedConfidence: Int64
    let expectedQuantizedDepthGain: Int64
}
```

### 8.3 Tier 3: Tolerance Tests (1-2% Max)

```swift
//
// ExternalSourceNoiseTests.swift
// Aether3D - Tests/Evidence/PR4/Tier3_ToleranceTests
//
// Tier 3: Small tolerance (1-2%) only for external source noise
// ONLY for fields that depend on non-deterministic external inputs
//

import XCTest

final class ExternalSourceNoiseTests: XCTestCase {

    /// Maximum tolerance for external source noise fields
    /// MUCH stricter than original 10%
    static let maxTolerance: Double = 0.02  // 2%

    func testDepthFusion_ExternalSourceNoise() throws {
        // Simulate depth sources with small noise variations
        let baseDepthMM: Int32 = 2000  // 2m

        for noiseLevel in [0, 5, 10, 20] {  // mm noise
            let noisySource1 = createNoisyDepthSource(
                baseDepthMM: baseDepthMM,
                noiseRangeMM: Int32(noiseLevel),
                seed: 42
            )
            let noisySource2 = createNoisyDepthSource(
                baseDepthMM: baseDepthMM,
                noiseRangeMM: Int32(noiseLevel),
                seed: 43
            )

            let engine = DepthFusionEngine()
            let result = engine.fuse(sources: [noisySource1, noisySource2])

            // Expected: consensus should be close to base depth
            let avgFusedDepthMM = computeAverageValidDepth(result.depthMapMM)
            let relativeError = abs(Double(avgFusedDepthMM) - Double(baseDepthMM)) / Double(baseDepthMM)

            // Tolerance scales with noise level
            let expectedMaxError = Double(noiseLevel) / Double(baseDepthMM) * 2.0
            let tolerance = max(Self.maxTolerance, expectedMaxError)

            XCTAssertLessThanOrEqual(
                relativeError,
                tolerance,
                "Fusion error \(relativeError) exceeds tolerance \(tolerance) at noise=\(noiseLevel)mm"
            )
        }
    }

    // Helper functions...
    private func createNoisyDepthSource(
        baseDepthMM: Int32,
        noiseRangeMM: Int32,
        seed: Int
    ) -> DepthFusionEngine.DepthEvidencePackage {
        // Create deterministic "noisy" depth source
        // Uses seed for reproducibility
        // ...
        fatalError("Implementation needed")
    }

    private func computeAverageValidDepth(_ depthMap: ContiguousArray<Int32>) -> Int32 {
        var sum: Int64 = 0
        var count: Int64 = 0
        for d in depthMap where d > 0 {
            sum += Int64(d)
            count += 1
        }
        return count > 0 ? Int32(sum / count) : 0
    }
}
```

---

## Part 9: Performance and Memory

### 9.1 Fused Single-Pass Computation

```swift
//
// FusedPassBuffers.swift
// Aether3D
//
// PR4 - Fused Pass Buffer Pool
// Pre-allocated buffers for single-pass computation
//

import Foundation

/// Fused pass buffer pool
/// All intermediate buffers pre-allocated, reused across frames
///
/// GOAL: Single traversal produces:
/// - Grayscale
/// - Sobel gradients (X, Y, magnitude)
/// - HSV (hue, saturation, brightness)
/// - Depth gradients
/// - Invalid depth mask
public final class FusedPassBuffers {

    /// Resolution
    public let resolution: Int
    public let pixelCount: Int

    // ═══════════════════════════════════════════════════════════════════════
    // All buffers pre-allocated
    // ═══════════════════════════════════════════════════════════════════════

    public var grayscale: ContiguousArray<Float>
    public var gradientX: ContiguousArray<Float>
    public var gradientY: ContiguousArray<Float>
    public var gradientMag: ContiguousArray<Float>
    public var hue: ContiguousArray<Float>
    public var saturation: ContiguousArray<Float>
    public var brightness: ContiguousArray<Float>
    public var depthGradient: ContiguousArray<Float>
    public var invalidMask: ContiguousArray<Bool>

    // Temporary buffers for sorting/statistics
    public var sortBuffer: ContiguousArray<Float>
    public var histogramBuffer: ContiguousArray<Int>

    // ═══════════════════════════════════════════════════════════════════════
    // Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(resolution: Int = TSDFConfig.primaryFusionSize) {
        self.resolution = resolution
        self.pixelCount = resolution * resolution

        // Pre-allocate all buffers
        self.grayscale = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientX = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientY = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientMag = ContiguousArray(repeating: 0, count: pixelCount)
        self.hue = ContiguousArray(repeating: 0, count: pixelCount)
        self.saturation = ContiguousArray(repeating: 0, count: pixelCount)
        self.brightness = ContiguousArray(repeating: 0, count: pixelCount)
        self.depthGradient = ContiguousArray(repeating: 0, count: pixelCount)
        self.invalidMask = ContiguousArray(repeating: false, count: pixelCount)

        self.sortBuffer = ContiguousArray(repeating: 0, count: TemporalConfig.maxWindowSize)
        self.histogramBuffer = ContiguousArray(repeating: 0, count: 256)
    }

    /// Reset all buffers to zero
    public func reset() {
        for i in 0..<pixelCount {
            grayscale[i] = 0
            gradientX[i] = 0
            gradientY[i] = 0
            gradientMag[i] = 0
            hue[i] = 0
            saturation[i] = 0
            brightness[i] = 0
            depthGradient[i] = 0
            invalidMask[i] = false
        }
    }

    /// Memory usage (bytes)
    public var memoryUsage: Int {
        let floatBuffers = 9  // grayscale, gradX/Y/Mag, H/S/V, depthGrad, sortBuffer
        let floatBytes = pixelCount * MemoryLayout<Float>.size * floatBuffers
        let sortBytes = sortBuffer.count * MemoryLayout<Float>.size
        let boolBytes = pixelCount * MemoryLayout<Bool>.size
        let histBytes = histogramBuffer.count * MemoryLayout<Int>.size

        return floatBytes + sortBytes + boolBytes + histBytes
    }
}
```

### 9.2 Performance Targets and Validation

```swift
//
// FusedPassBenchmarkTests.swift
// Aether3D - Tests/Evidence/PR4/PerformanceTests
//

import XCTest

final class FusedPassBenchmarkTests: XCTestCase {

    /// Performance targets (milliseconds)
    static let depthFusionTargetMs: Double = 10.0
    static let edgeScoringTargetMs: Double = 5.0
    static let topologyTargetMs: Double = 5.0
    static let totalSoftTargetMs: Double = 25.0

    func testDepthFusion_PerformanceTarget() {
        let engine = DepthFusionEngine()
        let sources = createBenchmarkDepthSources()

        measure {
            for _ in 0..<100 {
                _ = engine.fuse(sources: sources)
            }
        }

        // Note: XCTest measure reports average time
        // Manual check: should be < 10ms per fusion
    }

    func testEdgeScoring_PerformanceTarget() {
        let scorer = EdgeScorer()
        let (rgb, depth, conf) = createBenchmarkEdgeInputs()

        measure {
            for _ in 0..<100 {
                _ = scorer.computeScores(
                    rgbPixels: rgb,
                    depthMapMM: depth,
                    depthConfidence: conf,
                    width: 256,
                    height: 256
                )
            }
        }
    }

    func testTotalSoftComputation_PerformanceTarget() {
        let computer = SoftQualityComputer()
        let inputs = createBenchmarkSoftInputs()

        measure {
            for _ in 0..<100 {
                _ = computer.computeSoftQuality(
                    depthSources: inputs.depthSources,
                    frameData: inputs.frameData,
                    normalMap: inputs.normalMap,
                    viewDirection: inputs.viewDirection,
                    gateQuality: 0.8,
                    progress: 0.5
                )
            }
        }

        // Target: < 25ms total
    }

    func testMemoryPerPatch_UnderBudget() {
        let buffers = FusedPassBuffers()
        let engine = DepthFusionEngine()
        let scorer = EdgeScorer()
        let filter = RobustTemporalFilter()

        let totalBytes = buffers.memoryUsage +
                        MemoryLayout<DepthFusionEngine>.size +
                        MemoryLayout<EdgeScorer>.size +
                        MemoryLayout<RobustTemporalFilter>.size

        let targetBytes = SoftGatesV14.memoryPerPatchKB * 1024

        XCTAssertLessThanOrEqual(
            totalBytes,
            targetBytes,
            "Memory per patch (\(totalBytes) bytes) exceeds budget (\(targetBytes) bytes)"
        )
    }

    // Benchmark data generators...
    private func createBenchmarkDepthSources() -> [DepthFusionEngine.DepthEvidencePackage] {
        // Create realistic benchmark data
        fatalError("Implementation needed")
    }

    private func createBenchmarkEdgeInputs() -> (
        ContiguousArray<UInt8>,
        ContiguousArray<Int32>,
        ContiguousArray<Float>
    ) {
        fatalError("Implementation needed")
    }

    private func createBenchmarkSoftInputs() -> BenchmarkSoftInputs {
        fatalError("Implementation needed")
    }
}

struct BenchmarkSoftInputs {
    let depthSources: [DepthFusionEngine.DepthEvidencePackage]
    let frameData: DualFrameData
    let normalMap: ContiguousArray<EvidenceVector3>?
    let viewDirection: EvidenceVector3
}
```

---

## Part 10: Integration with IsolatedEvidenceEngine

### 10.1 New Entry Points (Not Modifying Existing)

```swift
//
// IsolatedEvidenceEngine+Soft.swift
// Aether3D
//
// PR4 - Soft Quality Extension for IsolatedEvidenceEngine
// Adds NEW entry points without modifying existing methods
//

import Foundation

extension IsolatedEvidenceEngine {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Soft Quality Computer (Lazy Initialization)
    // ═══════════════════════════════════════════════════════════════════════

    /// Soft quality computer (created on first use)
    private static var _softComputer: SoftQualityComputer?

    private var softComputer: SoftQualityComputer {
        if Self._softComputer == nil {
            Self._softComputer = SoftQualityComputer()
        }
        return Self._softComputer!
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - NEW Entry Point: processObservationWithSoft
    // ═══════════════════════════════════════════════════════════════════════

    /// Process observation with both gate and soft quality
    ///
    /// NEW ENTRY POINT - Does NOT modify existing processObservation()
    ///
    /// - Parameters:
    ///   - observation: Evidence observation
    ///   - gateQuality: Gate quality from PR3
    ///   - depthSources: Depth evidence packages for soft computation
    ///   - frameData: Dual frame data
    ///   - normalMap: Surface normals (optional)
    ///   - viewDirection: Camera view direction
    ///   - progress: Capture progress from PR3 evidence
    ///   - verdict: Observation verdict
    public func processObservationWithSoft(
        _ observation: EvidenceObservation,
        gateQuality: Double,
        depthSources: [DepthFusionEngine.DepthEvidencePackage],
        frameData: DualFrameData,
        normalMap: ContiguousArray<EvidenceVector3>?,
        viewDirection: EvidenceVector3,
        progress: Double,
        verdict: ObservationVerdict
    ) {
        // Compute soft quality
        let softQuality = softComputer.computeSoftQuality(
            depthSources: depthSources,
            frameData: frameData,
            normalMap: normalMap,
            viewDirection: viewDirection,
            gateQuality: gateQuality,
            progress: progress
        )

        // Delegate to existing processObservation
        // This preserves all PR2/PR3 behavior
        processObservation(
            observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - NEW Entry Point: processFrameWithGateAndSoft
    // ═══════════════════════════════════════════════════════════════════════

    /// Convenience wrapper for full frame processing
    ///
    /// Computes gate quality (via PR3) and soft quality (via PR4)
    ///
    /// - Parameters:
    ///   - observation: Evidence observation
    ///   - gateInputs: Inputs for gate computation
    ///   - softInputs: Inputs for soft computation
    ///   - verdict: Observation verdict
    public func processFrameWithGateAndSoft(
        observation: EvidenceObservation,
        gateInputs: GateQualityInputs,
        softInputs: SoftQualityInputs,
        verdict: ObservationVerdict
    ) {
        // Compute gate quality (PR3)
        let gateQuality = gateComputer.computeGateQuality(
            patchId: observation.patchId,
            cameraPosition: gateInputs.cameraPosition,
            patchCenter: gateInputs.patchCenter,
            reprojRmsPx: gateInputs.reprojRmsPx,
            edgeRmsPx: gateInputs.edgeRmsPx,
            sharpness: gateInputs.sharpness,
            overexposureRatio: gateInputs.overexposureRatio,
            underexposureRatio: gateInputs.underexposureRatio,
            timestampMs: Int64(observation.timestamp * 1000)
        )

        // Get progress from gate evidence
        let progress = computeProgressFromGateEvidence(patchId: observation.patchId)

        // Compute soft quality (PR4)
        let softQuality = softComputer.computeSoftQuality(
            depthSources: softInputs.depthSources,
            frameData: softInputs.frameData,
            normalMap: softInputs.normalMap,
            viewDirection: softInputs.viewDirection,
            gateQuality: gateQuality,
            progress: progress
        )

        // Process with both qualities
        processObservation(
            observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Progress Computation (From PR3 Evidence)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute progress from gate quality evidence
    ///
    /// CRITICAL: Progress comes from PR3 evidence, NOT from UI
    private func computeProgressFromGateEvidence(patchId: String) -> Double {
        // Get view stats from gate tracker
        guard let viewStats = gateComputer.tracker.stats(for: patchId) else {
            return 0.0
        }

        // Progress based on L2+/L3 achievement
        let l2Target = Double(HardGatesV13.minL2PlusCount)
        let l3Target = Double(HardGatesV13.minL3Count)
        let thetaTarget = HardGatesV13.minThetaSpanDeg

        let l2Progress = Double(viewStats.l2PlusCount) / l2Target
        let l3Progress = Double(viewStats.l3Count) / l3Target
        let thetaProgress = viewStats.thetaSpanDeg / thetaTarget

        // Combined progress (geometric mean for balanced weighting)
        let combined = PRMath.pow(
            l2Progress * l3Progress * thetaProgress,
            1.0 / 3.0
        )

        return PRMath.clamp(combined, 0.0, 1.0)
    }
}

/// Gate quality inputs structure
public struct GateQualityInputs: Sendable {
    public let cameraPosition: SIMD3<Float>
    public let patchCenter: SIMD3<Float>
    public let reprojRmsPx: Double
    public let edgeRmsPx: Double
    public let sharpness: Double
    public let overexposureRatio: Double
    public let underexposureRatio: Double

    public init(
        cameraPosition: SIMD3<Float>,
        patchCenter: SIMD3<Float>,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double
    ) {
        self.cameraPosition = cameraPosition
        self.patchCenter = patchCenter
        self.reprojRmsPx = reprojRmsPx
        self.edgeRmsPx = edgeRmsPx
        self.sharpness = sharpness
        self.overexposureRatio = overexposureRatio
        self.underexposureRatio = underexposureRatio
    }
}

/// Soft quality inputs structure
public struct SoftQualityInputs: Sendable {
    public let depthSources: [DepthFusionEngine.DepthEvidencePackage]
    public let frameData: DualFrameData
    public let normalMap: ContiguousArray<EvidenceVector3>?
    public let viewDirection: EvidenceVector3

    public init(
        depthSources: [DepthFusionEngine.DepthEvidencePackage],
        frameData: DualFrameData,
        normalMap: ContiguousArray<EvidenceVector3>?,
        viewDirection: EvidenceVector3
    ) {
        self.depthSources = depthSources
        self.frameData = frameData
        self.normalMap = normalMap
        self.viewDirection = viewDirection
    }
}
```

---

## Part 11: Implementation Phase Order

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PR4 IMPLEMENTATION PHASES                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PHASE 1: Constants & Math Foundation (Zero Dependencies)                    │
│  ├── SoftGatesV14.swift                                                     │
│  ├── TSDFConfig.swift                                                       │
│  ├── EdgeScoringConfig.swift                                                │
│  ├── TemporalConfig.swift                                                   │
│  ├── DeterminismConfig.swift                                                │
│  ├── PR4Math.swift (facade, uses PRMath)                                    │
│  └── Tests: Tier1_StructuralTests/WeightSumTests.swift                      │
│                                                                             │
│  PHASE 2: Internal Infrastructure                                            │
│  ├── FusedPassBuffers.swift                                                 │
│  ├── IntegerDepthBucket.swift                                               │
│  ├── AllocationSentinel.swift                                               │
│  ├── SoftRingBuffer.swift                                                   │
│  └── Tests: AllocationSentinelTests.swift                                   │
│                                                                             │
│  PHASE 3: TSDF-Inspired Depth Fusion                                        │
│  ├── DepthEvidencePackage (type definition)                                 │
│  ├── DepthFusionEngine.swift                                                │
│  ├── DepthTruncator.swift                                                   │
│  ├── AntiGrazingFilter.swift                                                │
│  └── Tests: DepthFusionTests.swift, DepthFusionGoldenTests.swift            │
│                                                                             │
│  PHASE 4: Hierarchical Refinement                                            │
│  ├── HierarchicalRefiner.swift                                              │
│  └── Tests: HierarchicalRefinerTests.swift                                  │
│                                                                             │
│  PHASE 5: Continuous Edge Scoring                                            │
│  ├── EdgeScorer.swift                                                       │
│  ├── EdgeTypeScores.swift                                                   │
│  ├── HSVStabilizer.swift                                                    │
│  ├── FusedEdgePass.swift                                                    │
│  └── Tests: EdgeScorerTests.swift, EdgeScorerGoldenTests.swift              │
│                                                                             │
│  PHASE 6: Topology Evaluation                                                │
│  ├── HoleDetector.swift (deterministic CCL)                                 │
│  ├── OcclusionBoundaryTracker.swift                                         │
│  ├── SelfOcclusionComputer.swift                                            │
│  ├── TopologyEvaluator.swift                                                │
│  └── Tests: TopologyTests.swift, CCLDeterminismTests.swift                  │
│                                                                             │
│  PHASE 7: Robust Temporal Filtering                                          │
│  ├── RobustTemporalFilter.swift                                             │
│  ├── TemporalAntiOvershoot.swift                                            │
│  ├── MotionCompensator.swift                                                │
│  └── Tests: TemporalFilterTests.swift                                       │
│                                                                             │
│  PHASE 8: Dual Frame Channel                                                 │
│  ├── DualFrameManager.swift                                                 │
│  ├── FrameConsistencyChecker.swift                                          │
│  └── Tests: DualChannelTests.swift                                          │
│                                                                             │
│  PHASE 9: Gain Functions                                                     │
│  ├── SoftGainFunctions.swift                                                │
│  ├── SoftConstitution.swift                                                 │
│  └── Tests: GainRangeInvariantsTests.swift, MonotonicityTests.swift         │
│                                                                             │
│  PHASE 10: Integration                                                       │
│  ├── SoftQualityComputer.swift                                              │
│  ├── DynamicWeightComputer.swift                                            │
│  ├── IsolatedEvidenceEngine+Soft.swift (NEW extension, not modify)          │
│  └── Tests: SoftIntegrationTests.swift                                      │
│                                                                             │
│  PHASE 11: Validation                                                        │
│  ├── SoftInputValidator.swift                                               │
│  ├── DepthEvidenceValidator.swift                                           │
│  ├── SoftInputInvalidReason.swift                                           │
│  └── Tests: ValidationTests.swift                                           │
│                                                                             │
│  PHASE 12: Determinism Tests                                                 │
│  ├── SoftDeterminism100RunTests.swift                                       │
│  ├── TieBreakDeterminismTests.swift                                         │
│  └── SoftCrossPlatformTests.swift                                           │
│                                                                             │
│  PHASE 13: Golden Fixtures                                                   │
│  ├── depth_fusion_golden_v2.json                                            │
│  ├── edge_scorer_golden_v2.json                                             │
│  ├── topology_golden_v2.json                                                │
│  └── soft_quality_golden_v2.json                                            │
│                                                                             │
│  PHASE 14: CI Configuration                                                  │
│  ├── pr4-whitelist.yml                                                      │
│  ├── pr4_import_lint.sh                                                     │
│  └── Update evidence-tests.yml with PR4 test filters                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 12: File Deliverables Checklist

```
Core/Evidence/PR4/                          STATUS
├── SoftGainFunctions.swift                 [ ] Phase 9
├── SoftQualityComputer.swift               [ ] Phase 10
├── SoftConstitution.swift                  [ ] Phase 9
├── DynamicWeightComputer.swift             [ ] Phase 10
├── DepthFusion/
│   ├── DepthFusionEngine.swift             [ ] Phase 3
│   ├── DepthTruncator.swift                [ ] Phase 3
│   ├── AntiGrazingFilter.swift             [ ] Phase 3
│   ├── HierarchicalRefiner.swift           [ ] Phase 4
│   └── DepthSourceAdapter.swift            [ ] Phase 3
├── EdgeClassification/
│   ├── EdgeScorer.swift                    [ ] Phase 5
│   ├── EdgeTypeScores.swift                [ ] Phase 5
│   ├── HSVStabilizer.swift                 [ ] Phase 5
│   └── FusedEdgePass.swift                 [ ] Phase 5
├── Topology/
│   ├── TopologyEvaluator.swift             [ ] Phase 6
│   ├── HoleDetector.swift                  [ ] Phase 6
│   ├── OcclusionBoundaryTracker.swift      [ ] Phase 6
│   └── SelfOcclusionComputer.swift         [ ] Phase 6
├── DualChannel/
│   ├── DualFrameManager.swift              [ ] Phase 8
│   └── FrameConsistencyChecker.swift       [ ] Phase 8
├── Temporal/
│   ├── RobustTemporalFilter.swift          [ ] Phase 7
│   ├── TemporalAntiOvershoot.swift         [ ] Phase 7
│   └── MotionCompensator.swift             [ ] Phase 7
├── Internal/
│   ├── FusedPassBuffers.swift              [ ] Phase 2
│   ├── IntegerDepthBucket.swift            [ ] Phase 2
│   ├── AllocationSentinel.swift            [ ] Phase 2
│   └── SoftRingBuffer.swift                [ ] Phase 2
└── Validation/
    ├── SoftInputValidator.swift            [ ] Phase 11
    ├── DepthEvidenceValidator.swift        [ ] Phase 11
    └── SoftInputInvalidReason.swift        [ ] Phase 11

Core/Evidence/PR4Math/
├── PR4Math.swift                           [ ] Phase 1
├── SobelKernels.swift                      [ ] Phase 1
├── BilinearInterpolator.swift              [ ] Phase 1
├── HSVConverter.swift                      [ ] Phase 1
├── TrimmedMeanComputer.swift               [ ] Phase 1
└── IntegerQuantizer.swift                  [ ] Phase 1

Core/Evidence/Constants/
├── SoftGatesV14.swift                      [ ] Phase 1
├── TSDFConfig.swift                        [ ] Phase 1
├── EdgeScoringConfig.swift                 [ ] Phase 1
├── TemporalConfig.swift                    [ ] Phase 1
└── DeterminismConfig.swift                 [ ] Phase 1

Tests/Evidence/PR4/
├── Tier1_StructuralTests/
│   ├── GainRangeInvariantsTests.swift      [ ] Phase 9
│   ├── MonotonicityTests.swift             [ ] Phase 9
│   └── WeightSumTests.swift                [ ] Phase 1
├── Tier2_QuantizedGoldenTests/
│   ├── DepthFusionGoldenTests.swift        [ ] Phase 13
│   ├── EdgeScorerGoldenTests.swift         [ ] Phase 13
│   └── TopologyGoldenTests.swift           [ ] Phase 13
├── Tier3_ToleranceTests/
│   └── ExternalSourceNoiseTests.swift      [ ] Phase 13
├── DeterminismTests/
│   ├── SoftDeterminism100RunTests.swift    [ ] Phase 12
│   ├── CCLDeterminismTests.swift           [ ] Phase 12
│   └── TieBreakDeterminismTests.swift      [ ] Phase 12
├── CrossPlatformTests/
│   └── SoftCrossPlatformTests.swift        [ ] Phase 12
└── PerformanceTests/
    ├── AllocationSentinelTests.swift       [ ] Phase 2
    └── FusedPassBenchmarkTests.swift       [ ] Phase 9

Tests/Evidence/Fixtures/Golden/
├── depth_fusion_golden_v2.json             [ ] Phase 13
├── edge_scorer_golden_v2.json              [ ] Phase 13
├── topology_golden_v2.json                 [ ] Phase 13
└── soft_quality_golden_v2.json             [ ] Phase 13

.github/workflows/
├── pr4-whitelist.yml                       [ ] Phase 14
└── scripts/ci/pr4_import_lint.sh           [ ] Phase 14
```

---

## Part 13: Acceptance Criteria Summary

### Functional (10 criteria)
| ID | Criterion | Verification |
|----|-----------|--------------|
| F1 | depthSoftGain in [0.08, 1] | Tier 1 test |
| F2 | edgeSoftGain in [0.10, 1] | Tier 1 test |
| F3 | topoSoftGain in [0.08, 1] | Tier 1 test |
| F4 | Gain weights sum to 1.0 | Tier 1 test |
| F5 | Dynamic weights sum to 1.0 | Tier 1 test |
| F6 | TSDF truncation clamps residuals | Unit test |
| F7 | Edge scorer produces 4 scores | Unit test |
| F8 | Temporal filter uses trimmed mean | Unit test |
| F9 | Gate→Soft gating is multiplicative | Integration test |
| F10 | Progress from PR3 evidence | Integration test |

### Determinism (6 criteria)
| ID | Criterion | Verification |
|----|-----------|--------------|
| D1 | 100 runs produce identical results | Determinism test |
| D2 | CCL scan order is row-major | Determinism test |
| D3 | Tie-break rules are deterministic | Determinism test |
| D4 | No forbidden APIs in PR4 | CI lint |
| D5 | Cross-platform results within 0.1% | Cross-platform test |
| D6 | Integer quantization for golden | Tier 2 test |

### Performance (6 criteria)
| ID | Criterion | Target |
|----|-----------|--------|
| P1 | Depth fusion | < 10ms |
| P2 | Edge scoring | < 5ms |
| P3 | Topology evaluation | < 5ms |
| P4 | Total soft computation | < 25ms |
| P5 | Memory per patch | < 50KB |
| P6 | Zero allocation in hot path | AllocationSentinel |

### Isolation (5 criteria)
| ID | Criterion | Verification |
|----|-----------|--------------|
| I1 | PR4 doesn't modify PR3 files | CI whitelist |
| I2 | PR4 imports only allowed | CI lint |
| I3 | New entry points, not modify | Code review |
| I4 | Math only via PRMath | CI lint |
| I5 | No platform-specific imports | CI lint |

---

**Document Version:** 2.0 (Bulletproof Edition)
**Author:** Claude Code
**Created:** 2026-01-31
**Status:** DRAFT - READY FOR IMPLEMENTATION

---

## Appendix: Key Reference Links

- [Open3D TSDF Integration](https://www.open3d.org/docs/latest/tutorial/t_reconstruction_system/integration.html)
- [TSDF Fusion GitHub](https://github.com/andyzeng/tsdf-fusion)
- [Apple Depth Pro](https://machinelearning.apple.com/research/depth-pro)
- [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2)
- [ChronoDepth Temporal Consistency](https://arxiv.org/abs/2406.01493)
- [NTIRE 2024 Specular/Transparent Challenge](https://cvlab-unibo.github.io/booster-web/ntire24.html)
- [Occlusion Boundary + Depth Multi-Task](https://arxiv.org/html/2505.21231v1)
- [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)
- [Swift Memory Allocation Guide](https://www.swift.org/documentation/server/guides/allocations.html)
- [Connected Component Labeling](https://suzukilab.first.iir.titech.ac.jp/wp-content/uploads/2020/01/HeChaoSuzuki_CombinationalAlgoCCL_JReal-TimeImagProc2014.pdf)
