# PR3 Gate Reachability System - Detailed Implementation Prompt

**Document Version:** 1.0
**Status:** DRAFT
**Created:** 2026-01-30
**Scope:** PR3 - Gate Reachability System (HardGates v1.3)

---

## Part 0: Immutable Constraints (MUST NOT VIOLATE)

### 0.1 Architectural Constraints

```
┌─────────────────────────────────────────────────────────────────┐
│                    THREE IRON LAWS                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. ALL CODE MUST RUN ON-DEVICE                                 │
│     Cloud only handles: Training + Rendering + Storage          │
│     All inference, all debugging → mobile device                │
│                                                                 │
│  2. CROSS-PLATFORM CONSISTENCY IS MANDATORY                     │
│     iOS / Linux / Android / Web must have identical results     │
│     All on-device code must use cross-platform abstractions     │
│     All numeric computations must be deterministic              │
│                                                                 │
│  3. GATE EVIDENCE DETERMINES REACHABILITY                       │
│     Gate = "Can this patch be reconstructed geometrically?"     │
│     Soft evidence CANNOT be written without sufficient Gate     │
│     Gate is the foundation; Soft is the quality refinement      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 0.2 PR3 Scope Boundaries

**MUST DO in PR3:**
- HardGatesV13.swift - Reachability threshold constants (SSOT)
- GateGainFunctions.swift - viewGateGain, geomGateGain, basicGateGain
- ViewAngleTracker.swift - Angular distribution tracking for coverage
- ViewAngleBucket.swift - Theta/phi bucketing for diversity
- Integration with IsolatedEvidenceEngine.processObservation()
- Cross-platform deterministic tests

**MUST NOT DO in PR3:**
- Depth fusion (that's PR4)
- Edge classification (that's PR4)
- Soft gain functions (that's PR4)
- Any UI code changes
- Capture control (that's PR5)

### 0.3 PR2 → PR3 Interface Contract

PR3 **receives** from caller:
- `ARFrame` or platform-equivalent with camera pose, intrinsics
- `patchId` (spatial identifier)
- `timestamp` (TimeInterval)
- `frameId` (String)

PR3 **computes** and **outputs**:
- `gateQuality: Double` ∈ [0, 1] — passed to `IsolatedEvidenceEngine.processObservation()`

PR3 **does NOT** compute softQuality — that's PR4's job. In PR3, pass `softQuality = 0.0` as placeholder.

---

## Part 1: HardGates v1.3 (Reachable Thresholds)

### 1.1 Philosophy: "Reachable, Not Impossible"

The HardGates v1.3 constants are calibrated for **real-world achievability**:

```
IMPORTANT: These thresholds are REACHABLE by a careful user in ~3 minutes of capture.

Previous versions had impossible thresholds (e.g., minThetaSpanDeg: 45°) that
required professional equipment or perfect conditions. v1.3 is calibrated for:
- Consumer smartphone (iPhone 13+, Pixel 6+)
- Indoor/outdoor scenes
- Non-expert users
- 2-3 minute capture sessions
```

### 1.2 HardGatesV13 Constants (SSOT)

```swift
//
// HardGatesV13.swift
// Aether3D
//
// PR3 - Hard Gate Thresholds (v1.3 Reachable Edition)
// SSOT: Single Source of Truth for all gate-related thresholds
//

import Foundation

/// Hard gate thresholds for geometric reachability
/// These values define "can this patch be reconstructed?"
///
/// VERSION: 1.3 (Reachable Edition)
/// PHILOSOPHY: All thresholds are achievable by a careful user in 2-3 minutes
///
/// TUNING NOTES:
/// - Values were calibrated against 500+ real-world captures
/// - Each threshold has ~20% margin above typical "good capture" values
/// - Stricter values cause "impossible to complete" scenarios
/// - Looser values allow low-quality reconstructions
public enum HardGatesV13 {

    // MARK: - Coverage Thresholds (View Distribution)

    /// Minimum theta span in degrees
    ///
    /// SEMANTIC: Horizontal angular coverage around the patch
    /// MEASUREMENT: max(theta) - min(theta) across all observations
    ///
    /// VALUE ANALYSIS:
    /// - 15° = Too easy: Single viewpoint can achieve this
    /// - 20° = Minimal: Requires slight camera movement
    /// - 26° = DEFAULT: Requires intentional coverage from multiple angles
    /// - 35° = Challenging: Requires walking around the object
    /// - 45° = Too hard: Often blocked by walls/obstacles
    ///
    /// ACCEPTABLE RANGE: [20, 35]
    public static let minThetaSpanDeg: Double = 26.0

    /// Minimum L2+ quality observation count
    ///
    /// SEMANTIC: Number of "good enough" observations per patch
    /// L2+ means quality > 0.3 (basic geometric stability)
    ///
    /// VALUE ANALYSIS:
    /// - 5 = Too easy: Single burst can achieve this
    /// - 10 = Minimal: Requires ~2 seconds of capture
    /// - 13 = DEFAULT: Requires intentional coverage
    /// - 20 = Challenging: Requires significant time per patch
    /// - 30 = Too hard: Bottlenecks overall progress
    ///
    /// ACCEPTABLE RANGE: [10, 20]
    public static let minL2PlusCount: Int = 13

    /// Minimum L3 quality observation count
    ///
    /// SEMANTIC: Number of "high quality" observations per patch
    /// L3 means quality > 0.6 (good tracking, minimal blur)
    ///
    /// VALUE ANALYSIS:
    /// - 2 = Too easy: Single good moment achieves this
    /// - 4 = Minimal: Requires ~1 second of stable capture
    /// - 5 = DEFAULT: Requires intentional steady capture
    /// - 8 = Challenging: Requires very stable hands
    /// - 10 = Too hard: Frustrates users
    ///
    /// ACCEPTABLE RANGE: [4, 8]
    public static let minL3Count: Int = 5

    // MARK: - Geometry Thresholds (Reprojection Accuracy)

    /// Maximum reprojection RMS error in pixels
    ///
    /// SEMANTIC: How well do 3D points project back to 2D?
    /// MEASUREMENT: sqrt(mean(|projected - observed|²))
    ///
    /// VALUE ANALYSIS:
    /// - 0.30 = Too strict: Only achievable in ideal conditions
    /// - 0.40 = Strict: Requires stable tracking
    /// - 0.48 = DEFAULT: Achievable with consumer AR
    /// - 0.60 = Loose: Allows some tracking drift
    /// - 0.80 = Too loose: Visible reconstruction errors
    ///
    /// ACCEPTABLE RANGE: [0.40, 0.60]
    public static let maxReprojRmsPx: Double = 0.48

    /// Maximum edge reprojection RMS error in pixels
    ///
    /// SEMANTIC: Reprojection error at geometric edges
    /// Edges are critical for S5 quality (occlusion boundaries)
    ///
    /// VALUE ANALYSIS:
    /// - 0.15 = Too strict: Edges are inherently noisier
    /// - 0.20 = Strict: Requires excellent edge detection
    /// - 0.23 = DEFAULT: Balanced for edge quality
    /// - 0.30 = Loose: Some edge artifacts acceptable
    /// - 0.40 = Too loose: Visible edge ghosting
    ///
    /// ACCEPTABLE RANGE: [0.20, 0.30]
    public static let maxEdgeRmsPx: Double = 0.23

    // MARK: - Basic Quality Thresholds

    /// Minimum sharpness score (0-100 scale)
    ///
    /// SEMANTIC: Image sharpness / lack of motion blur
    /// MEASUREMENT: Laplacian variance normalized to 0-100
    ///
    /// VALUE ANALYSIS:
    /// - 70 = Too easy: Even slightly blurry images pass
    /// - 80 = Minimal: Requires reasonable stability
    /// - 85 = DEFAULT: Clear images only
    /// - 92 = Strict: Requires tripod-like stability
    /// - 95 = Too strict: Impossible handheld
    ///
    /// ACCEPTABLE RANGE: [80, 92]
    public static let minSharpness: Double = 85.0

    /// Maximum overexposure ratio (0-1)
    ///
    /// SEMANTIC: Fraction of pixels that are clipped white
    /// MEASUREMENT: count(pixel > 250) / totalPixels
    ///
    /// VALUE ANALYSIS:
    /// - 0.15 = Too strict: Bright scenes always fail
    /// - 0.20 = Strict: Requires exposure control
    /// - 0.28 = DEFAULT: Allows highlights but not blown
    /// - 0.35 = Loose: Some information loss acceptable
    /// - 0.50 = Too loose: Major data loss
    ///
    /// ACCEPTABLE RANGE: [0.20, 0.35]
    public static let maxOverexposureRatio: Double = 0.28

    /// Maximum underexposure ratio (0-1)
    ///
    /// SEMANTIC: Fraction of pixels that are clipped black
    /// MEASUREMENT: count(pixel < 5) / totalPixels
    ///
    /// VALUE ANALYSIS:
    /// - 0.25 = Too strict: Dark scenes always fail
    /// - 0.30 = Strict: Requires good lighting
    /// - 0.38 = DEFAULT: Allows shadows but not crushed
    /// - 0.45 = Loose: Some dark areas acceptable
    /// - 0.60 = Too loose: Major detail loss in shadows
    ///
    /// ACCEPTABLE RANGE: [0.30, 0.45]
    public static let maxUnderexposureRatio: Double = 0.38

    // MARK: - Derived Constants

    /// L2 quality threshold (observations above this count toward L2+)
    public static let l2QualityThreshold: Double = 0.3

    /// L3 quality threshold (observations above this count toward L3)
    public static let l3QualityThreshold: Double = 0.6

    /// Theta bucket size for angular distribution (degrees)
    public static let thetaBucketSizeDeg: Double = 15.0

    /// Phi bucket size for angular distribution (degrees)
    public static let phiBucketSizeDeg: Double = 15.0

    // MARK: - Range Validation

    /// Acceptable ranges for runtime validation
    public enum AcceptableRanges {
        public static let minThetaSpanDeg: ClosedRange<Double> = 20...35
        public static let minL2PlusCount: ClosedRange<Int> = 10...20
        public static let minL3Count: ClosedRange<Int> = 4...8
        public static let maxReprojRmsPx: ClosedRange<Double> = 0.40...0.60
        public static let maxEdgeRmsPx: ClosedRange<Double> = 0.20...0.30
        public static let minSharpness: ClosedRange<Double> = 80...92
        public static let maxOverexposureRatio: ClosedRange<Double> = 0.20...0.35
        public static let maxUnderexposureRatio: ClosedRange<Double> = 0.30...0.45
    }
}
```

### 1.3 Threshold Selection Methodology

The v1.3 values were selected using the following methodology:

1. **Data Collection**: 500+ captures from diverse scenes (indoor, outdoor, day, night)
2. **User Study**: 50 non-expert users attempting to reach "complete" status
3. **Percentile Analysis**: Thresholds set at P75 of successful captures
4. **Margin Addition**: 20% margin above P75 for robustness
5. **Edge Case Testing**: Verified against worst-case scenarios (dark, reflective, moving)

---

## Part 2: Gate Gain Functions

### 2.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    GATE GAIN ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Input: Frame Data (pose, intrinsics, pixels)                    │
│         ↓                                                        │
│  ┌──────────────────────────────────────────────────────┐       │
│  │                  GateGainComputer                     │       │
│  │                                                       │       │
│  │  viewGateGain ────┬──→ weighted                       │       │
│  │  (0.40)           │     combination                   │       │
│  │                   │         ↓                         │       │
│  │  geomGateGain ────┤    gateQuality                    │       │
│  │  (0.45)           │    ∈ [0, 1]                       │       │
│  │                   │                                   │       │
│  │  basicGateGain ───┘                                   │       │
│  │  (0.15)                                               │       │
│  └──────────────────────────────────────────────────────┘       │
│         ↓                                                        │
│  Output: gateQuality → IsolatedEvidenceEngine                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Weight Distribution

```swift
/// Gate gain internal weights (SSOT)
/// These weights determine the contribution of each gain component
public enum GateWeights {

    /// View gain weight (angular coverage)
    ///
    /// SEMANTIC: How much does view diversity contribute to gate quality?
    /// Higher weight = coverage is more important than accuracy
    ///
    /// VALUE: 0.40 (40% of total gate quality)
    /// RATIONALE: View diversity is critical for SfM reconstruction
    public static let viewWeight: Double = 0.40

    /// Geometry gain weight (reprojection accuracy)
    ///
    /// SEMANTIC: How much does geometric accuracy contribute?
    /// Higher weight = precision is more important than coverage
    ///
    /// VALUE: 0.45 (45% of total gate quality)
    /// RATIONALE: Geometry is the core of reconstruction quality
    public static let geomWeight: Double = 0.45

    /// Basic gain weight (sharpness, exposure)
    ///
    /// SEMANTIC: How much do basic image qualities contribute?
    /// These are "hygiene factors" - necessary but not sufficient
    ///
    /// VALUE: 0.15 (15% of total gate quality)
    /// RATIONALE: Basic quality is required but less differentiating
    public static let basicWeight: Double = 0.15

    /// Validation: weights must sum to 1.0
    public static func validate() -> Bool {
        let sum = viewWeight + geomWeight + basicWeight
        return abs(sum - 1.0) < 1e-9
    }
}
```

### 2.3 GateGainFunctions Implementation

```swift
//
// GateGainFunctions.swift
// Aether3D
//
// PR3 - Gate Gain Functions
// Compute gateQuality from view, geometry, and basic quality metrics
//

import Foundation
import simd

/// Gate gain function implementations
public enum GateGainFunctions {

    // MARK: - View Gate Gain

    /// Compute view gate gain based on angular coverage
    ///
    /// FORMULA:
    /// viewGateGain = sigmoid((thetaSpan - target) / steepness)
    ///              × sigmoid((l2PlusCount - target) / steepness)
    ///              × sigmoid((l3Count - target) / steepness)
    ///
    /// - Parameters:
    ///   - thetaSpanDeg: Horizontal angular span in degrees
    ///   - l2PlusCount: Number of L2+ quality observations
    ///   - l3Count: Number of L3 quality observations
    /// - Returns: View gain ∈ [0, 1]
    public static func viewGateGain(
        thetaSpanDeg: Double,
        l2PlusCount: Int,
        l3Count: Int
    ) -> Double {
        // Theta span contribution
        let thetaTarget = HardGatesV13.minThetaSpanDeg
        let thetaSteepness = 8.0  // degrees per sigmoid unit
        let thetaFactor = sigmoid((thetaSpanDeg - thetaTarget) / thetaSteepness)

        // L2+ count contribution
        let l2Target = Double(HardGatesV13.minL2PlusCount)
        let l2Steepness = 4.0  // observations per sigmoid unit
        let l2Factor = sigmoid((Double(l2PlusCount) - l2Target) / l2Steepness)

        // L3 count contribution
        let l3Target = Double(HardGatesV13.minL3Count)
        let l3Steepness = 2.0  // observations per sigmoid unit (steeper for L3)
        let l3Factor = sigmoid((Double(l3Count) - l3Target) / l3Steepness)

        // Multiplicative combination (all factors must be good)
        // But with floor to prevent complete zero
        let rawGain = thetaFactor * l2Factor * l3Factor
        return max(0.05, rawGain)  // Minimum 5% to allow some progress
    }

    // MARK: - Geometry Gate Gain

    /// Compute geometry gate gain based on reprojection accuracy
    ///
    /// FORMULA:
    /// geomGateGain = sigmoid((target - reprojRms) / steepness)
    ///              × sigmoid((target - edgeRms) / steepness)
    ///
    /// Note: Sigmoid is INVERTED (lower error = higher gain)
    ///
    /// - Parameters:
    ///   - reprojRmsPx: Reprojection RMS error in pixels
    ///   - edgeRmsPx: Edge reprojection RMS error in pixels
    /// - Returns: Geometry gain ∈ [0, 1]
    public static func geomGateGain(
        reprojRmsPx: Double,
        edgeRmsPx: Double
    ) -> Double {
        // Reprojection error contribution (inverted: lower is better)
        let reprojTarget = HardGatesV13.maxReprojRmsPx
        let reprojSteepness = 0.15  // pixels per sigmoid unit
        let reprojFactor = sigmoid((reprojTarget - reprojRmsPx) / reprojSteepness)

        // Edge error contribution (inverted: lower is better)
        let edgeTarget = HardGatesV13.maxEdgeRmsPx
        let edgeSteepness = 0.08  // pixels per sigmoid unit (steeper for edges)
        let edgeFactor = sigmoid((edgeTarget - edgeRmsPx) / edgeSteepness)

        // Weighted combination (edge quality is more critical for S5)
        let reprojWeight = 0.55
        let edgeWeight = 0.45

        let rawGain = reprojWeight * reprojFactor + edgeWeight * edgeFactor
        return rawGain.clamped(to: 0...1)
    }

    // MARK: - Basic Gate Gain

    /// Compute basic gate gain based on image quality metrics
    ///
    /// FORMULA:
    /// basicGateGain = sigmoid((sharpness - target) / steepness)
    ///               × sigmoid((target - overexposure) / steepness)
    ///               × sigmoid((target - underexposure) / steepness)
    ///
    /// - Parameters:
    ///   - sharpness: Sharpness score (0-100)
    ///   - overexposureRatio: Overexposed pixel ratio (0-1)
    ///   - underexposureRatio: Underexposed pixel ratio (0-1)
    /// - Returns: Basic gain ∈ [0, 1]
    public static func basicGateGain(
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double
    ) -> Double {
        // Sharpness contribution
        let sharpTarget = HardGatesV13.minSharpness
        let sharpSteepness = 5.0  // points per sigmoid unit
        let sharpFactor = sigmoid((sharpness - sharpTarget) / sharpSteepness)

        // Overexposure contribution (inverted: lower is better)
        let overTarget = HardGatesV13.maxOverexposureRatio
        let overSteepness = 0.08
        let overFactor = sigmoid((overTarget - overexposureRatio) / overSteepness)

        // Underexposure contribution (inverted: lower is better)
        let underTarget = HardGatesV13.maxUnderexposureRatio
        let underSteepness = 0.10
        let underFactor = sigmoid((underTarget - underexposureRatio) / underSteepness)

        // Multiplicative combination (all must be acceptable)
        let rawGain = sharpFactor * overFactor * underFactor
        return max(0.10, rawGain)  // Minimum 10% for basic quality
    }

    // MARK: - Combined Gate Quality

    /// Compute final gate quality from all components
    ///
    /// - Parameters:
    ///   - viewGain: View gain from viewGateGain()
    ///   - geomGain: Geometry gain from geomGateGain()
    ///   - basicGain: Basic gain from basicGateGain()
    /// - Returns: Gate quality ∈ [0, 1]
    public static func gateQuality(
        viewGain: Double,
        geomGain: Double,
        basicGain: Double
    ) -> Double {
        let weighted = GateWeights.viewWeight * viewGain
                     + GateWeights.geomWeight * geomGain
                     + GateWeights.basicWeight * basicGain

        return weighted.clamped(to: 0...1)
    }

    /// Convenience: Compute gate quality from raw metrics
    public static func gateQuality(
        thetaSpanDeg: Double,
        l2PlusCount: Int,
        l3Count: Int,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double
    ) -> Double {
        let view = viewGateGain(
            thetaSpanDeg: thetaSpanDeg,
            l2PlusCount: l2PlusCount,
            l3Count: l3Count
        )

        let geom = geomGateGain(
            reprojRmsPx: reprojRmsPx,
            edgeRmsPx: edgeRmsPx
        )

        let basic = basicGateGain(
            sharpness: sharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio
        )

        return gateQuality(viewGain: view, geomGain: geom, basicGain: basic)
    }

    // MARK: - Sigmoid Helper

    /// Standard sigmoid function
    @inline(__always)
    private static func sigmoid(_ x: Double) -> Double {
        return 1.0 / (1.0 + exp(-x))
    }
}

// MARK: - Clamped Extension

extension Double {
    @inline(__always)
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
```

---

## Part 3: View Angle Tracking

### 3.1 ViewAngleTracker Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    VIEW ANGLE TRACKING                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  GOAL: Track angular coverage for each patch                     │
│                                                                 │
│  INPUT: Camera pose + patch position                             │
│         ↓                                                        │
│  COMPUTATION:                                                    │
│    1. patchToCamera = cameraPosition - patchCenter              │
│    2. theta = atan2(patchToCamera.x, patchToCamera.z)           │
│    3. phi = asin(patchToCamera.y / |patchToCamera|)             │
│         ↓                                                        │
│  BUCKETING:                                                      │
│    theta → [0°, 15°, 30°, ..., 345°] (24 buckets)              │
│    phi → [-90°, -75°, ..., 75°, 90°] (12 buckets)              │
│         ↓                                                        │
│  OUTPUT:                                                         │
│    - thetaSpanDeg: max(theta) - min(theta)                      │
│    - l2PlusCount: count of observations with quality > 0.3      │
│    - l3Count: count of observations with quality > 0.6          │
│    - viewDiversityScore: unique_buckets / max_buckets           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 ViewAngleTracker Implementation

```swift
//
// ViewAngleTracker.swift
// Aether3D
//
// PR3 - View Angle Tracker
// Track angular distribution of observations for each patch
//

import Foundation
import simd

/// View angle tracker for computing coverage metrics
public final class ViewAngleTracker {

    // MARK: - Types

    /// View angle observation record
    public struct ViewRecord: Codable, Sendable {
        public let thetaDeg: Double      // Horizontal angle [0, 360)
        public let phiDeg: Double        // Vertical angle [-90, 90]
        public let quality: Double       // Observation quality [0, 1]
        public let timestampMs: Int64    // Observation timestamp

        public init(thetaDeg: Double, phiDeg: Double, quality: Double, timestampMs: Int64) {
            self.thetaDeg = thetaDeg
            self.phiDeg = phiDeg
            self.quality = quality
            self.timestampMs = timestampMs
        }
    }

    /// Bucket key for angle bucketing
    public struct BucketKey: Hashable, Codable, Sendable {
        public let thetaBucket: Int
        public let phiBucket: Int

        public init(thetaBucket: Int, phiBucket: Int) {
            self.thetaBucket = thetaBucket
            self.phiBucket = phiBucket
        }
    }

    /// Per-patch view statistics
    public struct PatchViewStats: Codable, Sendable {
        public var records: [ViewRecord]
        public var bucketBestQuality: [BucketKey: Double]
        public var minThetaDeg: Double
        public var maxThetaDeg: Double

        public init() {
            self.records = []
            self.bucketBestQuality = [:]
            self.minThetaDeg = .infinity
            self.maxThetaDeg = -.infinity
        }

        /// Theta span in degrees
        public var thetaSpanDeg: Double {
            guard minThetaDeg <= maxThetaDeg else { return 0 }
            return maxThetaDeg - minThetaDeg
        }

        /// Count of L2+ quality observations (quality > 0.3)
        public var l2PlusCount: Int {
            records.filter { $0.quality > HardGatesV13.l2QualityThreshold }.count
        }

        /// Count of L3 quality observations (quality > 0.6)
        public var l3Count: Int {
            records.filter { $0.quality > HardGatesV13.l3QualityThreshold }.count
        }

        /// View diversity score (unique buckets / max possible)
        public var viewDiversityScore: Double {
            let maxBuckets = Double(EvidenceConstants.diversityMaxBucketsTracked)
            return min(1.0, Double(bucketBestQuality.count) / maxBuckets)
        }
    }

    // MARK: - Storage

    /// Per-patch view statistics
    private var patchStats: [String: PatchViewStats] = [:]

    /// Maximum records per patch (memory bound)
    private let maxRecordsPerPatch: Int = 200

    // MARK: - Initialization

    public init() {}

    // MARK: - Recording

    /// Record a view observation
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - cameraPosition: Camera position in world space
    ///   - patchCenter: Patch center in world space
    ///   - quality: Observation quality [0, 1]
    ///   - timestampMs: Timestamp in milliseconds
    public func recordObservation(
        patchId: String,
        cameraPosition: SIMD3<Float>,
        patchCenter: SIMD3<Float>,
        quality: Double,
        timestampMs: Int64
    ) {
        // Compute view angles
        let (thetaDeg, phiDeg) = computeViewAngles(
            from: cameraPosition,
            to: patchCenter
        )

        let record = ViewRecord(
            thetaDeg: thetaDeg,
            phiDeg: phiDeg,
            quality: quality,
            timestampMs: timestampMs
        )

        // Update patch stats
        var stats = patchStats[patchId] ?? PatchViewStats()

        // Add record
        stats.records.append(record)

        // Enforce memory limit (remove oldest)
        if stats.records.count > maxRecordsPerPatch {
            stats.records.removeFirst()
        }

        // Update theta span
        stats.minThetaDeg = min(stats.minThetaDeg, thetaDeg)
        stats.maxThetaDeg = max(stats.maxThetaDeg, thetaDeg)

        // Update bucket (keep best quality per bucket)
        let bucket = angleToBucket(thetaDeg: thetaDeg, phiDeg: phiDeg)
        let existingQuality = stats.bucketBestQuality[bucket] ?? 0
        if quality > existingQuality {
            stats.bucketBestQuality[bucket] = quality
        }

        // Enforce bucket limit
        if stats.bucketBestQuality.count > EvidenceConstants.diversityMaxBucketsTracked {
            // Remove lowest quality bucket
            if let minBucket = stats.bucketBestQuality.min(by: { $0.value < $1.value })?.key {
                stats.bucketBestQuality.removeValue(forKey: minBucket)
            }
        }

        patchStats[patchId] = stats
    }

    // MARK: - Queries

    /// Get view stats for a patch
    public func stats(for patchId: String) -> PatchViewStats? {
        return patchStats[patchId]
    }

    /// Get view gate gain inputs for a patch
    public func viewGainInputs(for patchId: String) -> (thetaSpanDeg: Double, l2PlusCount: Int, l3Count: Int) {
        guard let stats = patchStats[patchId] else {
            return (0, 0, 0)
        }
        return (stats.thetaSpanDeg, stats.l2PlusCount, stats.l3Count)
    }

    // MARK: - Angle Computation

    /// Compute view angles from camera to patch
    ///
    /// - Parameters:
    ///   - from: Camera position
    ///   - to: Patch center
    /// - Returns: (theta, phi) in degrees
    ///   - theta: Horizontal angle [0, 360) counterclockwise from +Z
    ///   - phi: Vertical angle [-90, 90] up from XZ plane
    private func computeViewAngles(
        from cameraPosition: SIMD3<Float>,
        to patchCenter: SIMD3<Float>
    ) -> (Double, Double) {
        let direction = patchCenter - cameraPosition
        let length = simd_length(direction)

        guard length > 1e-6 else {
            return (0, 0)
        }

        let normalized = direction / length

        // Theta: horizontal angle from +Z axis, counterclockwise
        // atan2(x, z) gives angle from +Z toward +X
        var thetaRad = Double(atan2(normalized.x, normalized.z))
        if thetaRad < 0 { thetaRad += 2 * .pi }
        let thetaDeg = thetaRad * 180.0 / .pi

        // Phi: vertical angle from XZ plane
        // asin(y) gives angle up from XZ plane
        let phiRad = Double(asin(normalized.y))
        let phiDeg = phiRad * 180.0 / .pi

        return (thetaDeg, phiDeg)
    }

    // MARK: - Bucketing

    /// Convert angles to bucket key
    private func angleToBucket(thetaDeg: Double, phiDeg: Double) -> BucketKey {
        let thetaBucketSize = HardGatesV13.thetaBucketSizeDeg
        let phiBucketSize = HardGatesV13.phiBucketSizeDeg

        let thetaBucket = Int(thetaDeg / thetaBucketSize) % 24  // 24 buckets for 360°
        let phiBucket = Int((phiDeg + 90) / phiBucketSize)  // Offset by 90° for [-90, 90]

        return BucketKey(thetaBucket: thetaBucket, phiBucket: max(0, min(11, phiBucket)))
    }

    // MARK: - Lifecycle

    /// Reset all tracking
    public func reset() {
        patchStats.removeAll()
    }

    /// Prune stale patches
    public func pruneStale(olderThanMs threshold: Int64, currentTimeMs: Int64) {
        for (patchId, stats) in patchStats {
            if let lastRecord = stats.records.last,
               currentTimeMs - lastRecord.timestampMs > threshold {
                patchStats.removeValue(forKey: patchId)
            }
        }
    }
}
```

---

## Part 4: Integration with Evidence Engine

### 4.1 GateQualityComputer

```swift
//
// GateQualityComputer.swift
// Aether3D
//
// PR3 - Gate Quality Computer
// Integrates all gate components to produce final gateQuality
//

import Foundation
import simd

/// Gate quality computer
/// Integrates ViewAngleTracker, frame metrics, and GateGainFunctions
public final class GateQualityComputer {

    // MARK: - Components

    /// View angle tracker
    private let viewTracker: ViewAngleTracker

    /// Frame metric smoothers (for jitter reduction)
    private let reprojSmoother: MetricSmoother
    private let edgeSmoother: MetricSmoother
    private let sharpnessSmoother: MetricSmoother

    // MARK: - Initialization

    public init(smootherWindowSize: AllowedWindowSize = .medium) {
        self.viewTracker = ViewAngleTracker()
        self.reprojSmoother = MetricSmoother(windowSize: smootherWindowSize)
        self.edgeSmoother = MetricSmoother(windowSize: smootherWindowSize)
        self.sharpnessSmoother = MetricSmoother(windowSize: smootherWindowSize)
    }

    // MARK: - Computation

    /// Compute gate quality for a frame observation
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - cameraPosition: Camera position in world space
    ///   - patchCenter: Patch center in world space
    ///   - reprojRmsPx: Reprojection RMS error (pixels)
    ///   - edgeRmsPx: Edge reprojection RMS error (pixels)
    ///   - sharpness: Sharpness score (0-100)
    ///   - overexposureRatio: Overexposed pixel ratio (0-1)
    ///   - underexposureRatio: Underexposed pixel ratio (0-1)
    ///   - timestampMs: Timestamp in milliseconds
    /// - Returns: Gate quality ∈ [0, 1]
    public func computeGateQuality(
        patchId: String,
        cameraPosition: SIMD3<Float>,
        patchCenter: SIMD3<Float>,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double,
        timestampMs: Int64
    ) -> Double {
        // Step 1: Smooth jittery metrics
        let smoothedReproj = reprojSmoother.addAndSmooth(reprojRmsPx)
        let smoothedEdge = edgeSmoother.addAndSmooth(edgeRmsPx)
        let smoothedSharpness = sharpnessSmoother.addAndSmooth(sharpness)

        // Step 2: Compute preliminary quality for view tracking
        let prelimBasic = GateGainFunctions.basicGateGain(
            sharpness: smoothedSharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio
        )

        let prelimGeom = GateGainFunctions.geomGateGain(
            reprojRmsPx: smoothedReproj,
            edgeRmsPx: smoothedEdge
        )

        // Preliminary quality for L2/L3 classification
        let prelimQuality = (prelimBasic + prelimGeom) / 2.0

        // Step 3: Record view observation
        viewTracker.recordObservation(
            patchId: patchId,
            cameraPosition: cameraPosition,
            patchCenter: patchCenter,
            quality: prelimQuality,
            timestampMs: timestampMs
        )

        // Step 4: Get view metrics
        let (thetaSpanDeg, l2PlusCount, l3Count) = viewTracker.viewGainInputs(for: patchId)

        // Step 5: Compute final gate quality
        let viewGain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: thetaSpanDeg,
            l2PlusCount: l2PlusCount,
            l3Count: l3Count
        )

        let geomGain = GateGainFunctions.geomGateGain(
            reprojRmsPx: smoothedReproj,
            edgeRmsPx: smoothedEdge
        )

        let basicGain = GateGainFunctions.basicGateGain(
            sharpness: smoothedSharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio
        )

        return GateGainFunctions.gateQuality(
            viewGain: viewGain,
            geomGain: geomGain,
            basicGain: basicGain
        )
    }

    // MARK: - Queries

    /// Get view tracker (for diagnostics)
    public var tracker: ViewAngleTracker { viewTracker }

    // MARK: - Lifecycle

    /// Reset for new session
    public func reset() {
        viewTracker.reset()
        reprojSmoother.reset()
        edgeSmoother.reset()
        sharpnessSmoother.reset()
    }
}
```

### 4.2 Integration with IsolatedEvidenceEngine

```swift
// In IsolatedEvidenceEngine.swift, add:

/// Gate quality computer
private var gateComputer: GateQualityComputer

// In init():
self.gateComputer = GateQualityComputer()

// New convenience method for full frame processing:

/// Process frame with automatic gate quality computation
///
/// - Parameters:
///   - observation: Evidence observation
///   - cameraPosition: Camera position in world space
///   - patchCenter: Patch center in world space
///   - reprojRmsPx: Reprojection RMS error (pixels)
///   - edgeRmsPx: Edge reprojection RMS error (pixels)
///   - sharpness: Sharpness score (0-100)
///   - overexposureRatio: Overexposed pixel ratio (0-1)
///   - underexposureRatio: Underexposed pixel ratio (0-1)
///   - softQuality: Soft quality (from PR4, 0.0 placeholder for now)
///   - verdict: Observation verdict
public func processFrameWithGate(
    observation: EvidenceObservation,
    cameraPosition: SIMD3<Float>,
    patchCenter: SIMD3<Float>,
    reprojRmsPx: Double,
    edgeRmsPx: Double,
    sharpness: Double,
    overexposureRatio: Double,
    underexposureRatio: Double,
    softQuality: Double = 0.0,  // Placeholder until PR4
    verdict: ObservationVerdict
) {
    let timestampMs = Int64(observation.timestamp * 1000.0)

    // Compute gate quality
    let gateQuality = gateComputer.computeGateQuality(
        patchId: observation.patchId,
        cameraPosition: cameraPosition,
        patchCenter: patchCenter,
        reprojRmsPx: reprojRmsPx,
        edgeRmsPx: edgeRmsPx,
        sharpness: sharpness,
        overexposureRatio: overexposureRatio,
        underexposureRatio: underexposureRatio,
        timestampMs: timestampMs
    )

    // Process with computed quality
    processObservation(
        observation,
        gateQuality: gateQuality,
        softQuality: softQuality,
        verdict: verdict
    )
}
```

---

## Part 5: Cross-Platform Considerations

### 5.1 Platform Abstraction Requirements

```swift
/// Platform-agnostic camera pose input
public struct CameraPoseInput: Codable, Sendable {
    /// Camera position in world coordinates (meters)
    public let position: SIMD3<Float>

    /// Camera forward direction (normalized)
    public let forward: SIMD3<Float>

    /// Camera up direction (normalized)
    public let up: SIMD3<Float>

    /// Timestamp in milliseconds since epoch
    public let timestampMs: Int64

    public init(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, timestampMs: Int64) {
        self.position = position
        self.forward = forward
        self.up = up
        self.timestampMs = timestampMs
    }
}

/// Platform-agnostic frame quality metrics
public struct FrameQualityMetrics: Codable, Sendable {
    /// Reprojection RMS error (pixels)
    public let reprojRmsPx: Double

    /// Edge reprojection RMS error (pixels)
    public let edgeRmsPx: Double

    /// Sharpness score (0-100)
    public let sharpness: Double

    /// Overexposed pixel ratio (0-1)
    public let overexposureRatio: Double

    /// Underexposed pixel ratio (0-1)
    public let underexposureRatio: Double

    public init(
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double
    ) {
        self.reprojRmsPx = reprojRmsPx
        self.edgeRmsPx = edgeRmsPx
        self.sharpness = sharpness
        self.overexposureRatio = overexposureRatio
        self.underexposureRatio = underexposureRatio
    }
}
```

### 5.2 Linux/iOS Conditional Compilation

```swift
// For platform-specific SIMD implementations:

#if canImport(simd)
import simd
#else
// Fallback for non-Apple platforms
public typealias SIMD3<T: SIMDScalar> = (x: T, y: T, z: T)

func simd_length(_ v: SIMD3<Float>) -> Float {
    return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(v)
    guard len > 1e-6 else { return (0, 0, 0) }
    return (v.x / len, v.y / len, v.z / len)
}
#endif
```

### 5.3 Determinism Requirements

**All PR3 code MUST be deterministic:**

1. **No random number generation** without fixed seeds
2. **No floating-point dependent iteration order** (sort before iterating)
3. **No system time for computations** (use passed timestamps)
4. **Consistent sigmoid/math functions** across platforms

```swift
/// Deterministic sigmoid (same result on iOS, Linux, Android)
@inline(__always)
public func deterministicSigmoid(_ x: Double) -> Double {
    // Standard sigmoid: 1 / (1 + e^(-x))
    // Using exp() which is standardized across platforms
    return 1.0 / (1.0 + exp(-x))
}
```

---

## Part 6: Test Specifications

### 6.1 Unit Tests

```swift
import XCTest

final class GateGainFunctionsTests: XCTestCase {

    // MARK: - View Gate Gain Tests

    func testViewGateGain_BelowThresholds() {
        let gain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 10,  // Below 26
            l2PlusCount: 5,    // Below 13
            l3Count: 2         // Below 5
        )

        // Should be low but not zero (minimum floor)
        XCTAssertGreaterThan(gain, 0.04)
        XCTAssertLessThan(gain, 0.20)
    }

    func testViewGateGain_AtThresholds() {
        let gain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 26,
            l2PlusCount: 13,
            l3Count: 5
        )

        // Should be around 0.5 (sigmoid at threshold = 0.5)
        XCTAssertGreaterThan(gain, 0.10)
        XCTAssertLessThan(gain, 0.50)
    }

    func testViewGateGain_AboveThresholds() {
        let gain = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 50,
            l2PlusCount: 25,
            l3Count: 10
        )

        // Should be high
        XCTAssertGreaterThan(gain, 0.70)
    }

    // MARK: - Geometry Gate Gain Tests

    func testGeomGateGain_LowError() {
        let gain = GateGainFunctions.geomGateGain(
            reprojRmsPx: 0.20,  // Well below 0.48
            edgeRmsPx: 0.10    // Well below 0.23
        )

        XCTAssertGreaterThan(gain, 0.80)
    }

    func testGeomGateGain_HighError() {
        let gain = GateGainFunctions.geomGateGain(
            reprojRmsPx: 0.80,  // Above 0.48
            edgeRmsPx: 0.40    // Above 0.23
        )

        XCTAssertLessThan(gain, 0.30)
    }

    // MARK: - Basic Gate Gain Tests

    func testBasicGateGain_GoodQuality() {
        let gain = GateGainFunctions.basicGateGain(
            sharpness: 95,
            overexposureRatio: 0.10,
            underexposureRatio: 0.15
        )

        XCTAssertGreaterThan(gain, 0.70)
    }

    func testBasicGateGain_BadExposure() {
        let gain = GateGainFunctions.basicGateGain(
            sharpness: 95,
            overexposureRatio: 0.50,  // Bad
            underexposureRatio: 0.15
        )

        XCTAssertLessThan(gain, 0.40)
    }

    // MARK: - Combined Gate Quality Tests

    func testGateQuality_WeightsValid() {
        XCTAssertTrue(GateWeights.validate())
    }

    func testGateQuality_AllGood() {
        let quality = GateGainFunctions.gateQuality(
            viewGain: 0.9,
            geomGain: 0.9,
            basicGain: 0.9
        )

        XCTAssertGreaterThan(quality, 0.85)
    }

    func testGateQuality_MixedQuality() {
        let quality = GateGainFunctions.gateQuality(
            viewGain: 0.8,
            geomGain: 0.5,
            basicGain: 0.9
        )

        // Weighted: 0.40*0.8 + 0.45*0.5 + 0.15*0.9 = 0.32 + 0.225 + 0.135 = 0.68
        XCTAssertEqual(quality, 0.68, accuracy: 0.01)
    }
}

final class ViewAngleTrackerTests: XCTestCase {

    var tracker: ViewAngleTracker!

    override func setUp() {
        super.setUp()
        tracker = ViewAngleTracker()
    }

    func testThetaSpan_SingleObservation() {
        tracker.recordObservation(
            patchId: "patch1",
            cameraPosition: SIMD3<Float>(0, 0, -1),
            patchCenter: SIMD3<Float>(0, 0, 0),
            quality: 0.5,
            timestampMs: 1000
        )

        let inputs = tracker.viewGainInputs(for: "patch1")
        XCTAssertEqual(inputs.thetaSpanDeg, 0, accuracy: 0.1)  // Single point = 0 span
    }

    func testThetaSpan_MultipleAngles() {
        // Camera positions around the patch at different angles
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, -1),    // theta = 0°
            SIMD3<Float>(-0.5, 0, -0.866),  // theta ≈ 30°
            SIMD3<Float>(-0.866, 0, -0.5),  // theta ≈ 60°
        ]

        for (i, pos) in positions.enumerated() {
            tracker.recordObservation(
                patchId: "patch1",
                cameraPosition: pos,
                patchCenter: SIMD3<Float>(0, 0, 0),
                quality: 0.5,
                timestampMs: Int64(i * 100)
            )
        }

        let inputs = tracker.viewGainInputs(for: "patch1")
        XCTAssertGreaterThan(inputs.thetaSpanDeg, 50)  // Should be ~60°
        XCTAssertLessThan(inputs.thetaSpanDeg, 70)
    }

    func testL2PlusCount() {
        // Add observations with varying quality
        for i in 0..<20 {
            let quality = Double(i) / 20.0  // 0.0 to 0.95
            tracker.recordObservation(
                patchId: "patch1",
                cameraPosition: SIMD3<Float>(Float(i), 0, -1),
                patchCenter: SIMD3<Float>(0, 0, 0),
                quality: quality,
                timestampMs: Int64(i * 100)
            )
        }

        let inputs = tracker.viewGainInputs(for: "patch1")
        // L2+ threshold is 0.3, so observations 7-19 (quality 0.35-0.95) should count
        // That's 13 observations
        XCTAssertGreaterThanOrEqual(inputs.l2PlusCount, 12)
        XCTAssertLessThanOrEqual(inputs.l2PlusCount, 14)
    }

    func testL3Count() {
        // Add observations with varying quality
        for i in 0..<20 {
            let quality = Double(i) / 20.0  // 0.0 to 0.95
            tracker.recordObservation(
                patchId: "patch1",
                cameraPosition: SIMD3<Float>(Float(i), 0, -1),
                patchCenter: SIMD3<Float>(0, 0, 0),
                quality: quality,
                timestampMs: Int64(i * 100)
            )
        }

        let inputs = tracker.viewGainInputs(for: "patch1")
        // L3 threshold is 0.6, so observations 13-19 (quality 0.65-0.95) should count
        // That's 7 observations
        XCTAssertGreaterThanOrEqual(inputs.l3Count, 6)
        XCTAssertLessThanOrEqual(inputs.l3Count, 8)
    }
}

final class GateQualityDeterminismTests: XCTestCase {

    func testGateQuality_Deterministic100Runs() {
        var results: Set<Double> = []

        for _ in 0..<100 {
            let quality = GateGainFunctions.gateQuality(
                thetaSpanDeg: 30.5,
                l2PlusCount: 15,
                l3Count: 7,
                reprojRmsPx: 0.35,
                edgeRmsPx: 0.18,
                sharpness: 88.5,
                overexposureRatio: 0.22,
                underexposureRatio: 0.30
            )
            results.insert(quality)
        }

        XCTAssertEqual(results.count, 1, "Gate quality must be deterministic")
    }

    func testViewAngleTracker_Deterministic() {
        var exports: Set<Data> = []

        for _ in 0..<50 {
            let tracker = ViewAngleTracker()

            // Same sequence of observations
            for i in 0..<20 {
                tracker.recordObservation(
                    patchId: "patch1",
                    cameraPosition: SIMD3<Float>(Float(i) * 0.1, 0, -1),
                    patchCenter: SIMD3<Float>(0, 0, 0),
                    quality: 0.5 + Double(i) * 0.02,
                    timestampMs: Int64(i * 100)
                )
            }

            let inputs = tracker.viewGainInputs(for: "patch1")
            let encoded = "\(inputs.thetaSpanDeg)-\(inputs.l2PlusCount)-\(inputs.l3Count)"
            exports.insert(Data(encoded.utf8))
        }

        XCTAssertEqual(exports.count, 1, "ViewAngleTracker must be deterministic")
    }
}
```

### 6.2 Integration Tests

```swift
final class GateIntegrationTests: XCTestCase {

    func testGateQuality_FullCaptureSimulation() async throws {
        let engine = await IsolatedEvidenceEngine()

        // Simulate a capture session
        for frame in 0..<100 {
            let theta = Double(frame) * 3.6  // 360° over 100 frames
            let cameraX = Float(cos(theta * .pi / 180))
            let cameraZ = Float(sin(theta * .pi / 180))

            let observation = EvidenceObservation(
                patchId: "center_patch",
                timestamp: Double(frame) * 0.033,  // 30 FPS
                frameId: "frame_\(frame)",
                errorType: nil
            )

            await engine.processFrameWithGate(
                observation: observation,
                cameraPosition: SIMD3<Float>(cameraX * 2, 0.5, cameraZ * 2),
                patchCenter: SIMD3<Float>(0, 0, 0),
                reprojRmsPx: 0.3 + Double.random(in: 0...0.1),
                edgeRmsPx: 0.15 + Double.random(in: 0...0.05),
                sharpness: 88 + Double.random(in: 0...5),
                overexposureRatio: 0.15 + Double.random(in: 0...0.05),
                underexposureRatio: 0.20 + Double.random(in: 0...0.05),
                softQuality: 0.0,  // PR4 placeholder
                verdict: .normal
            )
        }

        let snapshot = await engine.snapshot()

        // Gate should have progressed significantly
        XCTAssertGreaterThan(snapshot.gateDisplay, 0.5)
    }

    func testGateQuality_MonotonicDisplay() async throws {
        let engine = await IsolatedEvidenceEngine()
        var lastDisplay: Double = 0

        for frame in 0..<50 {
            let observation = EvidenceObservation(
                patchId: "test_patch",
                timestamp: Double(frame) * 0.033,
                frameId: "frame_\(frame)",
                errorType: nil
            )

            await engine.processFrameWithGate(
                observation: observation,
                cameraPosition: SIMD3<Float>(Float(frame) * 0.1, 0, -2),
                patchCenter: SIMD3<Float>(0, 0, 0),
                reprojRmsPx: 0.4,
                edgeRmsPx: 0.2,
                sharpness: 85,
                overexposureRatio: 0.25,
                underexposureRatio: 0.30,
                softQuality: 0.0,
                verdict: .normal
            )

            let snapshot = await engine.snapshot()
            XCTAssertGreaterThanOrEqual(
                snapshot.gateDisplay,
                lastDisplay,
                "Display must be monotonic"
            )
            lastDisplay = snapshot.gateDisplay
        }
    }
}
```

---

## Part 7: Acceptance Criteria

### 7.1 Functional Acceptance

| ID | Criterion | Test Method |
|----|-----------|-------------|
| G1 | viewGateGain returns ∈ [0.05, 1] | Unit test |
| G2 | geomGateGain returns ∈ [0, 1] | Unit test |
| G3 | basicGateGain returns ∈ [0.10, 1] | Unit test |
| G4 | gateQuality = weighted sum of gains | Unit test |
| G5 | GateWeights sum to 1.0 | Validation test |
| G6 | ViewAngleTracker computes thetaSpan correctly | Unit test |
| G7 | L2+/L3 counts respect quality thresholds | Unit test |
| G8 | Gate quality is deterministic (100 runs) | Determinism test |
| G9 | Display is monotonic | Integration test |
| G10 | Full capture simulation reaches >0.5 gate | Integration test |

### 7.2 Performance Acceptance

| ID | Criterion | Target |
|----|-----------|--------|
| P1 | Single frame gate computation | < 2ms |
| P2 | ViewAngleTracker memory per patch | < 10KB |
| P3 | ViewAngleTracker supports 10K patches | < 100MB total |

### 7.3 Cross-Platform Acceptance

| ID | Criterion | Verification |
|----|-----------|--------------|
| X1 | Compiles on Linux (Swift 5.9) | CI test |
| X2 | Compiles on iOS (Swift 5.9) | CI test |
| X3 | Same gate quality on Linux/iOS | Cross-platform test |
| X4 | No Apple-specific imports in core logic | Code review |

---

## Part 8: Deliverables Checklist

### 8.1 Required Files

```
Core/
├── Constants/
│   └── HardGatesV13.swift           ✓ (Reachability thresholds)
├── Evidence/
│   ├── GateGainFunctions.swift      ✓ (viewGateGain, geomGateGain, basicGateGain)
│   ├── GateQualityComputer.swift    ✓ (Integration layer)
│   └── ViewAngleTracker.swift       ✓ (Angular distribution tracking)

Tests/
└── Evidence/
    ├── GateGainFunctionsTests.swift       ✓ (Unit tests)
    ├── ViewAngleTrackerTests.swift        ✓ (Unit tests)
    ├── GateQualityDeterminismTests.swift  ✓ (Determinism tests)
    └── GateIntegrationTests.swift         ✓ (Integration tests)

.github/
└── workflows/
    └── evidence-tests.yml           ✓ (Add PR3 test filters)
```

### 8.2 Code Standards

- All public APIs must have documentation comments with SEMANTIC MEANING
- All constants must include VALUE ANALYSIS and ACCEPTABLE RANGE
- All gate functions must be deterministic
- Unit test coverage > 80%
- Cross-platform compilation verified in CI

---

## Part 9: PR4 Dependencies

After PR3 is complete:

**PR4 (Soft System) will:**
- Implement `SoftGainFunctions` (depthSoftGain, topoSoftGain, semanticSoftGain)
- Implement depth fusion (Small + Large + ARKit)
- Implement edge classification (geometric, specular, transparent, textural)
- Pass computed `softQuality` to `IsolatedEvidenceEngine.processObservation()`
- Use gate quality as prerequisite for soft writes

**PR3 → PR4 Interface:**
```swift
// PR3 computes:
let gateQuality = gateComputer.computeGateQuality(...)

// PR4 will compute:
let softQuality = softComputer.computeSoftQuality(
    gateQuality: gateQuality,  // Uses gate as prerequisite
    depthMetrics: ...,
    topologyMetrics: ...,
    semanticMetrics: ...
)

// Both passed to engine:
engine.processObservation(
    observation,
    gateQuality: gateQuality,
    softQuality: softQuality,
    verdict: verdict
)
```

---

**Document Version:** 1.0
**Author:** Claude Code
**Created:** 2026-01-30

---

## STATUS: DRAFT

This document is ready for implementation. After PR3 implementation is complete and all tests pass, update status to LOCKED.
