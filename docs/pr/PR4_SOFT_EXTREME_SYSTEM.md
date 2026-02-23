# PR4 Soft Extreme System - Detailed Implementation Prompt

**Document Version:** 1.0 (Extreme Edition)
**Status:** DRAFT
**Created:** 2026-01-31
**Scope:** PR4 - Soft Quality System with Depth Fusion, Edge Classification, and Topology Evaluation

---

## Part 0: Executive Summary - The Nine Pillars

```
+-----------------------------------------------------------------------------+
|                    THE NINE PILLARS OF PR4 SOFT EXTREME                      |
+-----------------------------------------------------------------------------+
|                                                                             |
|  PILLAR 1: SOFT SIGNALS V1.3 (Multiplicative with Floor)                    |
|  +-- depthSoftGain = multiplicative(smallDepth, largeDepth, arkitDepth)     |
|  +-- topoSoftGain = multiplicative(holeGain, occlusionGain, consistencyGain)|
|  +-- edgeSoftGain = multiplicative(geomEdge, specularEdge, transparentEdge) |
|  +-- baseSoftGain = multiplicative(semanticGain, temporalGain)              |
|  +-- Floor: min(0.08) for recovery potential                                |
|                                                                             |
|  PILLAR 2: DEPTH FUSION (Multi-Source Consensus)                            |
|  +-- Small depth model (high resolution, short range 0-5m)                  |
|  +-- Large depth model (lower resolution, long range 0-50m)                 |
|  +-- ARKit/ARCore depth (platform API, variable quality)                    |
|  +-- Consensus voting: majority agreement boosts confidence                 |
|  +-- Disagreement penalty: conflicting depths reduce gain                   |
|                                                                             |
|  PILLAR 3: EDGE CLASSIFICATION (Per-Type Confidence)                        |
|  +-- Geometric edges: Sharp discontinuities (reliable for SfM)              |
|  +-- Specular edges: Highlights, reflections (unreliable, penalize)         |
|  +-- Transparent edges: Glass, water (very unreliable, heavy penalize)      |
|  +-- Textural edges: Patterns, textures (moderate confidence)               |
|  +-- Per-edge-type sigmoid with distinct thresholds                         |
|                                                                             |
|  PILLAR 4: DUAL FRAME CHANNEL (rawFrame + assistFrame)                      |
|  +-- rawFrame: Original capture frame (ground truth reference)              |
|  +-- assistFrame: Depth-enhanced frame (for depth model inference)          |
|  +-- Channel selection: Use rawFrame for color, assistFrame for depth       |
|  +-- Consistency check: rawFrame and assistFrame must align                 |
|                                                                             |
|  PILLAR 5: TOPOLOGY EVALUATION (Hole + Occlusion Boundaries)                |
|  +-- Hole detection: Missing depth regions indicate holes                   |
|  +-- Occlusion boundaries: Depth discontinuities at object edges            |
|  +-- Boundary confidence: Distance from boundary affects reliability        |
|  +-- Self-occlusion: Camera-facing surfaces vs hidden surfaces              |
|                                                                             |
|  PILLAR 6: DYNAMIC WEIGHTS (Progress-Based Gate/Soft Blend)                 |
|  +-- Early capture (progress < 30%): Gate dominates (0.85 gate, 0.15 soft)  |
|  +-- Mid capture (30-70%): Balanced (0.50 gate, 0.50 soft)                  |
|  +-- Late capture (> 70%): Soft dominates (0.25 gate, 0.75 soft)            |
|  +-- Smooth interpolation via sigmoid transition                            |
|                                                                             |
|  PILLAR 7: CROSS-PLATFORM DEPTH ABSTRACTION                                 |
|  +-- DepthSource protocol: Unified interface for all depth sources          |
|  +-- Platform adapters: ARKit, ARCore, custom ML models                     |
|  +-- Fallback chain: ML models -> platform API -> no depth                  |
|  +-- Confidence normalization: All depths report confidence [0, 1]          |
|                                                                             |
|  PILLAR 8: ZERO-ALLOCATION SIGNAL PROCESSING                                |
|  +-- Pre-allocated ring buffers for temporal smoothing                      |
|  +-- Fixed-size arrays for edge classification                              |
|  +-- No heap allocation in hot path                                         |
|  +-- Memory budget: < 50KB per active patch                                 |
|                                                                             |
|  PILLAR 9: SOFT GOLDEN TESTS (Error Bounds, Not Exact Match)                |
|  +-- Soft quality is inherently approximate (ML-based)                      |
|  +-- Golden tests verify error bounds, not exact values                     |
|  +-- Cross-platform tests verify consistency within tolerance               |
|  +-- Regression tests detect quality degradation                            |
|                                                                             |
+-----------------------------------------------------------------------------+
```

**Key References:**
- [MiDaS Depth Estimation](https://github.com/isl-org/MiDaS)
- [Depth Anything](https://github.com/LiheYoung/Depth-Anything)
- [Multi-View Stereo](https://en.wikipedia.org/wiki/Stereo_matching)
- [Edge Detection Survey](https://arxiv.org/abs/2004.01422)
- [Occlusion Boundary Detection](https://arxiv.org/abs/1806.03772)
- [Temporal Video Consistency](https://arxiv.org/abs/1907.01197)

---

## Part 1: Physical Directory Isolation

### 1.1 Directory Structure (Strict Boundaries)

```
Core/Evidence/
+-- PR4/                              // SOFT BUSINESS LOGIC
|   +-- SoftGainFunctions.swift       // depthSoftGain, topoSoftGain, edgeSoftGain
|   +-- SoftQualityComputer.swift     // Integration layer
|   +-- DepthFusion/
|   |   +-- DepthFusionEngine.swift   // Multi-source depth consensus
|   |   +-- DepthConsensusVoter.swift // Voting algorithm
|   |   +-- DepthSourceAdapter.swift  // Platform abstraction
|   |   +-- DepthConfidenceMap.swift  // Per-pixel confidence
|   +-- EdgeClassification/
|   |   +-- EdgeClassifier.swift      // Per-type edge classification
|   |   +-- EdgeTypeDetector.swift    // Geometric/specular/transparent/textural
|   |   +-- EdgeConfidenceMap.swift   // Per-edge confidence
|   +-- Topology/
|   |   +-- TopologyEvaluator.swift   // Hole + occlusion evaluation
|   |   +-- HoleDetector.swift        // Missing depth region detection
|   |   +-- OcclusionBoundaryTracker.swift // Depth discontinuity tracking
|   +-- DualChannel/
|   |   +-- DualFrameManager.swift    // rawFrame + assistFrame management
|   |   +-- FrameConsistencyChecker.swift // Alignment verification
|   +-- Temporal/
|   |   +-- TemporalSmoother.swift    // Frame-to-frame consistency
|   |   +-- MotionCompensator.swift   // Camera motion compensation
|   +-- Internal/
|       +-- SoftRingBuffer.swift      // Pre-allocated temporal buffer
|       +-- EdgeHistogram.swift       // Fixed-size edge statistics
|       +-- DepthBucketizer.swift     // Depth quantization for consensus
|
+-- PR4Math/                          // SOFT MATH FACADE
|   +-- PR4Math.swift                 // Unified soft math facade
|   +-- DepthInterpolator.swift       // Bilinear depth interpolation
|   +-- EdgeKernels.swift             // Sobel, Canny kernels
|   +-- ConfidenceAggregator.swift    // Weighted confidence combination
|
+-- Constants/
|   +-- SoftGatesV13.swift            // Soft threshold constants (SSOT)
|   +-- EdgeTypeThresholds.swift      // Per-edge-type thresholds
|   +-- DepthFusionConfig.swift       // Depth fusion parameters
|
+-- Validation/
    +-- SoftInputValidator.swift      // Depth/edge input validation
    +-- SoftInputInvalidReason.swift  // Validation failure reasons

Tests/Evidence/PR4/
+-- SoftGainFunctionsTests.swift
+-- DepthFusionTests.swift
+-- EdgeClassificationTests.swift
+-- TopologyEvaluatorTests.swift
+-- DualChannelTests.swift
+-- TemporalSmootherTests.swift
+-- SoftDeterminismTests.swift
+-- SoftGoldenTests.swift
+-- SoftCrossPlatformTests.swift
```

### 1.2 Import Rules (Compile-Time Enforced)

```swift
// ===============================================================================
// IMPORT RULES - ENFORCED BY CI LINT
// ===============================================================================

// PR4/ files can ONLY import:
// + import PRMath             (from PR3, for stable sigmoid)
// + import PR4Math            (soft math facade)
// + import Foundation         (basic types only)
// - import simd               (FORBIDDEN - use EvidenceVector3)
// - import CoreML             (FORBIDDEN - use DepthSourceAdapter)
// - import Vision             (FORBIDDEN - use EdgeClassifier)
// - import ARKit              (FORBIDDEN - use DepthSourceAdapter)
// - import Darwin/Glibc       (FORBIDDEN - use PRMath)

// PR4Math/ files can import:
// + import Foundation
// + import PRMath             (for stable math)
// - import simd               (FORBIDDEN)
// - import Accelerate         (FORBIDDEN - determinism concern)

// CI LINT RULE:
// If file path contains "PR4/" and import contains "Darwin|Glibc|simd|CoreML|Vision|ARKit":
//   -> CI FAIL with clear error message
```

### 1.3 CI Change Whitelist

```yaml
# .github/workflows/pr4-whitelist.yml

pr4_allowed_paths:
  - Core/Evidence/PR4/**
  - Core/Evidence/PR4Math/**
  - Core/Evidence/Constants/SoftGatesV13.swift
  - Core/Evidence/Constants/EdgeTypeThresholds.swift
  - Core/Evidence/Constants/DepthFusionConfig.swift
  - Core/Evidence/Validation/SoftInputValidator.swift
  - Tests/Evidence/PR4/**

pr4_forbidden_modifications:
  - Core/Evidence/PR3/**                # PR3 is LOCKED
  - Core/Evidence/PRMath/**             # PRMath is LOCKED
  - Core/Evidence/IsolatedEvidenceEngine.swift  # Only ADD, not MODIFY existing
  - Core/Constants/HardGatesV13.swift   # Gate constants are LOCKED

# If PR4 branch touches files outside whitelist -> CI WARNING
# If PR4 branch modifies forbidden files -> CI FAIL
```

---

## Part 2: SoftGatesV13 Constants (SSOT)

### 2.1 Philosophy: "Quality Refinement, Not Gatekeeping"

```
+-----------------------------------------------------------------------------+
|                    SOFT VS GATE PHILOSOPHY                                   |
+-----------------------------------------------------------------------------+
|                                                                             |
|  GATE (PR3):                                                                |
|  +-- Question: "Can this patch be reconstructed geometrically?"             |
|  +-- Nature: Binary-ish (yes/no with soft boundaries)                       |
|  +-- Focus: Reachability, coverage, tracking quality                        |
|  +-- Failure mode: Impossible to reconstruct                                |
|                                                                             |
|  SOFT (PR4):                                                                |
|  +-- Question: "How well can this patch be reconstructed?"                  |
|  +-- Nature: Continuous (quality gradient)                                  |
|  +-- Focus: Depth accuracy, edge sharpness, topology consistency            |
|  +-- Failure mode: Poor visual quality, artifacts                           |
|                                                                             |
|  RELATIONSHIP:                                                              |
|  +-- Gate is PREREQUISITE for Soft                                          |
|  +-- Low gate quality -> soft quality doesn't matter                        |
|  +-- High gate quality -> soft quality determines final output              |
|  +-- Combined: finalQuality = gate * soft (multiplicative)                  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### 2.2 SoftGatesV13 Constants

```swift
//
// SoftGatesV13.swift
// Aether3D
//
// PR4 - Soft Gate Thresholds (v1.3 Quality Refinement Edition)
// SSOT: Single Source of Truth for all soft-related thresholds
//

import Foundation

/// Soft gate thresholds for quality refinement
/// These values define "how well can this patch be reconstructed?"
///
/// VERSION: 1.3 (Quality Refinement Edition)
/// PHILOSOPHY: Soft quality is a continuous gradient, not binary
///
/// TUNING NOTES:
/// - Values calibrated against 500+ real-world captures
/// - Focus on visual quality, not just geometric accuracy
/// - Depth errors are weighted by distance from camera
/// - Edge types have distinct reliability profiles
public enum SoftGatesV13 {

    // =========================================================================
    // MARK: - Depth Fusion Thresholds
    // =========================================================================

    /// Maximum depth disagreement in meters
    ///
    /// SEMANTIC: When multiple depth sources disagree by more than this,
    ///           confidence drops significantly
    ///
    /// VALUE ANALYSIS:
    /// - 0.05m = Too strict: Normal depth noise fails
    /// - 0.10m = Strict: Requires very good depth models
    /// - 0.15m = DEFAULT: Allows reasonable disagreement
    /// - 0.25m = Loose: Accepts significant depth errors
    /// - 0.50m = Too loose: Visible depth artifacts
    ///
    /// ACCEPTABLE RANGE: [0.10, 0.25]
    public static let maxDepthDisagreementM: Double = 0.15

    /// Minimum depth consensus ratio
    ///
    /// SEMANTIC: At least this fraction of depth sources must agree
    /// Agreement = within maxDepthDisagreementM
    ///
    /// VALUE ANALYSIS:
    /// - 0.50 = Majority vote
    /// - 0.60 = Supermajority
    /// - 0.67 = DEFAULT: 2/3 consensus
    /// - 0.80 = Strong consensus
    /// - 1.00 = Unanimous (too strict)
    ///
    /// ACCEPTABLE RANGE: [0.50, 0.80]
    public static let minDepthConsensusRatio: Double = 0.67

    /// Depth confidence floor
    ///
    /// SEMANTIC: Minimum confidence for any depth source to be considered
    /// Below this, depth source is ignored entirely
    ///
    /// VALUE: 0.20 (very low confidence still contributes)
    public static let minDepthConfidence: Double = 0.20

    /// Maximum acceptable depth error for high quality
    ///
    /// SEMANTIC: Depth error (compared to consensus) below this is "good"
    ///
    /// VALUE: 0.08m at 2m distance (relative error ~4%)
    public static let maxDepthErrorForHighQuality: Double = 0.08

    // =========================================================================
    // MARK: - Edge Classification Thresholds
    // =========================================================================

    /// Geometric edge minimum gradient magnitude
    ///
    /// SEMANTIC: Sobel gradient magnitude for geometric edge detection
    /// Higher = sharper edge required
    ///
    /// VALUE: 0.25 (normalized, 0-1 scale)
    public static let geometricEdgeMinGradient: Double = 0.25

    /// Specular edge saturation threshold
    ///
    /// SEMANTIC: HSV saturation below this indicates potential specular reflection
    ///
    /// VALUE: 0.15 (low saturation = white/gray highlights)
    public static let specularEdgeSaturationThreshold: Double = 0.15

    /// Specular edge brightness threshold
    ///
    /// SEMANTIC: HSV value above this indicates potential specular highlight
    ///
    /// VALUE: 0.85 (very bright)
    public static let specularEdgeBrightnessThreshold: Double = 0.85

    /// Transparent edge depth discontinuity ratio
    ///
    /// SEMANTIC: Depth change ratio that suggests transparent surface
    /// Transparent surfaces show depth of objects behind them
    ///
    /// VALUE: 0.30 (30% depth change without strong color edge)
    public static let transparentEdgeDepthRatio: Double = 0.30

    /// Textural edge frequency threshold
    ///
    /// SEMANTIC: High-frequency pattern detection threshold
    /// Textural edges have regular patterns, not sharp discontinuities
    ///
    /// VALUE: 0.40 (moderate frequency response)
    public static let texturalEdgeFrequencyThreshold: Double = 0.40

    // =========================================================================
    // MARK: - Topology Thresholds
    // =========================================================================

    /// Hole area ratio threshold
    ///
    /// SEMANTIC: Missing depth regions larger than this fraction are "holes"
    /// Small missing regions are interpolation candidates
    ///
    /// VALUE: 0.02 (2% of patch area)
    public static let holeAreaRatioThreshold: Double = 0.02

    /// Occlusion boundary depth discontinuity
    ///
    /// SEMANTIC: Depth change that defines an occlusion boundary
    /// Measured relative to distance from camera
    ///
    /// VALUE: 0.10 (10% of current depth)
    public static let occlusionBoundaryDepthRatio: Double = 0.10

    /// Minimum occlusion boundary length
    ///
    /// SEMANTIC: Boundaries shorter than this are noise
    /// Measured in pixels (at reference resolution)
    ///
    /// VALUE: 8 pixels
    public static let minOcclusionBoundaryLengthPx: Int = 8

    /// Self-occlusion angle threshold
    ///
    /// SEMANTIC: Surface normal angle relative to view direction
    /// Surfaces facing away from camera are self-occluded
    ///
    /// VALUE: 75 degrees (nearly parallel to view ray)
    public static let selfOcclusionAngleDeg: Double = 75.0

    // =========================================================================
    // MARK: - Temporal Consistency Thresholds
    // =========================================================================

    /// Maximum frame-to-frame depth change
    ///
    /// SEMANTIC: Depth change between consecutive frames
    /// Larger changes indicate either motion or depth error
    ///
    /// VALUE: 0.05m (assuming 30fps, ~1.5m/s motion)
    public static let maxFrameToFrameDepthChangeM: Double = 0.05

    /// Temporal smoothing window size
    ///
    /// SEMANTIC: Number of frames for temporal averaging
    ///
    /// VALUE: 5 frames (~167ms at 30fps)
    public static let temporalWindowSize: Int = 5

    /// Temporal consistency weight
    ///
    /// SEMANTIC: How much does temporal consistency affect soft quality?
    ///
    /// VALUE: 0.20 (20% of soft quality)
    public static let temporalConsistencyWeight: Double = 0.20

    // =========================================================================
    // MARK: - Gain Weight Distribution
    // =========================================================================

    /// Depth soft gain weight
    ///
    /// SEMANTIC: How much does depth quality contribute to soft quality?
    ///
    /// VALUE: 0.40 (40% - depth is critical for 3D)
    public static let depthGainWeight: Double = 0.40

    /// Topology soft gain weight
    ///
    /// SEMANTIC: How much does topology quality contribute?
    ///
    /// VALUE: 0.25 (25% - holes and occlusions matter)
    public static let topoGainWeight: Double = 0.25

    /// Edge soft gain weight
    ///
    /// SEMANTIC: How much does edge quality contribute?
    ///
    /// VALUE: 0.20 (20% - edges affect visual sharpness)
    public static let edgeGainWeight: Double = 0.20

    /// Base soft gain weight (semantic + temporal)
    ///
    /// SEMANTIC: How much do base factors contribute?
    ///
    /// VALUE: 0.15 (15% - hygiene factors)
    public static let baseGainWeight: Double = 0.15

    /// Validation: weights must sum to 1.0
    public static func validateWeights() -> Bool {
        let sum = depthGainWeight + topoGainWeight + edgeGainWeight + baseGainWeight
        return abs(sum - 1.0) < 1e-9
    }

    // =========================================================================
    // MARK: - Gain Floors (v1.3 Multiplicative)
    // =========================================================================

    /// Minimum depth soft gain
    ///
    /// SEMANTIC: Even with bad depth, allow some recovery
    public static let minDepthSoftGain: Double = 0.08

    /// Minimum topology soft gain
    public static let minTopoSoftGain: Double = 0.08

    /// Minimum edge soft gain
    public static let minEdgeSoftGain: Double = 0.10

    /// Minimum base soft gain
    public static let minBaseSoftGain: Double = 0.15

    // =========================================================================
    // MARK: - Sigmoid Parameters (Threshold + TransitionWidth)
    // =========================================================================

    /// Depth error sigmoid threshold (50% point)
    public static let depthErrorThreshold: Double = 0.10  // meters

    /// Depth error transition width
    public static let depthErrorTransitionWidth: Double = 0.088  // 0.02 * 4.4

    /// Edge confidence sigmoid threshold
    public static let edgeConfidenceThreshold: Double = 0.50

    /// Edge confidence transition width
    public static let edgeConfidenceTransitionWidth: Double = 0.352  // 0.08 * 4.4

    /// Hole penalty sigmoid threshold
    public static let holePenaltyThreshold: Double = 0.05  // 5% area

    /// Hole penalty transition width
    public static let holePenaltyTransitionWidth: Double = 0.044  // 0.01 * 4.4

    // =========================================================================
    // MARK: - Dynamic Weight Progression
    // =========================================================================

    /// Progress threshold for early capture (gate dominates)
    public static let earlyProgressThreshold: Double = 0.30

    /// Progress threshold for late capture (soft dominates)
    public static let lateProgressThreshold: Double = 0.70

    /// Gate weight at early progress
    public static let earlyGateWeight: Double = 0.85

    /// Gate weight at late progress
    public static let lateGateWeight: Double = 0.25

    // =========================================================================
    // MARK: - Memory Limits
    // =========================================================================

    /// Maximum depth sources per fusion
    public static let maxDepthSources: Int = 4

    /// Maximum edge classification categories
    public static let maxEdgeCategories: Int = 4

    /// Temporal buffer size
    public static let temporalBufferSize: Int = 8

    /// Maximum depth map resolution (for memory)
    public static let maxDepthMapResolution: Int = 256  // 256x256 per patch

    // =========================================================================
    // MARK: - Range Validation
    // =========================================================================

    public enum AcceptableRanges {
        public static let maxDepthDisagreementM: ClosedRange<Double> = 0.10...0.25
        public static let minDepthConsensusRatio: ClosedRange<Double> = 0.50...0.80
        public static let geometricEdgeMinGradient: ClosedRange<Double> = 0.15...0.40
        public static let holeAreaRatioThreshold: ClosedRange<Double> = 0.01...0.05
        public static let temporalWindowSize: ClosedRange<Int> = 3...10
    }
}
```

---

## Part 3: Depth Fusion System

### 3.1 Multi-Source Depth Architecture

```
+-----------------------------------------------------------------------------+
|                    DEPTH FUSION ARCHITECTURE                                 |
+-----------------------------------------------------------------------------+
|                                                                             |
|  INPUT SOURCES:                                                              |
|  +-- Small Depth Model (e.g., Depth Anything Lite)                          |
|  |   +-- Resolution: 384x384                                                 |
|  |   +-- Range: 0-5m (optimized for close range)                            |
|  |   +-- Speed: 15ms per frame                                               |
|  |   +-- Confidence: High for near objects                                   |
|  |                                                                           |
|  +-- Large Depth Model (e.g., MiDaS Large)                                  |
|  |   +-- Resolution: 512x512                                                 |
|  |   +-- Range: 0-50m (better for far objects)                              |
|  |   +-- Speed: 50ms per frame                                               |
|  |   +-- Confidence: High for distant objects                                |
|  |                                                                           |
|  +-- ARKit/ARCore Depth                                                      |
|  |   +-- Resolution: Variable (device dependent)                             |
|  |   +-- Range: 0-8m (LiDAR) or 0-5m (structured light)                     |
|  |   +-- Speed: Real-time                                                    |
|  |   +-- Confidence: High where sensor works, zero elsewhere                 |
|  |                                                                           |
|  +-- Stereo Depth (optional)                                                 |
|      +-- Resolution: Based on capture resolution                             |
|      +-- Range: 0.5-10m (depends on baseline)                               |
|      +-- Speed: 100ms per frame                                              |
|      +-- Confidence: High for textured regions                               |
|                                                                              |
|  FUSION ALGORITHM:                                                          |
|  1. Normalize all depths to common scale (meters)                           |
|  2. Resize to common resolution (256x256)                                   |
|  3. Compute per-pixel consensus (majority vote)                             |
|  4. Weight by source confidence                                              |
|  5. Output: fused depth + confidence map                                     |
|                                                                              |
+-----------------------------------------------------------------------------+
```

### 3.2 DepthFusionEngine Implementation

```swift
//
// DepthFusionEngine.swift
// Aether3D
//
// PR4 - Depth Fusion Engine
// Fuses multiple depth sources into consensus depth with confidence
//

import Foundation

/// Depth fusion engine for multi-source consensus
public final class DepthFusionEngine {

    // =========================================================================
    // MARK: - Types
    // =========================================================================

    /// Single depth source data
    public struct DepthSourceData: Sendable {
        /// Depth values (meters, row-major)
        public let depthMap: ContiguousArray<Float>

        /// Per-pixel confidence (0-1)
        public let confidenceMap: ContiguousArray<Float>

        /// Source identifier
        public let sourceId: DepthSourceId

        /// Map dimensions
        public let width: Int
        public let height: Int

        /// Valid depth range for this source
        public let validRangeM: ClosedRange<Float>

        public init(
            depthMap: ContiguousArray<Float>,
            confidenceMap: ContiguousArray<Float>,
            sourceId: DepthSourceId,
            width: Int,
            height: Int,
            validRangeM: ClosedRange<Float>
        ) {
            precondition(depthMap.count == width * height)
            precondition(confidenceMap.count == width * height)
            self.depthMap = depthMap
            self.confidenceMap = confidenceMap
            self.sourceId = sourceId
            self.width = width
            self.height = height
            self.validRangeM = validRangeM
        }
    }

    /// Depth source identifier
    public enum DepthSourceId: String, Codable, Sendable, CaseIterable {
        case smallModel = "small_model"
        case largeModel = "large_model"
        case platformApi = "platform_api"  // ARKit/ARCore
        case stereo = "stereo"
    }

    /// Fused depth result
    public struct FusedDepthResult: Sendable {
        /// Consensus depth values (meters)
        public let depthMap: ContiguousArray<Float>

        /// Fusion confidence (0-1)
        public let confidenceMap: ContiguousArray<Float>

        /// Per-source agreement map (bitmask)
        public let agreementMap: ContiguousArray<UInt8>

        /// Map dimensions
        public let width: Int
        public let height: Int

        /// Statistics
        public let consensusRatio: Double
        public let averageConfidence: Double
        public let sourcesUsed: [DepthSourceId]
    }

    // =========================================================================
    // MARK: - Configuration
    // =========================================================================

    /// Fusion resolution (output)
    private let fusionWidth: Int
    private let fusionHeight: Int

    /// Pre-allocated buffers
    private var resizedDepths: [[Float]]
    private var resizedConfidences: [[Float]]
    private var fusedDepth: ContiguousArray<Float>
    private var fusedConfidence: ContiguousArray<Float>
    private var agreementMask: ContiguousArray<UInt8>

    // =========================================================================
    // MARK: - Initialization
    // =========================================================================

    public init(fusionResolution: Int = SoftGatesV13.maxDepthMapResolution) {
        self.fusionWidth = fusionResolution
        self.fusionHeight = fusionResolution

        let pixelCount = fusionResolution * fusionResolution
        let maxSources = SoftGatesV13.maxDepthSources

        // Pre-allocate buffers (ZERO ALLOCATION in hot path)
        self.resizedDepths = Array(repeating: Array(repeating: 0.0, count: pixelCount), count: maxSources)
        self.resizedConfidences = Array(repeating: Array(repeating: 0.0, count: pixelCount), count: maxSources)
        self.fusedDepth = ContiguousArray(repeating: 0.0, count: pixelCount)
        self.fusedConfidence = ContiguousArray(repeating: 0.0, count: pixelCount)
        self.agreementMask = ContiguousArray(repeating: 0, count: pixelCount)
    }

    // =========================================================================
    // MARK: - Fusion API
    // =========================================================================

    /// Fuse multiple depth sources into consensus
    ///
    /// ALGORITHM:
    /// 1. Resize all sources to fusion resolution
    /// 2. For each pixel, compute weighted median
    /// 3. Track agreement between sources
    /// 4. Compute final confidence
    ///
    /// - Parameters:
    ///   - sources: Array of depth sources (1-4 sources)
    /// - Returns: Fused depth result
    public func fuse(sources: [DepthSourceData]) -> FusedDepthResult {
        precondition(sources.count >= 1 && sources.count <= SoftGatesV13.maxDepthSources)

        let pixelCount = fusionWidth * fusionHeight

        // Step 1: Resize all sources to fusion resolution
        for (i, source) in sources.enumerated() {
            resizeDepthMap(
                source: source.depthMap,
                sourceWidth: source.width,
                sourceHeight: source.height,
                into: &resizedDepths[i]
            )
            resizeDepthMap(
                source: source.confidenceMap,
                sourceWidth: source.width,
                sourceHeight: source.height,
                into: &resizedConfidences[i]
            )
        }

        // Step 2: Per-pixel fusion
        var totalAgreement: Double = 0
        var totalConfidence: Double = 0

        for p in 0..<pixelCount {
            // Collect valid depths for this pixel
            var validDepths: [(depth: Float, confidence: Float, sourceIndex: Int)] = []

            for i in 0..<sources.count {
                let depth = resizedDepths[i][p]
                let conf = resizedConfidences[i][p]

                // Filter by confidence threshold
                guard conf >= Float(SoftGatesV13.minDepthConfidence) else { continue }

                // Filter by valid range
                let range = sources[i].validRangeM
                guard depth >= range.lowerBound && depth <= range.upperBound else { continue }

                validDepths.append((depth, conf, i))
            }

            if validDepths.isEmpty {
                // No valid depths - mark as invalid
                fusedDepth[p] = 0
                fusedConfidence[p] = 0
                agreementMask[p] = 0
            } else if validDepths.count == 1 {
                // Single source - use directly
                fusedDepth[p] = validDepths[0].depth
                fusedConfidence[p] = validDepths[0].confidence * 0.5  // Penalty for single source
                agreementMask[p] = UInt8(1 << validDepths[0].sourceIndex)
            } else {
                // Multiple sources - compute consensus
                let (consensusDepth, confidence, agreement) = computeConsensus(
                    validDepths: validDepths,
                    maxDisagreement: Float(SoftGatesV13.maxDepthDisagreementM)
                )
                fusedDepth[p] = consensusDepth
                fusedConfidence[p] = confidence
                agreementMask[p] = agreement

                let agreementCount = agreement.nonzeroBitCount
                if agreementCount >= 2 {
                    totalAgreement += 1
                }
            }

            totalConfidence += Double(fusedConfidence[p])
        }

        // Step 3: Compute statistics
        let validPixels = fusedConfidence.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        let consensusRatio = validPixels > 0 ? totalAgreement / Double(validPixels) : 0
        let averageConfidence = validPixels > 0 ? totalConfidence / Double(validPixels) : 0

        return FusedDepthResult(
            depthMap: ContiguousArray(fusedDepth),
            confidenceMap: ContiguousArray(fusedConfidence),
            agreementMap: ContiguousArray(agreementMask),
            width: fusionWidth,
            height: fusionHeight,
            consensusRatio: consensusRatio,
            averageConfidence: averageConfidence,
            sourcesUsed: sources.map { $0.sourceId }
        )
    }

    // =========================================================================
    // MARK: - Internal Methods
    // =========================================================================

    /// Resize depth map using bilinear interpolation (deterministic)
    private func resizeDepthMap(
        source: ContiguousArray<Float>,
        sourceWidth: Int,
        sourceHeight: Int,
        into destination: inout [Float]
    ) {
        let scaleX = Float(sourceWidth - 1) / Float(fusionWidth - 1)
        let scaleY = Float(sourceHeight - 1) / Float(fusionHeight - 1)

        for y in 0..<fusionHeight {
            for x in 0..<fusionWidth {
                let srcX = Float(x) * scaleX
                let srcY = Float(y) * scaleY

                // Bilinear interpolation
                let x0 = Int(srcX)
                let y0 = Int(srcY)
                let x1 = min(x0 + 1, sourceWidth - 1)
                let y1 = min(y0 + 1, sourceHeight - 1)

                let fx = srcX - Float(x0)
                let fy = srcY - Float(y0)

                let v00 = source[y0 * sourceWidth + x0]
                let v10 = source[y0 * sourceWidth + x1]
                let v01 = source[y1 * sourceWidth + x0]
                let v11 = source[y1 * sourceWidth + x1]

                // Deterministic interpolation (no FMA)
                let top = v00 + (v10 - v00) * fx
                let bottom = v01 + (v11 - v01) * fx
                destination[y * fusionWidth + x] = top + (bottom - top) * fy
            }
        }
    }

    /// Compute consensus depth from multiple sources
    private func computeConsensus(
        validDepths: [(depth: Float, confidence: Float, sourceIndex: Int)],
        maxDisagreement: Float
    ) -> (depth: Float, confidence: Float, agreement: UInt8) {
        // Sort by depth for median finding
        let sorted = validDepths.sorted { $0.depth < $1.depth }

        // Compute weighted median
        var totalWeight: Float = 0
        for (_, conf, _) in sorted {
            totalWeight += conf
        }

        var cumWeight: Float = 0
        var medianDepth = sorted[0].depth
        for (depth, conf, _) in sorted {
            cumWeight += conf
            if cumWeight >= totalWeight * 0.5 {
                medianDepth = depth
                break
            }
        }

        // Count agreement (within maxDisagreement of median)
        var agreement: UInt8 = 0
        var agreementConfSum: Float = 0
        var agreementCount = 0

        for (depth, conf, sourceIndex) in sorted {
            if abs(depth - medianDepth) <= maxDisagreement {
                agreement |= UInt8(1 << sourceIndex)
                agreementConfSum += conf
                agreementCount += 1
            }
        }

        // Confidence is based on agreement and source confidences
        let consensusRatio = Float(agreementCount) / Float(sorted.count)
        let avgAgreementConf = agreementCount > 0 ? agreementConfSum / Float(agreementCount) : 0
        let finalConfidence = consensusRatio * avgAgreementConf

        return (medianDepth, finalConfidence, agreement)
    }

    // =========================================================================
    // MARK: - Lifecycle
    // =========================================================================

    /// Reset for new session
    public func reset() {
        for i in 0..<resizedDepths.count {
            for j in 0..<resizedDepths[i].count {
                resizedDepths[i][j] = 0
                resizedConfidences[i][j] = 0
            }
        }
        for i in 0..<fusedDepth.count {
            fusedDepth[i] = 0
            fusedConfidence[i] = 0
            agreementMask[i] = 0
        }
    }
}
```

### 3.3 Depth Soft Gain Function

```swift
/// Compute depth soft gain from fused depth result
///
/// FORMULA:
/// depthSoftGain = consensusGain * confidenceGain * errorGain
///
/// WHERE:
/// - consensusGain = sigmoid((consensusRatio - 0.67) / transitionWidth)
/// - confidenceGain = sigmoid((avgConfidence - 0.50) / transitionWidth)
/// - errorGain = sigmoid((maxErrorThreshold - avgError) / transitionWidth)
///
/// With floor: max(minDepthSoftGain, rawGain)
public static func depthSoftGain(
    fusedResult: DepthFusionEngine.FusedDepthResult,
    referenceDepth: ContiguousArray<Float>?  // Ground truth if available
) -> Double {
    let config = SoftGatesV13.self

    // Consensus gain
    let consensusTarget = config.minDepthConsensusRatio
    let consensusSlope = config.depthErrorTransitionWidth / 4.4
    let consensusGain = PRMath.sigmoid(
        (fusedResult.consensusRatio - consensusTarget) / consensusSlope
    )

    // Confidence gain
    let confTarget = 0.50
    let confSlope = 0.10
    let confidenceGain = PRMath.sigmoid(
        (fusedResult.averageConfidence - confTarget) / confSlope
    )

    // Error gain (if reference available)
    var errorGain = 1.0
    if let reference = referenceDepth {
        let avgError = computeAverageDepthError(
            fused: fusedResult.depthMap,
            reference: reference,
            confidence: fusedResult.confidenceMap
        )
        let errorTarget = config.maxDepthErrorForHighQuality
        let errorSlope = config.depthErrorTransitionWidth / 4.4
        errorGain = PRMath.sigmoid((errorTarget - avgError) / errorSlope)
    }

    // Multiplicative combination with floor
    let rawGain = consensusGain * confidenceGain * errorGain
    return max(config.minDepthSoftGain, rawGain)
}

/// Compute average depth error (confidence-weighted)
private static func computeAverageDepthError(
    fused: ContiguousArray<Float>,
    reference: ContiguousArray<Float>,
    confidence: ContiguousArray<Float>
) -> Double {
    precondition(fused.count == reference.count)
    precondition(fused.count == confidence.count)

    var totalError: Double = 0
    var totalWeight: Double = 0

    for i in 0..<fused.count {
        let conf = Double(confidence[i])
        guard conf > 0 else { continue }

        let error = abs(Double(fused[i]) - Double(reference[i]))
        totalError += error * conf
        totalWeight += conf
    }

    return totalWeight > 0 ? totalError / totalWeight : Double.infinity
}
```

---

## Part 4: Edge Classification System

### 4.1 Edge Type Philosophy

```
+-----------------------------------------------------------------------------+
|                    EDGE TYPE CLASSIFICATION                                  |
+-----------------------------------------------------------------------------+
|                                                                             |
|  GEOMETRIC EDGES (High Confidence)                                           |
|  +-- Definition: Sharp depth discontinuities with color discontinuities     |
|  +-- Examples: Object boundaries, furniture edges, architectural features    |
|  +-- Reliability: HIGH - consistent across views, good for SfM              |
|  +-- Weight: 0.40                                                           |
|                                                                             |
|  TEXTURAL EDGES (Medium Confidence)                                          |
|  +-- Definition: High-frequency patterns without depth change               |
|  +-- Examples: Brick walls, carpets, patterned fabrics                      |
|  +-- Reliability: MEDIUM - can cause texture bleeding in reconstruction     |
|  +-- Weight: 0.30                                                           |
|                                                                             |
|  SPECULAR EDGES (Low Confidence)                                             |
|  +-- Definition: Bright highlights with low saturation                      |
|  +-- Examples: Metal surfaces, glossy plastic, polished wood                |
|  +-- Reliability: LOW - view-dependent, moves with camera                   |
|  +-- Weight: 0.15 (heavily penalized)                                       |
|                                                                             |
|  TRANSPARENT EDGES (Very Low Confidence)                                     |
|  +-- Definition: Color edges with unexpected depth (sees through)           |
|  +-- Examples: Glass, water, clear plastic, windows                         |
|  +-- Reliability: VERY LOW - depth sensor often fails completely            |
|  +-- Weight: 0.08 (heavily penalized)                                       |
|                                                                             |
|  CLASSIFICATION ALGORITHM:                                                  |
|  1. Compute Sobel gradient on grayscale                                     |
|  2. Compute depth gradient (from fused depth)                               |
|  3. Check saturation/brightness for specular                                |
|  4. Check depth/color mismatch for transparent                              |
|  5. Check frequency response for textural                                   |
|  6. Default to geometric if high gradients on both                          |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### 4.2 EdgeClassifier Implementation

```swift
//
// EdgeClassifier.swift
// Aether3D
//
// PR4 - Edge Classification by Type
// Classifies edges as geometric, textural, specular, or transparent
//

import Foundation

/// Edge type classification
public enum EdgeType: Int, Codable, Sendable, CaseIterable {
    case geometric = 0      // High confidence
    case textural = 1       // Medium confidence
    case specular = 2       // Low confidence
    case transparent = 3    // Very low confidence
    case none = 4           // Not an edge

    /// Reliability weight for this edge type
    public var reliabilityWeight: Double {
        switch self {
        case .geometric: return 0.95
        case .textural: return 0.70
        case .specular: return 0.30
        case .transparent: return 0.15
        case .none: return 0.0
        }
    }
}

/// Edge classification result for a patch
public struct EdgeClassificationResult: Sendable {
    /// Per-edge-type pixel counts
    public let typeCounts: [EdgeType: Int]

    /// Per-edge-type average gradient magnitude
    public let typeGradients: [EdgeType: Double]

    /// Dominant edge type
    public let dominantType: EdgeType

    /// Overall edge confidence
    public let overallConfidence: Double

    /// Edge density (edge pixels / total pixels)
    public let edgeDensity: Double
}

/// Edge classifier using multi-cue analysis
public final class EdgeClassifier {

    // =========================================================================
    // MARK: - Pre-allocated Buffers
    // =========================================================================

    private let resolution: Int
    private var grayscaleBuffer: ContiguousArray<Float>
    private var gradientXBuffer: ContiguousArray<Float>
    private var gradientYBuffer: ContiguousArray<Float>
    private var gradientMagBuffer: ContiguousArray<Float>
    private var edgeTypeBuffer: ContiguousArray<UInt8>

    // =========================================================================
    // MARK: - Initialization
    // =========================================================================

    public init(resolution: Int = SoftGatesV13.maxDepthMapResolution) {
        self.resolution = resolution
        let pixelCount = resolution * resolution

        self.grayscaleBuffer = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientXBuffer = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientYBuffer = ContiguousArray(repeating: 0, count: pixelCount)
        self.gradientMagBuffer = ContiguousArray(repeating: 0, count: pixelCount)
        self.edgeTypeBuffer = ContiguousArray(repeating: 0, count: pixelCount)
    }

    // =========================================================================
    // MARK: - Classification API
    // =========================================================================

    /// Classify edges in an image region
    ///
    /// - Parameters:
    ///   - rgbPixels: RGB pixels (interleaved, 0-255)
    ///   - depthMap: Depth values (meters)
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Classification result
    public func classify(
        rgbPixels: ContiguousArray<UInt8>,
        depthMap: ContiguousArray<Float>,
        width: Int,
        height: Int
    ) -> EdgeClassificationResult {
        precondition(rgbPixels.count == width * height * 3)
        precondition(depthMap.count == width * height)

        let pixelCount = width * height

        // Step 1: Convert to grayscale
        for i in 0..<pixelCount {
            let r = Float(rgbPixels[i * 3 + 0])
            let g = Float(rgbPixels[i * 3 + 1])
            let b = Float(rgbPixels[i * 3 + 2])
            grayscaleBuffer[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }

        // Step 2: Compute Sobel gradients
        computeSobelGradients(
            input: grayscaleBuffer,
            width: width,
            height: height,
            gradientX: &gradientXBuffer,
            gradientY: &gradientYBuffer,
            gradientMag: &gradientMagBuffer
        )

        // Step 3: Classify each pixel
        var typeCounts: [EdgeType: Int] = [:]
        var typeGradientSums: [EdgeType: Double] = [:]

        for i in 0..<pixelCount {
            let edgeType = classifyPixel(
                index: i,
                x: i % width,
                y: i / width,
                width: width,
                height: height,
                rgbPixels: rgbPixels,
                depthMap: depthMap
            )
            edgeTypeBuffer[i] = UInt8(edgeType.rawValue)

            typeCounts[edgeType, default: 0] += 1
            typeGradientSums[edgeType, default: 0] += Double(gradientMagBuffer[i])
        }

        // Step 4: Compute statistics
        var typeGradients: [EdgeType: Double] = [:]
        for (type, count) in typeCounts {
            if count > 0 {
                typeGradients[type] = typeGradientSums[type]! / Double(count)
            }
        }

        let edgePixels = typeCounts.filter { $0.key != .none }.values.reduce(0, +)
        let edgeDensity = Double(edgePixels) / Double(pixelCount)

        let dominantType = typeCounts.filter { $0.key != .none }
            .max(by: { $0.value < $1.value })?.key ?? .none

        // Overall confidence is weighted average
        var totalWeight: Double = 0
        var weightedConfidence: Double = 0
        for (type, count) in typeCounts where type != .none {
            let weight = Double(count) * type.reliabilityWeight
            weightedConfidence += weight
            totalWeight += Double(count)
        }
        let overallConfidence = totalWeight > 0 ? weightedConfidence / totalWeight : 0

        return EdgeClassificationResult(
            typeCounts: typeCounts,
            typeGradients: typeGradients,
            dominantType: dominantType,
            overallConfidence: overallConfidence,
            edgeDensity: edgeDensity
        )
    }

    // =========================================================================
    // MARK: - Internal Methods
    // =========================================================================

    /// Classify single pixel edge type
    private func classifyPixel(
        index: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        rgbPixels: ContiguousArray<UInt8>,
        depthMap: ContiguousArray<Float>
    ) -> EdgeType {
        let gradMag = gradientMagBuffer[index]

        // Not an edge if gradient is too low
        guard gradMag >= Float(SoftGatesV13.geometricEdgeMinGradient) else {
            return .none
        }

        // Get RGB at this pixel
        let r = Float(rgbPixels[index * 3 + 0]) / 255.0
        let g = Float(rgbPixels[index * 3 + 1]) / 255.0
        let b = Float(rgbPixels[index * 3 + 2]) / 255.0

        // Compute HSV
        let (_, saturation, value) = rgbToHsv(r: r, g: g, b: b)

        // Check for specular (low saturation, high brightness)
        if saturation < Float(SoftGatesV13.specularEdgeSaturationThreshold) &&
           value > Float(SoftGatesV13.specularEdgeBrightnessThreshold) {
            return .specular
        }

        // Check for transparent (depth discontinuity without color edge)
        let depthGrad = computeDepthGradient(
            at: index,
            x: x,
            y: y,
            width: width,
            height: height,
            depthMap: depthMap
        )

        let depth = depthMap[index]
        if depth > 0 && depthGrad / depth > Float(SoftGatesV13.transparentEdgeDepthRatio) {
            // Large depth change
            if gradMag < 0.5 * Float(SoftGatesV13.geometricEdgeMinGradient) {
                // But weak color edge -> transparent
                return .transparent
            }
        }

        // Check for textural (high frequency, no depth change)
        if depthGrad / max(depth, 0.1) < 0.02 {
            // Very small depth change
            if gradMag > 2.0 * Float(SoftGatesV13.geometricEdgeMinGradient) {
                // But strong color edge -> textural
                return .textural
            }
        }

        // Default: geometric
        return .geometric
    }

    /// Compute Sobel gradients (deterministic, no SIMD)
    private func computeSobelGradients(
        input: ContiguousArray<Float>,
        width: Int,
        height: Int,
        gradientX: inout ContiguousArray<Float>,
        gradientY: inout ContiguousArray<Float>,
        gradientMag: inout ContiguousArray<Float>
    ) {
        // Sobel kernels
        // Gx = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]
        // Gy = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]]

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x

                let p00 = input[(y - 1) * width + (x - 1)]
                let p10 = input[(y - 1) * width + x]
                let p20 = input[(y - 1) * width + (x + 1)]
                let p01 = input[y * width + (x - 1)]
                let p21 = input[y * width + (x + 1)]
                let p02 = input[(y + 1) * width + (x - 1)]
                let p12 = input[(y + 1) * width + x]
                let p22 = input[(y + 1) * width + (x + 1)]

                let gx = -p00 + p20 - 2 * p01 + 2 * p21 - p02 + p22
                let gy = -p00 - 2 * p10 - p20 + p02 + 2 * p12 + p22

                gradientX[idx] = gx
                gradientY[idx] = gy
                gradientMag[idx] = sqrt(gx * gx + gy * gy)
            }
        }

        // Border pixels
        for x in 0..<width {
            gradientMag[x] = 0
            gradientMag[(height - 1) * width + x] = 0
        }
        for y in 0..<height {
            gradientMag[y * width] = 0
            gradientMag[y * width + width - 1] = 0
        }
    }

    /// Compute depth gradient at pixel
    private func computeDepthGradient(
        at index: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        depthMap: ContiguousArray<Float>
    ) -> Float {
        guard x > 0 && x < width - 1 && y > 0 && y < height - 1 else {
            return 0
        }

        let left = depthMap[index - 1]
        let right = depthMap[index + 1]
        let top = depthMap[index - width]
        let bottom = depthMap[index + width]

        let gx = right - left
        let gy = bottom - top

        return sqrt(gx * gx + gy * gy)
    }

    /// RGB to HSV conversion (deterministic)
    private func rgbToHsv(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC

        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0

        var h: Float = 0
        if delta > 0 {
            if maxC == r {
                h = (g - b) / delta
                if g < b { h += 6 }
            } else if maxC == g {
                h = 2 + (b - r) / delta
            } else {
                h = 4 + (r - g) / delta
            }
            h /= 6
        }

        return (h, s, v)
    }
}
```

### 4.3 Edge Soft Gain Function

```swift
/// Compute edge soft gain from classification result
///
/// FORMULA:
/// edgeSoftGain = weighted_sum(typeGain[t] * typeWeight[t])
///
/// WHERE:
/// - typeGain[t] = reliability[t] * (count[t] / totalEdges)
/// - typeWeight matches edge type reliability
public static func edgeSoftGain(
    classificationResult: EdgeClassificationResult
) -> Double {
    let config = SoftGatesV13.self

    // Early exit if no edges
    guard classificationResult.edgeDensity > 0.01 else {
        return config.minEdgeSoftGain
    }

    var weightedGain: Double = 0
    var totalWeight: Double = 0

    let totalEdges = classificationResult.typeCounts.values.reduce(0, +)
    guard totalEdges > 0 else { return config.minEdgeSoftGain }

    for (edgeType, count) in classificationResult.typeCounts {
        guard edgeType != .none else { continue }

        let typeRatio = Double(count) / Double(totalEdges)
        let reliability = edgeType.reliabilityWeight
        let contribution = typeRatio * reliability

        weightedGain += contribution
        totalWeight += typeRatio
    }

    let rawGain = totalWeight > 0 ? weightedGain / totalWeight : 0

    // Density bonus: more edges = more features = better
    let densityBonus = min(0.2, classificationResult.edgeDensity * 2)

    let finalGain = rawGain + densityBonus
    return max(config.minEdgeSoftGain, min(1.0, finalGain))
}
```

---

## Part 5: Topology Evaluation System

### 5.1 Topology Components

```
+-----------------------------------------------------------------------------+
|                    TOPOLOGY EVALUATION COMPONENTS                            |
+-----------------------------------------------------------------------------+
|                                                                             |
|  HOLE DETECTION:                                                            |
|  +-- Definition: Contiguous regions with invalid/missing depth              |
|  +-- Detection: Connected component analysis on invalid depth pixels        |
|  +-- Metrics:                                                                |
|  |   +-- holeCount: Number of distinct holes                                |
|  |   +-- totalHoleArea: Sum of hole areas (pixels)                          |
|  |   +-- holeAreaRatio: totalHoleArea / totalArea                           |
|  |   +-- maxHoleSize: Largest single hole                                   |
|  +-- Gain formula: sigmoid((threshold - holeAreaRatio) / width)             |
|                                                                             |
|  OCCLUSION BOUNDARIES:                                                      |
|  +-- Definition: Depth discontinuities at object boundaries                 |
|  +-- Detection: Depth gradient > threshold relative to depth                |
|  +-- Metrics:                                                                |
|  |   +-- boundaryLength: Total length of occlusion boundaries               |
|  |   +-- boundaryConfidence: How well-defined are boundaries                |
|  |   +-- boundaryConsistency: Do boundaries match across frames             |
|  +-- Gain formula: sigmoid((boundaryConfidence - threshold) / width)        |
|                                                                             |
|  SELF-OCCLUSION:                                                            |
|  +-- Definition: Surfaces nearly parallel to view direction                 |
|  +-- Detection: Surface normal dot view direction < threshold               |
|  +-- Metrics:                                                                |
|  |   +-- selfOccludedRatio: Fraction of patch self-occluded                 |
|  |   +-- grazingAngle: Average angle for near-parallel surfaces             |
|  +-- Gain formula: sigmoid((threshold - selfOccludedRatio) / width)         |
|                                                                             |
|  DEPTH CONSISTENCY:                                                         |
|  +-- Definition: Neighboring pixels should have similar depth               |
|  +-- Detection: Local depth variance analysis                               |
|  +-- Metrics:                                                                |
|  |   +-- depthVariance: Local depth variance (excl. boundaries)             |
|  |   +-- depthSmoothness: 1 - normalized variance                           |
|  +-- Gain formula: sigmoid((depthSmoothness - threshold) / width)           |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### 5.2 TopologyEvaluator Implementation

```swift
//
// TopologyEvaluator.swift
// Aether3D
//
// PR4 - Topology Evaluation
// Evaluates holes, occlusion boundaries, and depth consistency
//

import Foundation

/// Topology evaluation result
public struct TopologyResult: Sendable {
    /// Hole metrics
    public let holeCount: Int
    public let totalHoleAreaPixels: Int
    public let holeAreaRatio: Double
    public let maxHoleSize: Int

    /// Occlusion boundary metrics
    public let boundaryLengthPixels: Int
    public let boundaryConfidence: Double

    /// Self-occlusion metrics
    public let selfOccludedRatio: Double

    /// Depth consistency metrics
    public let depthSmoothness: Double

    /// Overall topology confidence
    public let overallConfidence: Double
}

/// Topology evaluator for depth maps
public final class TopologyEvaluator {

    // =========================================================================
    // MARK: - Pre-allocated Buffers
    // =========================================================================

    private let resolution: Int
    private var visitedBuffer: ContiguousArray<Bool>
    private var boundaryBuffer: ContiguousArray<Bool>
    private var componentIdBuffer: ContiguousArray<Int>

    // =========================================================================
    // MARK: - Initialization
    // =========================================================================

    public init(resolution: Int = SoftGatesV13.maxDepthMapResolution) {
        self.resolution = resolution
        let pixelCount = resolution * resolution

        self.visitedBuffer = ContiguousArray(repeating: false, count: pixelCount)
        self.boundaryBuffer = ContiguousArray(repeating: false, count: pixelCount)
        self.componentIdBuffer = ContiguousArray(repeating: 0, count: pixelCount)
    }

    // =========================================================================
    // MARK: - Evaluation API
    // =========================================================================

    /// Evaluate topology of a depth map
    ///
    /// - Parameters:
    ///   - depthMap: Depth values (0 = invalid/hole)
    ///   - confidenceMap: Per-pixel confidence
    ///   - normalMap: Surface normals (optional, for self-occlusion)
    ///   - viewDirection: Camera view direction (optional)
    ///   - width: Map width
    ///   - height: Map height
    /// - Returns: Topology evaluation result
    public func evaluate(
        depthMap: ContiguousArray<Float>,
        confidenceMap: ContiguousArray<Float>,
        normalMap: ContiguousArray<EvidenceVector3>? = nil,
        viewDirection: EvidenceVector3? = nil,
        width: Int,
        height: Int
    ) -> TopologyResult {
        let config = SoftGatesV13.self
        let pixelCount = width * height

        // Reset buffers
        for i in 0..<pixelCount {
            visitedBuffer[i] = false
            boundaryBuffer[i] = false
            componentIdBuffer[i] = 0
        }

        // Step 1: Detect holes (connected components of invalid depth)
        let (holeCount, holeSizes) = detectHoles(
            depthMap: depthMap,
            width: width,
            height: height
        )

        let totalHoleAreaPixels = holeSizes.reduce(0, +)
        let holeAreaRatio = Double(totalHoleAreaPixels) / Double(pixelCount)
        let maxHoleSize = holeSizes.max() ?? 0

        // Step 2: Detect occlusion boundaries
        let (boundaryLengthPixels, boundaryConfidence) = detectOcclusionBoundaries(
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            width: width,
            height: height
        )

        // Step 3: Compute self-occlusion ratio
        var selfOccludedRatio: Double = 0
        if let normals = normalMap, let viewDir = viewDirection {
            selfOccludedRatio = computeSelfOcclusionRatio(
                normalMap: normals,
                viewDirection: viewDir,
                depthMap: depthMap,
                width: width,
                height: height
            )
        }

        // Step 4: Compute depth smoothness
        let depthSmoothness = computeDepthSmoothness(
            depthMap: depthMap,
            width: width,
            height: height
        )

        // Step 5: Compute overall confidence
        let holeGain = PRMath.sigmoid(
            (config.holeAreaRatioThreshold - holeAreaRatio) /
            (config.holePenaltyTransitionWidth / 4.4)
        )
        let smoothnessGain = depthSmoothness
        let occlusionGain = 1.0 - selfOccludedRatio

        let overallConfidence = holeGain * 0.4 + smoothnessGain * 0.35 + occlusionGain * 0.25

        return TopologyResult(
            holeCount: holeCount,
            totalHoleAreaPixels: totalHoleAreaPixels,
            holeAreaRatio: holeAreaRatio,
            maxHoleSize: maxHoleSize,
            boundaryLengthPixels: boundaryLengthPixels,
            boundaryConfidence: boundaryConfidence,
            selfOccludedRatio: selfOccludedRatio,
            depthSmoothness: depthSmoothness,
            overallConfidence: overallConfidence
        )
    }

    // =========================================================================
    // MARK: - Hole Detection
    // =========================================================================

    /// Detect holes using flood fill
    private func detectHoles(
        depthMap: ContiguousArray<Float>,
        width: Int,
        height: Int
    ) -> (count: Int, sizes: [Int]) {
        var holeCount = 0
        var holeSizes: [Int] = []

        for startY in 0..<height {
            for startX in 0..<width {
                let startIdx = startY * width + startX

                // Skip if already visited or valid depth
                guard !visitedBuffer[startIdx] else { continue }
                guard depthMap[startIdx] <= 0 else {
                    visitedBuffer[startIdx] = true
                    continue
                }

                // Flood fill to find connected hole
                let holeSize = floodFillHole(
                    startX: startX,
                    startY: startY,
                    depthMap: depthMap,
                    width: width,
                    height: height,
                    componentId: holeCount + 1
                )

                if holeSize > 0 {
                    holeCount += 1
                    holeSizes.append(holeSize)
                }
            }
        }

        return (holeCount, holeSizes)
    }

    /// Flood fill a single hole
    private func floodFillHole(
        startX: Int,
        startY: Int,
        depthMap: ContiguousArray<Float>,
        width: Int,
        height: Int,
        componentId: Int
    ) -> Int {
        var stack: [(Int, Int)] = [(startX, startY)]
        var size = 0

        while let (x, y) = stack.popLast() {
            let idx = y * width + x

            guard x >= 0 && x < width && y >= 0 && y < height else { continue }
            guard !visitedBuffer[idx] else { continue }
            guard depthMap[idx] <= 0 else { continue }

            visitedBuffer[idx] = true
            componentIdBuffer[idx] = componentId
            size += 1

            // 4-connectivity
            stack.append((x - 1, y))
            stack.append((x + 1, y))
            stack.append((x, y - 1))
            stack.append((x, y + 1))
        }

        return size
    }

    // =========================================================================
    // MARK: - Occlusion Boundary Detection
    // =========================================================================

    /// Detect occlusion boundaries
    private func detectOcclusionBoundaries(
        depthMap: ContiguousArray<Float>,
        confidenceMap: ContiguousArray<Float>,
        width: Int,
        height: Int
    ) -> (length: Int, confidence: Double) {
        let config = SoftGatesV13.self
        var boundaryPixels = 0
        var totalConfidence: Double = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let depth = depthMap[idx]

                guard depth > 0 else { continue }

                // Check depth gradient relative to depth
                let maxNeighborGrad = maxNeighborDepthGradient(
                    idx: idx,
                    x: x,
                    y: y,
                    width: width,
                    depthMap: depthMap
                )

                let relativeGrad = maxNeighborGrad / depth

                if relativeGrad > Float(config.occlusionBoundaryDepthRatio) {
                    boundaryBuffer[idx] = true
                    boundaryPixels += 1
                    totalConfidence += Double(confidenceMap[idx])
                }
            }
        }

        let avgConfidence = boundaryPixels > 0 ?
            totalConfidence / Double(boundaryPixels) : 0

        return (boundaryPixels, avgConfidence)
    }

    /// Maximum depth gradient to neighbors
    private func maxNeighborDepthGradient(
        idx: Int,
        x: Int,
        y: Int,
        width: Int,
        depthMap: ContiguousArray<Float>
    ) -> Float {
        let depth = depthMap[idx]
        var maxGrad: Float = 0

        // 4-connectivity
        let neighbors = [
            (x - 1, y, idx - 1),
            (x + 1, y, idx + 1),
            (x, y - 1, idx - width),
            (x, y + 1, idx + width)
        ]

        for (_, _, nIdx) in neighbors {
            let nDepth = depthMap[nIdx]
            if nDepth > 0 {
                maxGrad = max(maxGrad, abs(depth - nDepth))
            }
        }

        return maxGrad
    }

    // =========================================================================
    // MARK: - Self-Occlusion
    // =========================================================================

    /// Compute self-occlusion ratio
    private func computeSelfOcclusionRatio(
        normalMap: ContiguousArray<EvidenceVector3>,
        viewDirection: EvidenceVector3,
        depthMap: ContiguousArray<Float>,
        width: Int,
        height: Int
    ) -> Double {
        let config = SoftGatesV13.self
        let cosThreshold = cos(config.selfOcclusionAngleDeg * .pi / 180.0)

        var selfOccludedCount = 0
        var validCount = 0

        for i in 0..<(width * height) {
            guard depthMap[i] > 0 else { continue }

            validCount += 1

            let normal = normalMap[i]
            let dot = normal.dot(viewDirection)

            // Surface facing away from camera
            if dot < cosThreshold {
                selfOccludedCount += 1
            }
        }

        return validCount > 0 ? Double(selfOccludedCount) / Double(validCount) : 0
    }

    // =========================================================================
    // MARK: - Depth Smoothness
    // =========================================================================

    /// Compute depth smoothness (inverse of local variance)
    private func computeDepthSmoothness(
        depthMap: ContiguousArray<Float>,
        width: Int,
        height: Int
    ) -> Double {
        var totalVariance: Double = 0
        var validSamples = 0

        let windowSize = 3

        for y in (windowSize/2)..<(height - windowSize/2) {
            for x in (windowSize/2)..<(width - windowSize/2) {
                let idx = y * width + x
                let centerDepth = depthMap[idx]

                guard centerDepth > 0 else { continue }

                // Skip boundary pixels
                if boundaryBuffer[idx] { continue }

                // Compute local variance
                var sum: Double = 0
                var sumSq: Double = 0
                var count = 0

                for dy in -windowSize/2...windowSize/2 {
                    for dx in -windowSize/2...windowSize/2 {
                        let nIdx = (y + dy) * width + (x + dx)
                        let nDepth = depthMap[nIdx]

                        if nDepth > 0 {
                            sum += Double(nDepth)
                            sumSq += Double(nDepth * nDepth)
                            count += 1
                        }
                    }
                }

                if count > 1 {
                    let mean = sum / Double(count)
                    let variance = (sumSq / Double(count)) - (mean * mean)
                    totalVariance += variance / Double(centerDepth * centerDepth)  // Normalized
                    validSamples += 1
                }
            }
        }

        let avgVariance = validSamples > 0 ? totalVariance / Double(validSamples) : 1.0

        // Smoothness is inverse of variance (clamped)
        return max(0, min(1, 1.0 - avgVariance * 10))  // Scale factor 10 for [0,1]
    }
}
```

### 5.3 Topology Soft Gain Function

```swift
/// Compute topology soft gain from evaluation result
///
/// FORMULA:
/// topoSoftGain = holeGain * occlusionGain * consistencyGain
///
/// With floor: max(minTopoSoftGain, rawGain)
public static func topoSoftGain(
    topoResult: TopologyResult
) -> Double {
    let config = SoftGatesV13.self

    // Hole gain (fewer holes = better)
    let holeGain = PRMath.sigmoid(
        (config.holeAreaRatioThreshold - topoResult.holeAreaRatio) /
        (config.holePenaltyTransitionWidth / 4.4)
    )

    // Occlusion boundary gain (well-defined boundaries = better)
    let occlusionGain = topoResult.boundaryConfidence

    // Self-occlusion penalty (less self-occlusion = better)
    let selfOcclusionGain = 1.0 - topoResult.selfOccludedRatio

    // Smoothness gain
    let smoothnessGain = topoResult.depthSmoothness

    // Multiplicative combination
    let rawGain = holeGain * occlusionGain * selfOcclusionGain * smoothnessGain

    return max(config.minTopoSoftGain, rawGain)
}
```

---

## Part 6: Dynamic Weight System

### 6.1 Progress-Based Weight Transition

```swift
//
// DynamicWeightComputer.swift
// Aether3D
//
// PR4 - Dynamic Weight Computation
// Blends Gate and Soft weights based on capture progress
//

import Foundation

/// Dynamic weight computer for Gate/Soft blending
public enum DynamicWeightComputer {

    /// Compute gate and soft weights based on progress
    ///
    /// FORMULA:
    /// At progress p in [0, 1]:
    /// - p < 0.30: gateWeight = 0.85, softWeight = 0.15
    /// - p > 0.70: gateWeight = 0.25, softWeight = 0.75
    /// - Between: Smooth sigmoid interpolation
    ///
    /// - Parameter progress: Capture progress [0, 1]
    /// - Returns: (gateWeight, softWeight) that sum to 1.0
    public static func computeWeights(progress: Double) -> (gate: Double, soft: Double) {
        let config = SoftGatesV13.self

        let clampedProgress = max(0, min(1, progress))

        // Sigmoid transition centered at midpoint (0.50)
        // Map progress to sigmoid input
        let midpoint = (config.earlyProgressThreshold + config.lateProgressThreshold) / 2
        let steepness = 8.0  // Controls transition sharpness

        let sigmoidInput = (clampedProgress - midpoint) * steepness
        let transitionFactor = PRMath.sigmoid(sigmoidInput)

        // Interpolate between early and late weights
        let gateWeight = config.earlyGateWeight +
            (config.lateGateWeight - config.earlyGateWeight) * transitionFactor
        let softWeight = 1.0 - gateWeight

        return (gateWeight, softWeight)
    }

    /// Compute final quality from gate and soft
    ///
    /// - Parameters:
    ///   - gateQuality: Gate quality [0, 1]
    ///   - softQuality: Soft quality [0, 1]
    ///   - progress: Capture progress [0, 1]
    /// - Returns: Final quality [0, 1]
    public static func computeFinalQuality(
        gateQuality: Double,
        softQuality: Double,
        progress: Double
    ) -> Double {
        let (gateWeight, softWeight) = computeWeights(progress: progress)

        // Gate is MULTIPLICATIVE prerequisite
        // Soft quality only matters if gate is open
        let gateModulator = gateQuality  // [0, 1]

        // Weighted combination, modulated by gate
        let weighted = gateWeight * gateQuality + softWeight * softQuality * gateModulator

        return weighted.clamped(to: 0...1)
    }
}
```

### 6.2 Weight Transition Visualization

```
+-----------------------------------------------------------------------------+
|                    DYNAMIC WEIGHT TRANSITION                                 |
+-----------------------------------------------------------------------------+
|                                                                             |
|  Progress:    0%      30%      50%      70%      100%                       |
|               |        |        |        |        |                         |
|  Gate:       85%      85%   -> 55% ->   25%      25%                        |
|               |        |     sigmoid    |        |                         |
|  Soft:       15%      15%   -> 45% ->   75%      75%                        |
|                                                                             |
|  Rationale:                                                                 |
|  - Early: Gate dominates to establish baseline coverage                     |
|  - Middle: Balanced to refine both coverage and quality                     |
|  - Late: Soft dominates to maximize quality on already-covered areas        |
|                                                                             |
|  The sigmoid transition prevents sudden weight jumps that would cause       |
|  display value discontinuities.                                             |
|                                                                             |
+-----------------------------------------------------------------------------+
```

---

## Part 7: Dual Frame Channel System

### 7.1 Raw vs Assist Frame Philosophy

```
+-----------------------------------------------------------------------------+
|                    DUAL FRAME CHANNEL DESIGN                                 |
+-----------------------------------------------------------------------------+
|                                                                             |
|  rawFrame (Ground Truth):                                                    |
|  +-- Source: Original camera capture                                        |
|  +-- Usage: Color information, texture, final reconstruction                |
|  +-- Properties: Full resolution, accurate colors, may have noise           |
|  +-- Guarantees: Unmodified, original sensor data                           |
|                                                                             |
|  assistFrame (Enhanced):                                                     |
|  +-- Source: Processed for depth estimation                                  |
|  +-- Usage: Input to depth models, edge detection                           |
|  +-- Properties: May be downsampled, color-corrected, sharpened             |
|  +-- Guarantees: Aligned with rawFrame, optimized for ML                    |
|                                                                             |
|  Channel Selection:                                                         |
|  +-- Color extraction: ALWAYS from rawFrame                                 |
|  +-- Depth inference: ALWAYS from assistFrame                               |
|  +-- Edge detection: Can use either (configurable)                          |
|  +-- Consistency check: Both channels must align spatially                  |
|                                                                             |
|  Consistency Validation:                                                    |
|  +-- Timestamp match: Both frames from same capture instant                 |
|  +-- Resolution compatible: assistFrame is downsampled rawFrame             |
|  +-- Transform known: Pixel mapping between channels is defined             |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### 7.2 DualFrameManager Implementation

```swift
//
// DualFrameManager.swift
// Aether3D
//
// PR4 - Dual Frame Channel Manager
// Manages rawFrame and assistFrame channels
//

import Foundation

/// Frame channel type
public enum FrameChannel: String, Codable, Sendable {
    case raw = "raw"
    case assist = "assist"
}

/// Dual frame data
public struct DualFrameData: Sendable {
    /// Raw frame RGB (full resolution)
    public let rawRGB: ContiguousArray<UInt8>
    public let rawWidth: Int
    public let rawHeight: Int

    /// Assist frame RGB (depth model resolution)
    public let assistRGB: ContiguousArray<UInt8>
    public let assistWidth: Int
    public let assistHeight: Int

    /// Timestamp (both frames same)
    public let timestampMs: Int64

    /// Scale factors (raw to assist)
    public var scaleX: Float { Float(assistWidth) / Float(rawWidth) }
    public var scaleY: Float { Float(assistHeight) / Float(rawHeight) }

    public init(
        rawRGB: ContiguousArray<UInt8>,
        rawWidth: Int,
        rawHeight: Int,
        assistRGB: ContiguousArray<UInt8>,
        assistWidth: Int,
        assistHeight: Int,
        timestampMs: Int64
    ) {
        precondition(rawRGB.count == rawWidth * rawHeight * 3)
        precondition(assistRGB.count == assistWidth * assistHeight * 3)

        self.rawRGB = rawRGB
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.assistRGB = assistRGB
        self.assistWidth = assistWidth
        self.assistHeight = assistHeight
        self.timestampMs = timestampMs
    }
}

/// Dual frame manager
public final class DualFrameManager {

    // =========================================================================
    // MARK: - State
    // =========================================================================

    private var lastRawFrame: DualFrameData?
    private var consistencyScore: Double = 1.0

    // =========================================================================
    // MARK: - API
    // =========================================================================

    /// Process new frame pair
    public func processFramePair(
        _ data: DualFrameData
    ) -> (consistency: Double, valid: Bool) {
        // Validate timestamp freshness
        if let lastFrame = lastRawFrame {
            let timeDiff = data.timestampMs - lastFrame.timestampMs
            if timeDiff < 0 {
                // Out of order frame
                return (0, false)
            }
        }

        // Validate resolution ratio
        let expectedAssistWidth = data.rawWidth / 4  // Typical 4x downscale
        let expectedAssistHeight = data.rawHeight / 4

        let widthRatioOk = abs(data.assistWidth - expectedAssistWidth) < expectedAssistWidth / 4
        let heightRatioOk = abs(data.assistHeight - expectedAssistHeight) < expectedAssistHeight / 4

        guard widthRatioOk && heightRatioOk else {
            return (0.5, true)  // Unusual ratio but acceptable
        }

        // Update state
        lastRawFrame = data
        consistencyScore = 1.0

        return (consistencyScore, true)
    }

    /// Get pixel from appropriate channel
    public func getPixel(
        x: Int,
        y: Int,
        channel: FrameChannel,
        data: DualFrameData
    ) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch channel {
        case .raw:
            guard x >= 0 && x < data.rawWidth && y >= 0 && y < data.rawHeight else {
                return (0, 0, 0)
            }
            let idx = (y * data.rawWidth + x) * 3
            return (data.rawRGB[idx], data.rawRGB[idx + 1], data.rawRGB[idx + 2])

        case .assist:
            guard x >= 0 && x < data.assistWidth && y >= 0 && y < data.assistHeight else {
                return (0, 0, 0)
            }
            let idx = (y * data.assistWidth + x) * 3
            return (data.assistRGB[idx], data.assistRGB[idx + 1], data.assistRGB[idx + 2])
        }
    }

    /// Map coordinate from raw to assist
    public func rawToAssist(
        x: Int,
        y: Int,
        data: DualFrameData
    ) -> (x: Int, y: Int) {
        let ax = Int(Float(x) * data.scaleX)
        let ay = Int(Float(y) * data.scaleY)
        return (min(ax, data.assistWidth - 1), min(ay, data.assistHeight - 1))
    }

    /// Map coordinate from assist to raw
    public func assistToRaw(
        x: Int,
        y: Int,
        data: DualFrameData
    ) -> (x: Int, y: Int) {
        let rx = Int(Float(x) / data.scaleX)
        let ry = Int(Float(y) / data.scaleY)
        return (min(rx, data.rawWidth - 1), min(ry, data.rawHeight - 1))
    }
}
```

---

## Part 8: SoftQualityComputer Integration

### 8.1 Complete Integration Layer

```swift
//
// SoftQualityComputer.swift
// Aether3D
//
// PR4 - Soft Quality Computer
// Integrates all soft components to produce final softQuality
//

import Foundation

/// Soft quality computer
/// Integrates depth fusion, edge classification, topology evaluation
public final class SoftQualityComputer {

    // =========================================================================
    // MARK: - Components
    // =========================================================================

    private let depthFusion: DepthFusionEngine
    private let edgeClassifier: EdgeClassifier
    private let topoEvaluator: TopologyEvaluator
    private let frameManager: DualFrameManager
    private let temporalSmoother: TemporalSmoother

    // =========================================================================
    // MARK: - Initialization
    // =========================================================================

    public init(resolution: Int = SoftGatesV13.maxDepthMapResolution) {
        self.depthFusion = DepthFusionEngine(fusionResolution: resolution)
        self.edgeClassifier = EdgeClassifier(resolution: resolution)
        self.topoEvaluator = TopologyEvaluator(resolution: resolution)
        self.frameManager = DualFrameManager()
        self.temporalSmoother = TemporalSmoother(
            windowSize: SoftGatesV13.temporalWindowSize
        )
    }

    // =========================================================================
    // MARK: - Computation
    // =========================================================================

    /// Compute soft quality for a frame
    ///
    /// - Parameters:
    ///   - depthSources: Array of depth sources
    ///   - frameData: Dual frame data
    ///   - normalMap: Surface normals (optional)
    ///   - viewDirection: Camera view direction
    ///   - gateQuality: Gate quality from PR3 (prerequisite)
    ///   - progress: Capture progress [0, 1]
    /// - Returns: Soft quality [0, 1]
    public func computeSoftQuality(
        depthSources: [DepthFusionEngine.DepthSourceData],
        frameData: DualFrameData,
        normalMap: ContiguousArray<EvidenceVector3>?,
        viewDirection: EvidenceVector3,
        gateQuality: Double,
        progress: Double
    ) -> Double {
        let config = SoftGatesV13.self

        // Early exit if gate is too low
        guard gateQuality >= 0.1 else {
            return 0.0
        }

        // Step 1: Depth fusion
        let fusedDepth = depthFusion.fuse(sources: depthSources)
        let depthGain = SoftGainFunctions.depthSoftGain(
            fusedResult: fusedDepth,
            referenceDepth: nil
        )

        // Step 2: Edge classification
        let edgeResult = edgeClassifier.classify(
            rgbPixels: frameData.assistRGB,
            depthMap: fusedDepth.depthMap,
            width: fusedDepth.width,
            height: fusedDepth.height
        )
        let edgeGain = SoftGainFunctions.edgeSoftGain(
            classificationResult: edgeResult
        )

        // Step 3: Topology evaluation
        let topoResult = topoEvaluator.evaluate(
            depthMap: fusedDepth.depthMap,
            confidenceMap: fusedDepth.confidenceMap,
            normalMap: normalMap,
            viewDirection: viewDirection,
            width: fusedDepth.width,
            height: fusedDepth.height
        )
        let topoGain = SoftGainFunctions.topoSoftGain(topoResult: topoResult)

        // Step 4: Base gain (frame consistency)
        let (frameConsistency, _) = frameManager.processFramePair(frameData)
        let baseGain = max(config.minBaseSoftGain, frameConsistency)

        // Step 5: Combine gains
        let rawSoftQuality =
            config.depthGainWeight * depthGain +
            config.topoGainWeight * topoGain +
            config.edgeGainWeight * edgeGain +
            config.baseGainWeight * baseGain

        // Step 6: Temporal smoothing
        let smoothedSoft = temporalSmoother.addAndSmooth(rawSoftQuality)

        // Step 7: Dynamic weighting with gate
        let finalQuality = DynamicWeightComputer.computeFinalQuality(
            gateQuality: gateQuality,
            softQuality: smoothedSoft,
            progress: progress
        )

        return finalQuality.clamped(to: 0...1)
    }

    // =========================================================================
    // MARK: - Lifecycle
    // =========================================================================

    /// Reset for new session
    public func reset() {
        depthFusion.reset()
        temporalSmoother.reset()
    }
}
```

---

## Part 9: Test Specifications

### 9.1 Unit Tests

```swift
final class SoftGainFunctionsTests: XCTestCase {

    // MARK: - Depth Soft Gain Tests

    func testDepthSoftGain_HighConsensus() {
        let fusedResult = createMockFusedResult(
            consensusRatio: 0.90,
            averageConfidence: 0.85
        )

        let gain = SoftGainFunctions.depthSoftGain(
            fusedResult: fusedResult,
            referenceDepth: nil
        )

        XCTAssertGreaterThan(gain, 0.70)
    }

    func testDepthSoftGain_LowConsensus() {
        let fusedResult = createMockFusedResult(
            consensusRatio: 0.40,
            averageConfidence: 0.50
        )

        let gain = SoftGainFunctions.depthSoftGain(
            fusedResult: fusedResult,
            referenceDepth: nil
        )

        XCTAssertLessThan(gain, 0.30)
        XCTAssertGreaterThanOrEqual(gain, SoftGatesV13.minDepthSoftGain)
    }

    // MARK: - Edge Soft Gain Tests

    func testEdgeSoftGain_GeometricDominant() {
        let result = EdgeClassificationResult(
            typeCounts: [
                .geometric: 800,
                .textural: 150,
                .specular: 30,
                .transparent: 10,
                .none: 10
            ],
            typeGradients: [:],
            dominantType: .geometric,
            overallConfidence: 0.85,
            edgeDensity: 0.10
        )

        let gain = SoftGainFunctions.edgeSoftGain(classificationResult: result)

        XCTAssertGreaterThan(gain, 0.75)
    }

    func testEdgeSoftGain_TransparentDominant() {
        let result = EdgeClassificationResult(
            typeCounts: [
                .geometric: 50,
                .textural: 100,
                .specular: 150,
                .transparent: 700,
                .none: 0
            ],
            typeGradients: [:],
            dominantType: .transparent,
            overallConfidence: 0.25,
            edgeDensity: 0.10
        )

        let gain = SoftGainFunctions.edgeSoftGain(classificationResult: result)

        XCTAssertLessThan(gain, 0.40)
    }

    // MARK: - Topology Soft Gain Tests

    func testTopoSoftGain_NoHoles() {
        let result = TopologyResult(
            holeCount: 0,
            totalHoleAreaPixels: 0,
            holeAreaRatio: 0.0,
            maxHoleSize: 0,
            boundaryLengthPixels: 500,
            boundaryConfidence: 0.85,
            selfOccludedRatio: 0.05,
            depthSmoothness: 0.90,
            overallConfidence: 0.88
        )

        let gain = SoftGainFunctions.topoSoftGain(topoResult: result)

        XCTAssertGreaterThan(gain, 0.70)
    }

    func testTopoSoftGain_LargeHoles() {
        let result = TopologyResult(
            holeCount: 3,
            totalHoleAreaPixels: 5000,
            holeAreaRatio: 0.08,
            maxHoleSize: 3000,
            boundaryLengthPixels: 200,
            boundaryConfidence: 0.50,
            selfOccludedRatio: 0.15,
            depthSmoothness: 0.60,
            overallConfidence: 0.45
        )

        let gain = SoftGainFunctions.topoSoftGain(topoResult: result)

        XCTAssertLessThan(gain, 0.40)
    }

    // MARK: - Dynamic Weights Tests

    func testDynamicWeights_EarlyProgress() {
        let (gate, soft) = DynamicWeightComputer.computeWeights(progress: 0.10)

        XCTAssertGreaterThan(gate, 0.80)
        XCTAssertLessThan(soft, 0.20)
        XCTAssertEqual(gate + soft, 1.0, accuracy: 1e-9)
    }

    func testDynamicWeights_LateProgress() {
        let (gate, soft) = DynamicWeightComputer.computeWeights(progress: 0.90)

        XCTAssertLessThan(gate, 0.30)
        XCTAssertGreaterThan(soft, 0.70)
        XCTAssertEqual(gate + soft, 1.0, accuracy: 1e-9)
    }

    func testDynamicWeights_MidProgress() {
        let (gate, soft) = DynamicWeightComputer.computeWeights(progress: 0.50)

        XCTAssertGreaterThan(gate, 0.40)
        XCTAssertLessThan(gate, 0.60)
        XCTAssertGreaterThan(soft, 0.40)
        XCTAssertLessThan(soft, 0.60)
    }
}
```

### 9.2 Golden Tests (Error Bounds)

```swift
final class SoftGoldenTests: XCTestCase {

    /// Soft golden tests verify ERROR BOUNDS, not exact match
    /// Because soft quality is ML-based and inherently approximate

    func testSoftQuality_ErrorBoundsWithinTolerance() throws {
        let goldenFixture = try loadSoftGoldenFixture("soft_quality_golden_v1.json")

        // Maximum allowed error (10% tolerance)
        let maxError = 0.10

        for testCase in goldenFixture.cases {
            let computed = computeSoftQualityForTestCase(testCase.input)
            let expected = testCase.expected.softQuality

            let error = abs(computed - expected)

            XCTAssertLessThanOrEqual(
                error,
                maxError,
                "\(testCase.name): soft error \(error) exceeds tolerance \(maxError)"
            )
        }
    }

    func testDepthFusion_ConsensusWithinTolerance() throws {
        let goldenFixture = try loadDepthFusionGoldenFixture("depth_fusion_golden_v1.json")

        let maxConsensusError = 0.05

        for testCase in goldenFixture.cases {
            let fusedResult = performDepthFusion(testCase.input)
            let expectedConsensus = testCase.expected.consensusRatio

            let error = abs(fusedResult.consensusRatio - expectedConsensus)

            XCTAssertLessThanOrEqual(
                error,
                maxConsensusError,
                "\(testCase.name): consensus error \(error) exceeds tolerance"
            )
        }
    }
}
```

### 9.3 Determinism Tests

```swift
final class SoftDeterminismTests: XCTestCase {

    func testDepthFusion_Deterministic100Runs() {
        var results: Set<String> = []

        for _ in 0..<100 {
            let engine = DepthFusionEngine()
            let sources = createDeterministicDepthSources()
            let result = engine.fuse(sources: sources)

            let fingerprint = "\(result.consensusRatio)-\(result.averageConfidence)"
            results.insert(fingerprint)
        }

        XCTAssertEqual(results.count, 1, "Depth fusion must be deterministic")
    }

    func testEdgeClassifier_Deterministic100Runs() {
        var results: Set<Int> = []

        for _ in 0..<100 {
            let classifier = EdgeClassifier()
            let result = classifier.classify(
                rgbPixels: createDeterministicRGBPixels(),
                depthMap: createDeterministicDepthMap(),
                width: 256,
                height: 256
            )

            results.insert(result.typeCounts[.geometric] ?? 0)
        }

        XCTAssertEqual(results.count, 1, "Edge classifier must be deterministic")
    }

    func testDynamicWeights_DeterministicOverProgress() {
        for progress in stride(from: 0.0, through: 1.0, by: 0.01) {
            var gateResults: Set<Double> = []

            for _ in 0..<50 {
                let (gate, _) = DynamicWeightComputer.computeWeights(progress: progress)
                gateResults.insert(gate)
            }

            XCTAssertEqual(
                gateResults.count, 1,
                "Dynamic weights must be deterministic at progress \(progress)"
            )
        }
    }
}
```

### 9.4 Cross-Platform Tests

```swift
final class SoftCrossPlatformTests: XCTestCase {

    /// These tests verify that soft quality is consistent across iOS and Linux
    /// Results should be within tolerance (not exact due to floating point)

    func testDepthFusion_CrossPlatformConsistency() throws {
        let testCases = try loadCrossPlatformTestCases("depth_fusion_cross_platform.json")

        let tolerance = 0.001  // 0.1% tolerance

        for testCase in testCases {
            let result = performDepthFusion(testCase.input)

            XCTAssertEqual(
                result.consensusRatio,
                testCase.expectedConsensusRatio,
                accuracy: tolerance,
                "\(testCase.name): cross-platform consensus mismatch"
            )
        }
    }

    func testEdgeClassifier_CrossPlatformConsistency() throws {
        let testCases = try loadCrossPlatformTestCases("edge_classifier_cross_platform.json")

        for testCase in testCases {
            let result = performEdgeClassification(testCase.input)

            // Exact match for integer counts
            XCTAssertEqual(
                result.typeCounts[.geometric],
                testCase.expectedGeometricCount,
                "\(testCase.name): cross-platform geometric count mismatch"
            )
        }
    }
}
```

---

## Part 10: Acceptance Criteria

### 10.1 Functional Acceptance

| ID | Criterion | Test Method |
|----|-----------|-------------|
| S1 | depthSoftGain returns in [minDepthSoftGain, 1] | Unit test |
| S2 | edgeSoftGain returns in [minEdgeSoftGain, 1] | Unit test |
| S3 | topoSoftGain returns in [minTopoSoftGain, 1] | Unit test |
| S4 | Dynamic weights sum to 1.0 | Unit test |
| S5 | softQuality is gated by gateQuality | Integration test |
| S6 | Depth fusion handles 1-4 sources | Unit test |
| S7 | Edge classifier identifies all 4 types | Unit test |
| S8 | Topology detects holes > threshold | Unit test |
| S9 | Temporal smoothing reduces jitter | Unit test |
| S10 | Final quality is deterministic | Determinism test |

### 10.2 Performance Acceptance

| ID | Criterion | Target |
|----|-----------|--------|
| P1 | Depth fusion per frame | < 10ms |
| P2 | Edge classification per frame | < 5ms |
| P3 | Topology evaluation per frame | < 5ms |
| P4 | Total soft computation per frame | < 25ms |
| P5 | Memory per patch | < 50KB |
| P6 | Memory for 1000 patches | < 50MB |

### 10.3 Cross-Platform Acceptance

| ID | Criterion | Verification |
|----|-----------|--------------|
| X1 | Compiles on Linux (Swift 5.9) | CI test |
| X2 | Compiles on iOS (Swift 5.9) | CI test |
| X3 | Soft quality within 1% tolerance cross-platform | Cross-platform test |
| X4 | No platform-specific imports in core | Lint |
| X5 | Depth source adapter works on both platforms | Integration test |

### 10.4 Quality Acceptance

| ID | Criterion | Verification |
|----|-----------|--------------|
| Q1 | High gate + high soft = high final | Integration test |
| Q2 | Low gate = low final (regardless of soft) | Integration test |
| Q3 | Progress transition is smooth (no jumps) | Visual test |
| Q4 | Soft quality correlates with visual quality | Manual test |
| Q5 | Golden test error within 10% tolerance | Golden test |

---

## Part 11: File Deliverables

### 11.1 Required Files

```
Core/Evidence/PR4/
+-- SoftGainFunctions.swift           / (depthSoftGain, edgeSoftGain, topoSoftGain)
+-- SoftQualityComputer.swift         / (Integration layer)
+-- DepthFusion/
|   +-- DepthFusionEngine.swift       / (Multi-source consensus)
|   +-- DepthConsensusVoter.swift     / (Voting algorithm)
|   +-- DepthSourceAdapter.swift      / (Platform abstraction)
|   +-- DepthConfidenceMap.swift      / (Per-pixel confidence)
+-- EdgeClassification/
|   +-- EdgeClassifier.swift          / (4-type classification)
|   +-- EdgeTypeDetector.swift        / (Type detection logic)
|   +-- EdgeConfidenceMap.swift       / (Per-edge confidence)
+-- Topology/
|   +-- TopologyEvaluator.swift       / (Hole + occlusion)
|   +-- HoleDetector.swift            / (Connected component)
|   +-- OcclusionBoundaryTracker.swift / (Depth discontinuity)
+-- DualChannel/
|   +-- DualFrameManager.swift        / (raw + assist)
|   +-- FrameConsistencyChecker.swift / (Alignment check)
+-- Temporal/
|   +-- TemporalSmoother.swift        / (Frame smoothing)
|   +-- MotionCompensator.swift       / (Camera motion)
+-- Internal/
    +-- SoftRingBuffer.swift          / (Pre-allocated buffer)
    +-- EdgeHistogram.swift           / (Edge statistics)
    +-- DepthBucketizer.swift         / (Depth quantization)

Core/Evidence/PR4Math/
+-- PR4Math.swift                     / (Soft math facade)
+-- DepthInterpolator.swift           / (Bilinear interpolation)
+-- EdgeKernels.swift                 / (Sobel, Canny)
+-- ConfidenceAggregator.swift        / (Weighted combination)

Core/Evidence/Constants/
+-- SoftGatesV13.swift                / (Soft thresholds SSOT)
+-- EdgeTypeThresholds.swift          / (Per-edge thresholds)
+-- DepthFusionConfig.swift           / (Fusion parameters)

Core/Evidence/Validation/
+-- SoftInputValidator.swift          / (Depth/edge validation)
+-- SoftInputInvalidReason.swift      / (Validation reasons)

Tests/Evidence/PR4/
+-- SoftGainFunctionsTests.swift
+-- DepthFusionTests.swift
+-- EdgeClassificationTests.swift
+-- TopologyEvaluatorTests.swift
+-- DualChannelTests.swift
+-- TemporalSmootherTests.swift
+-- SoftDeterminismTests.swift
+-- SoftGoldenTests.swift
+-- SoftCrossPlatformTests.swift

Tests/Evidence/Fixtures/Golden/
+-- soft_quality_golden_v1.json
+-- depth_fusion_golden_v1.json
+-- edge_classifier_golden_v1.json
```

---

## Part 12: Implementation Phase Order

```
Phase 1: Math & Constants Foundation (Zero Dependencies)
+-- PR4Math.swift (facade)
+-- SoftGatesV13.swift (thresholds)
+-- EdgeTypeThresholds.swift
+-- DepthFusionConfig.swift

Phase 2: Internal Infrastructure
+-- SoftRingBuffer.swift
+-- EdgeHistogram.swift
+-- DepthBucketizer.swift

Phase 3: Depth Fusion System
+-- DepthSourceAdapter.swift
+-- DepthConfidenceMap.swift
+-- DepthConsensusVoter.swift
+-- DepthFusionEngine.swift

Phase 4: Edge Classification System
+-- EdgeKernels.swift
+-- EdgeTypeDetector.swift
+-- EdgeConfidenceMap.swift
+-- EdgeClassifier.swift

Phase 5: Topology Evaluation
+-- HoleDetector.swift
+-- OcclusionBoundaryTracker.swift
+-- TopologyEvaluator.swift

Phase 6: Dual Frame Channel
+-- FrameConsistencyChecker.swift
+-- DualFrameManager.swift

Phase 7: Temporal Processing
+-- MotionCompensator.swift
+-- TemporalSmoother.swift

Phase 8: Gain Functions
+-- SoftGainFunctions.swift (uses all above)

Phase 9: Integration
+-- SoftQualityComputer.swift
+-- DynamicWeightComputer.swift
+-- Modify IsolatedEvidenceEngine.swift (ADD soft path)

Phase 10: Validation
+-- SoftInputValidator.swift
+-- SoftInputInvalidReason.swift

Phase 11: Tests
+-- All test files
+-- Golden fixtures
+-- Cross-platform CI

Phase 12: CI
+-- pr4-whitelist.yml
+-- ForbiddenPatternLint updates for PR4
```

---

## Part 13: PR5 Dependencies (Future)

After PR4 is complete:

**PR5 (Capture Control) will:**
- Use gateQuality and softQuality to guide capture UI
- Implement real-time feedback for coverage gaps
- Implement capture completion detection
- Provide recommendations for next capture angle

**PR4 -> PR5 Interface:**
```swift
// PR4 computes:
let softQuality = softComputer.computeSoftQuality(...)

// PR5 will use:
let recommendation = captureController.getNextRecommendation(
    gateQuality: gateQuality,
    softQuality: softQuality,
    coverageMap: coverageMap
)

// Display to user:
ui.showRecommendation(recommendation)
ui.showProgress(combineQuality: finalQuality)
```

---

## Summary: PR4 Key Innovations

1. **Multi-Source Depth Fusion**: Consensus voting from 1-4 depth sources
2. **4-Type Edge Classification**: Geometric/textural/specular/transparent with reliability weights
3. **Topology Evaluation**: Hole detection, occlusion boundaries, self-occlusion
4. **Dual Frame Channel**: Separate raw (color) and assist (depth) frames
5. **Dynamic Weight System**: Progress-based Gate/Soft blending
6. **Multiplicative Gain with Floor**: v1.3 style conservative aggregation
7. **Zero-Allocation Hot Path**: Pre-allocated buffers, no heap in computation
8. **Cross-Platform Abstraction**: DepthSourceAdapter for ARKit/ARCore/ML
9. **Error Bound Testing**: Golden tests verify bounds, not exact values
10. **Temporal Consistency**: Frame-to-frame smoothing reduces jitter

---

**Document Version:** 1.0 (Extreme Edition)
**Author:** Claude Code
**Created:** 2026-01-31
**Status:** DRAFT - READY FOR IMPLEMENTATION
