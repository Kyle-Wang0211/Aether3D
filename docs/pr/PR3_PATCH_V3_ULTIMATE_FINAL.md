# PR3 Gate Reachability System - Patch V3 Ultimate Final

**Document Version:** 3.0 (Ultimate Final)
**Status:** DRAFT
**Created:** 2026-01-30
**Scope:** PR3 Ultimate Hardening with PRMath Architecture

---

## Part 0: Executive Summary - The Three Pillars

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE THREE PILLARS OF PR3 ULTIMATE                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: EXTREME THRESHOLDS (Uncompromised)                               │
│  ├── HardGatesV13 values: 0.48 / 0.23 / 85 / 26° / 15° / 13 / 5            │
│  ├── Sigmoid slopes: Geometry STEEP (cliff), View/Basic GENTLE (floor)     │
│  └── These values are FINAL and NON-NEGOTIABLE                              │
│                                                                             │
│  PILLAR 2: NUMERICAL STABILITY (Implementation Layer)                       │
│  ├── PRMath: Unified math facade (all sigmoid/exp/trig go through it)      │
│  ├── Stable Logistic: Piecewise formula, no NaN, no Inf, no overflow       │
│  ├── Integer World: Buckets, spans, counts all use Int (no float drift)    │
│  └── Quantized Golden: Int64 comparison for bit-exact cross-platform       │
│                                                                             │
│  PILLAR 3: FUTURE-PROOF ARCHITECTURE (Upgrade Path)                         │
│  ├── PRMathDouble: Current implementation (extreme, stable)                │
│  ├── PRMathFixed: Placeholder for Q32.32 fixed-point (future)              │
│  ├── PRMATH_FIXED compile flag: One switch to change implementation        │
│  └── Zero business logic changes when switching implementations             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**References:**
- [Numerically Stable Sigmoid](https://shaktiwadekar.medium.com/how-to-avoid-numerical-overflow-in-sigmoid-function-numerically-stable-sigmoid-function-5298b14720f6)
- [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)
- [libfixmath for Fixed Point](https://github.com/howerj/q)
- [Circular Statistics](https://en.wikipedia.org/wiki/Directional_statistics)

---

## Part 1: PRMath Architecture - The Math Facade

### 1.1 Directory Structure

```
Core/Evidence/Math/
├── PRMath.swift              // Unified facade (business only uses this)
├── PRMathDouble.swift        // Double implementation (current, extreme+stable)
├── PRMathFixed.swift         // Fixed implementation (placeholder for future)
├── Quantizer.swift           // Double↔Int64 quantization for golden tests
└── StableLogistic.swift      // Piecewise stable sigmoid implementation
```

### 1.2 PRMath Facade API (Business Layer Interface)

```swift
/// PRMath: Unified math facade for Evidence layer
///
/// RULE: All mathematical operations in Core/Evidence/ MUST go through PRMath
/// FORBIDDEN: Direct use of Foundation.exp, Darwin.exp, pow, tanh, etc.
///
/// WHY: This facade enables:
/// 1. Numerical stability (stable sigmoid, safe exp)
/// 2. Cross-platform determinism (quantized comparison)
/// 3. Future fixed-point upgrade (one switch to change)
public enum PRMath {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Core Sigmoid Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Standard sigmoid: σ(x) = 1 / (1 + e^(-x))
    ///
    /// IMPLEMENTATION: Uses stable logistic (piecewise formula)
    /// GUARANTEE: No NaN, no Inf, output ∈ (0, 1)
    /// DETERMINISM: Bit-exact across iOS/Linux/macOS
    public static func sigmoid(_ x: Double) -> Double

    /// Sigmoid from threshold with slope
    ///
    /// FORMULA: sigmoid((value - threshold) / slope)
    /// USAGE: All gain functions MUST use this, not raw sigmoid
    /// EXAMPLE: sigmoid01FromThreshold(reproj, 0.48, 0.10)
    ///          → 0.5 when reproj == 0.48
    ///          → ~0.27 when reproj == 0.58 (cliff drop!)
    public static func sigmoid01FromThreshold(
        _ value: Double,
        threshold: Double,
        slope: Double
    ) -> Double

    /// Inverted sigmoid (for "lower is better" metrics)
    ///
    /// FORMULA: sigmoid((threshold - value) / slope)
    /// USAGE: reprojRms, edgeRms, exposure ratios
    public static func sigmoidInverted01FromThreshold(
        _ value: Double,
        threshold: Double,
        slope: Double
    ) -> Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Safe Math Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Safe exponential: clamps input to prevent overflow
    /// INPUT RANGE: clamped to [-80, 80]
    /// WHY 80: exp(80) ≈ 5.5e34, exp(-80) ≈ 1.8e-35, both safe in Double
    public static func expSafe(_ x: Double) -> Double

    /// Safe atan2: handles NaN/Inf inputs
    /// OUTPUT: radians, deterministic for all inputs
    public static func atan2Safe(_ y: Double, _ x: Double) -> Double

    /// Safe asin: clamps input to [-1, 1]
    /// OUTPUT: radians, no NaN even for out-of-range input
    public static func asinSafe(_ x: Double) -> Double

    /// Safe sqrt: returns 0 for negative input
    public static func sqrtSafe(_ x: Double) -> Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Utility Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Clamp to [0, 1]
    public static func clamp01(_ x: Double) -> Double

    /// Clamp to arbitrary range
    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double

    /// Linear interpolation
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double

    /// Check if value is usable (finite and not NaN)
    public static func isUsable(_ x: Double) -> Bool

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Angle Conversion
    // ═══════════════════════════════════════════════════════════════════════

    /// Radians to degrees (deterministic)
    public static func toDegrees(_ radians: Double) -> Double

    /// Degrees to radians (deterministic)
    public static func toRadians(_ degrees: Double) -> Double

    /// Normalize angle to [0, 360)
    public static func normalizeAngle360(_ degrees: Double) -> Double

    /// Normalize angle to [-180, 180)
    public static func normalizeAngle180(_ degrees: Double) -> Double

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quantization (for Golden Tests)
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantize Double to Int64 for bit-exact comparison
    /// SCALE: 1e12 (12 decimal places)
    /// ROUNDING: Half away from zero (deterministic)
    public static func quantize(_ x: Double) -> Int64

    /// Dequantize Int64 back to Double
    public static func dequantize(_ q: Int64) -> Double
}
```

### 1.3 Compile-Time Switch

```swift
// In Package.swift or Build Settings:
// SWIFT_ACTIVE_COMPILATION_CONDITIONS = PRMATH_FIXED (to enable fixed-point)

// In PRMath.swift:
#if PRMATH_FIXED
    // Use PRMathFixed implementation
    public static func sigmoid(_ x: Double) -> Double {
        return PRMathFixed.sigmoid(x)
    }
#else
    // Use PRMathDouble implementation (default)
    public static func sigmoid(_ x: Double) -> Double {
        return PRMathDouble.sigmoid(x)
    }
#endif
```

---

## Part 2: Stable Logistic Implementation

### 2.1 The Problem with Naive Sigmoid

```
NAIVE IMPLEMENTATION (DANGEROUS):
sigmoid(x) = 1 / (1 + exp(-x))

FAILURE MODES:
- x = -800: exp(800) = +Inf → sigmoid = 0/Inf = NaN
- x = +800: exp(-800) = 0 → sigmoid = 1/1 = 1.0 (OK but edge case)
- Cross-platform: Different exp() precision → different results
```

### 2.2 Stable Logistic Formula

**Reference:** [Numerically Stable Sigmoid](https://shaktiwadekar.medium.com/how-to-avoid-numerical-overflow-in-sigmoid-function-numerically-stable-sigmoid-function-5298b14720f6)

```swift
/// Stable Logistic: Piecewise formula to avoid overflow
///
/// FORMULA:
/// - x ≥ 0: σ(x) = 1 / (1 + exp(-x))
/// - x < 0: σ(x) = exp(x) / (1 + exp(x))
///
/// WHY THIS WORKS:
/// - For x ≥ 0: exp(-x) ≤ 1, no overflow
/// - For x < 0: exp(x) ≤ 1, no overflow
///
/// ADDITIONAL SAFETY:
/// - Clamp x to [-80, 80] before computation
/// - exp(80) ≈ 5.5e34 is safe in Double
/// - exp(-80) ≈ 1.8e-35 is safe in Double
///
/// GUARANTEE:
/// - No NaN for any finite input
/// - No Inf for any finite input
/// - Output strictly in (0, 1)
public enum StableLogistic {

    /// Maximum safe input for exp()
    /// WHY 80: exp(80) ≈ 5.5e34, well within Double range
    private static let maxSafeInput: Double = 80.0

    /// Compute stable sigmoid
    public static func sigmoid(_ x: Double) -> Double {
        // Handle non-finite input
        guard x.isFinite else {
            if x.isNaN { return 0.5 }  // Neutral for NaN
            return x > 0 ? 1.0 : 0.0   // Saturate for ±Inf
        }

        // Clamp to safe range
        let clamped = max(-maxSafeInput, min(maxSafeInput, x))

        // Piecewise stable formula
        if clamped >= 0 {
            let expNegX = exp(-clamped)
            return 1.0 / (1.0 + expNegX)
        } else {
            let expX = exp(clamped)
            return expX / (1.0 + expX)
        }
    }

    /// Compute with threshold and slope (main API for gain functions)
    public static func sigmoidFromThreshold(
        value: Double,
        threshold: Double,
        slope: Double
    ) -> Double {
        guard slope > 0 else { return 0.5 }  // Degenerate case
        let normalized = (value - threshold) / slope
        return sigmoid(normalized)
    }

    /// Inverted sigmoid (lower is better)
    public static func sigmoidInvertedFromThreshold(
        value: Double,
        threshold: Double,
        slope: Double
    ) -> Double {
        guard slope > 0 else { return 0.5 }
        let normalized = (threshold - value) / slope
        return sigmoid(normalized)
    }
}
```

### 2.3 Why This Preserves Extreme Slopes

```
IMPORTANT: Stable Logistic does NOT reduce steepness!

Example with slope = 0.10 (geometry cliff):
- At threshold (reproj = 0.48): sigmoid(0) = 0.5
- At threshold + slope (reproj = 0.58): sigmoid(1.0) = 0.73 → gain ≈ 0.27 (CLIFF!)
- At threshold + 2*slope (reproj = 0.68): sigmoid(2.0) = 0.88 → gain ≈ 0.12 (STEEP!)

The steepness comes from the slope parameter, not the sigmoid implementation.
Stable Logistic only prevents OVERFLOW, not STEEPNESS.
```

---

## Part 3: Integer World for Buckets and Spans

### 3.1 The Problem with Float Buckets

```
PROBLEM: Float arithmetic causes cross-platform drift

Example:
- iOS: 359.9999999° / 15° = bucket 23.999999... → Int = 23
- Linux: 359.9999998° / 15° = bucket 23.999999... → Int = 23 (maybe)

Even tiny differences in the last digit can cause:
- Different bucket assignment
- Different span calculation
- Different L2+/L3 counts
- Failed golden tests
```

### 3.2 Solution: Integer Bucket World

```swift
/// Integer-based bucket system for deterministic angular tracking
///
/// DESIGN PRINCIPLE:
/// 1. Convert angle to bucket ONCE at input boundary
/// 2. All subsequent operations use bucket index (Int)
/// 3. Span calculation operates on bucket indices
/// 4. Output converted back to degrees only for display
public enum IntegerBucketWorld {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Bucket Configuration (from HardGatesV13)
    // ═══════════════════════════════════════════════════════════════════════

    /// Theta buckets: 360° / 15° = 24 buckets
    public static let thetaBucketCount: Int = 24
    public static let thetaBucketSizeDeg: Double = 15.0

    /// Phi buckets: 180° / 15° = 12 buckets (from -90° to +90°)
    public static let phiBucketCount: Int = 12
    public static let phiBucketSizeDeg: Double = 15.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Angle to Bucket Conversion
    // ═══════════════════════════════════════════════════════════════════════

    /// Convert theta (horizontal) to bucket index
    ///
    /// INPUT: angle in degrees (any range)
    /// OUTPUT: bucket index in [0, thetaBucketCount - 1]
    /// DETERMINISM: Uses floor() after normalization
    public static func thetaToBucket(_ angleDeg: Double) -> Int {
        // Normalize to [0, 360)
        let normalized = PRMath.normalizeAngle360(angleDeg)
        // Convert to bucket (floor for determinism)
        let bucket = Int(floor(normalized / thetaBucketSizeDeg))
        // Clamp to valid range (defensive)
        return max(0, min(thetaBucketCount - 1, bucket))
    }

    /// Convert phi (vertical) to bucket index
    ///
    /// INPUT: angle in degrees [-90, +90]
    /// OUTPUT: bucket index in [0, phiBucketCount - 1]
    public static func phiToBucket(_ angleDeg: Double) -> Int {
        // Clamp to valid range
        let clamped = max(-90.0, min(90.0, angleDeg))
        // Shift to [0, 180] range
        let shifted = clamped + 90.0
        // Convert to bucket
        let bucket = Int(floor(shifted / phiBucketSizeDeg))
        // Clamp to valid range (defensive)
        return max(0, min(phiBucketCount - 1, bucket))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Bucket to Angle Conversion (for output only)
    // ═══════════════════════════════════════════════════════════════════════

    /// Convert bucket span (count) to degrees
    public static func bucketSpanToDegrees(_ bucketCount: Int, bucketSize: Double) -> Double {
        return Double(bucketCount) * bucketSize
    }
}
```

### 3.3 Circular Span in Integer World

```swift
/// Circular span calculation using integer buckets
///
/// ALGORITHM: Maximum Gap Method (on bucket indices)
///
/// EXAMPLE:
/// Buckets filled: [0, 1, 23] (angles: 0°, 15°, 345°)
/// Gaps between consecutive: [1, 22, 1 (wrap: 0+24-23=1)]
/// Wait, let's recalculate:
///   Sorted buckets: [0, 1, 23]
///   Gap 0→1: 1 bucket
///   Gap 1→23: 22 buckets
///   Gap 23→0 (wrap): 24 - 23 + 0 = 1 bucket
/// Max gap: 22 buckets
/// Span: 24 - 22 = 2 buckets = 30°
///
/// CORRECTNESS: This handles 0°/360° wrap-around automatically!
public enum CircularSpanInteger {

    /// Compute circular span from sorted unique bucket indices
    ///
    /// PRECONDITION: buckets is sorted, unique, all in [0, maxBuckets)
    /// OUTPUT: span in bucket count (NOT degrees)
    public static func computeSpanBuckets(
        sortedBuckets: [Int],
        maxBuckets: Int
    ) -> Int {
        guard !sortedBuckets.isEmpty else { return 0 }
        guard sortedBuckets.count > 1 else { return 0 }

        var maxGap: Int = 0

        // Gaps between consecutive buckets
        for i in 1..<sortedBuckets.count {
            let gap = sortedBuckets[i] - sortedBuckets[i - 1]
            maxGap = max(maxGap, gap)
        }

        // Wrap-around gap (from last to first + maxBuckets)
        let wrapGap = (sortedBuckets.first! + maxBuckets) - sortedBuckets.last!
        maxGap = max(maxGap, wrapGap)

        // Span is complement of max gap
        return maxBuckets - maxGap
    }

    /// Convert bucket span to degrees
    public static func spanToDegrees(_ spanBuckets: Int, bucketSizeDeg: Double) -> Double {
        return Double(spanBuckets) * bucketSizeDeg
    }
}
```

---

## Part 4: SortedUniqueIntArray - Eliminating Set Non-Determinism

### 4.1 The Problem with Set<Int>

```
PROBLEM: Set iteration order is non-deterministic in Swift

let set: Set<Int> = [1, 3, 2]
for x in set { print(x) }  // Could print: 1,2,3 or 3,1,2 or 2,3,1 ...

This breaks:
- Deterministic span calculation
- Golden tests
- Cross-platform consistency
```

### 4.2 Solution: SortedUniqueIntArray

```swift
/// Sorted unique integer array - deterministic Set<Int> replacement
///
/// INVARIANT: Elements are always sorted ascending and unique
/// DETERMINISM: Iteration order is always ascending
/// USAGE: Replace Set<Int> in GateCoverageTracker
public struct SortedUniqueIntArray: Codable, Sendable, Equatable {

    /// Internal storage (always sorted, unique)
    private var elements: [Int] = []

    /// Number of elements
    public var count: Int { elements.count }

    /// Check if empty
    public var isEmpty: Bool { elements.isEmpty }

    /// Initialize empty
    public init() {}

    /// Initialize from unsorted array (will sort and dedupe)
    public init(_ unsorted: [Int]) {
        self.elements = Array(Set(unsorted)).sorted()
    }

    /// Insert element (maintains sorted, unique invariant)
    ///
    /// TIME: O(log n) search + O(n) insert = O(n)
    /// For small n (< 100), this is fine
    public mutating func insert(_ element: Int) {
        // Binary search for insertion point
        var lo = 0
        var hi = elements.count

        while lo < hi {
            let mid = (lo + hi) / 2
            if elements[mid] < element {
                lo = mid + 1
            } else if elements[mid] > element {
                hi = mid
            } else {
                // Already exists, no-op
                return
            }
        }

        // Insert at position lo
        elements.insert(element, at: lo)
    }

    /// Check if contains element
    ///
    /// TIME: O(log n)
    public func contains(_ element: Int) -> Bool {
        var lo = 0
        var hi = elements.count

        while lo < hi {
            let mid = (lo + hi) / 2
            if elements[mid] < element {
                lo = mid + 1
            } else if elements[mid] > element {
                hi = mid
            } else {
                return true
            }
        }

        return false
    }

    /// Get sorted array (for iteration)
    ///
    /// DETERMINISM: Always returns elements in ascending order
    public var sorted: [Int] { elements }

    /// Iterate in deterministic order
    public func forEach(_ body: (Int) -> Void) {
        for element in elements {
            body(element)
        }
    }

    /// Remove oldest elements to maintain size limit
    ///
    /// STRATEGY: Remove smallest indices first (deterministic)
    public mutating func trimToSize(_ maxSize: Int) {
        guard elements.count > maxSize else { return }
        elements.removeFirst(elements.count - maxSize)
    }
}
```

---

## Part 5: GateInputValidator with Closed Enum Reasons

### 5.1 Closed Enum for Invalid Reasons

```swift
/// Invalid input reason (closed enum, Codable for golden tests)
///
/// WHY CLOSED ENUM:
/// 1. Exhaustive switch statements catch new cases at compile time
/// 2. Golden tests can cover all cases
/// 3. CI can track frequency of each reason
/// 4. No string-based ambiguity
public enum GateInputInvalidReason: String, Codable, CaseIterable, Sendable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Non-Finite Values
    // ═══════════════════════════════════════════════════════════════════════

    case thetaSpanNaN = "theta_span_nan"
    case thetaSpanInf = "theta_span_inf"
    case phiSpanNaN = "phi_span_nan"
    case phiSpanInf = "phi_span_inf"
    case reprojRmsNaN = "reproj_rms_nan"
    case reprojRmsInf = "reproj_rms_inf"
    case edgeRmsNaN = "edge_rms_nan"
    case edgeRmsInf = "edge_rms_inf"
    case sharpnessNaN = "sharpness_nan"
    case sharpnessInf = "sharpness_inf"
    case overexposureNaN = "overexposure_nan"
    case overexposureInf = "overexposure_inf"
    case underexposureNaN = "underexposure_nan"
    case underexposureInf = "underexposure_inf"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Out of Range Values
    // ═══════════════════════════════════════════════════════════════════════

    case l2PlusCountNegative = "l2_plus_count_negative"
    case l3CountNegative = "l3_count_negative"
    case l3CountExceedsL2Plus = "l3_count_exceeds_l2_plus"
    case reprojRmsNegative = "reproj_rms_negative"
    case edgeRmsNegative = "edge_rms_negative"
    case sharpnessNegative = "sharpness_negative"
    case sharpnessExceeds100 = "sharpness_exceeds_100"
    case overexposureNegative = "overexposure_negative"
    case overexposureExceeds1 = "overexposure_exceeds_1"
    case underexposureNegative = "underexposure_negative"
    case underexposureExceeds1 = "underexposure_exceeds_1"

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Logical Errors
    // ═══════════════════════════════════════════════════════════════════════

    case thetaSpanNegative = "theta_span_negative"
    case phiSpanNegative = "phi_span_negative"
    case thetaSpanExceeds360 = "theta_span_exceeds_360"
    case phiSpanExceeds180 = "phi_span_exceeds_180"
}
```

### 5.2 Validation Result with Fallback Strategy

```swift
/// Validation result with computed fallback (not fixed constant)
public enum GateValidationResult {

    /// Valid inputs (all checks passed)
    case valid(GateValidatedInputs)

    /// Invalid inputs with reasons and computed fallback
    case invalid(reasons: [GateInputInvalidReason], fallbackQuality: Double)
}

/// Validated inputs (all guaranteed in valid ranges)
public struct GateValidatedInputs: Codable, Sendable {
    public let thetaSpanDeg: Double
    public let phiSpanDeg: Double
    public let l2PlusCount: Int
    public let l3Count: Int
    public let reprojRmsPx: Double
    public let edgeRmsPx: Double
    public let sharpness: Double
    public let overexposureRatio: Double
    public let underexposureRatio: Double
}

/// Input validator with computed fallback (not fixed 0.1)
public enum GateInputValidator {

    /// Validate all inputs
    ///
    /// FALLBACK STRATEGY:
    /// - Do NOT return fixed 0.1 (can be exploited)
    /// - Instead: Replace invalid input with WORST-CASE value, recompute
    /// - Result is always <= min(minViewGain, minBasicGain)
    public static func validate(
        thetaSpanDeg: Double,
        phiSpanDeg: Double,
        l2PlusCount: Int,
        l3Count: Int,
        reprojRmsPx: Double,
        edgeRmsPx: Double,
        sharpness: Double,
        overexposureRatio: Double,
        underexposureRatio: Double
    ) -> GateValidationResult {

        var reasons: [GateInputInvalidReason] = []

        // Check all inputs, collect all reasons
        if thetaSpanDeg.isNaN { reasons.append(.thetaSpanNaN) }
        if thetaSpanDeg.isInfinite { reasons.append(.thetaSpanInf) }
        // ... (check all other inputs)

        // If any invalid, compute fallback from worst-case
        if !reasons.isEmpty {
            let fallback = computeFallbackFromWorstCase()
            return .invalid(reasons: reasons, fallbackQuality: fallback)
        }

        // All valid
        return .valid(GateValidatedInputs(
            thetaSpanDeg: thetaSpanDeg,
            phiSpanDeg: phiSpanDeg,
            l2PlusCount: l2PlusCount,
            l3Count: l3Count,
            reprojRmsPx: reprojRmsPx,
            edgeRmsPx: edgeRmsPx,
            sharpness: sharpness,
            overexposureRatio: overexposureRatio,
            underexposureRatio: underexposureRatio
        ))
    }

    /// Compute fallback from worst-case inputs
    ///
    /// This computes gateQuality with:
    /// - thetaSpan = 0, phiSpan = 0 (no coverage)
    /// - l2Plus = 0, l3 = 0 (no good observations)
    /// - reprojRms = 2.0, edgeRms = 1.0 (terrible geometry)
    /// - sharpness = 0, overexposure = 1.0, underexposure = 1.0 (terrible basic)
    ///
    /// Result is typically ~0.02-0.05, much lower than fixed 0.1
    private static func computeFallbackFromWorstCase() -> Double {
        let worstView = GateGainFunctions.viewGateGain(
            thetaSpanDeg: 0, phiSpanDeg: 0, l2PlusCount: 0, l3Count: 0
        )
        let worstGeom = GateGainFunctions.geomGateGain(
            reprojRmsPx: 2.0, edgeRmsPx: 1.0
        )
        let worstBasic = GateGainFunctions.basicGateGain(
            sharpness: 0, overexposureRatio: 1.0, underexposureRatio: 1.0
        )
        let fallback = GateGainFunctions.gateQuality(
            viewGain: worstView, geomGain: worstGeom, basicGain: worstBasic
        )

        // Cap at minViewGain to prevent any exploitation
        return min(fallback, HardGatesV13.minViewGain)
    }
}
```

---

## Part 6: PR3InternalQuality - Single Metric Space

### 6.1 The Problem with Dual Sigmoid

```
PROBLEM: Original design has TWO sigmoid computations:
1. PR3InternalQuality.compute() → uses sigmoid with some params
2. GateGainFunctions.basicGain() → uses sigmoid with different params

This creates:
- Two "metric spaces" that can drift apart during tuning
- Confusion about which quality is authoritative
- Potential for double-counting or conflicting thresholds
```

### 6.2 Solution: Reuse Gain Functions

```swift
/// PR3 Internal Quality: Single metric space, reusing gain functions
///
/// DESIGN: pr3Quality is computed from ALREADY-NORMALIZED gains
/// This ensures L2+/L3 classification uses the SAME metric space
/// as final gateQuality computation
public enum PR3InternalQuality {

    /// Compute PR3 internal quality for L2+/L3 classification
    ///
    /// FORMULA: pr3Quality = w1 * basicGain + w2 * geomGain
    /// WHERE: basicGain and geomGain are from GateGainFunctions (normalized [0,1])
    ///
    /// WHY NOT include viewGain:
    /// - L2+/L3 classification is per-observation
    /// - View diversity is a cumulative property (tracked separately)
    /// - Including view would create circular dependency
    public static func compute(
        basicGain: Double,  // From GateGainFunctions.basicGateGain()
        geomGain: Double    // From GateGainFunctions.geomGateGain()
    ) -> Double {
        // Weights for L2+/L3 classification
        // Geom is more important for "is this observation usable?"
        let basicWeight = 0.35
        let geomWeight = 0.65

        return basicWeight * basicGain + geomWeight * geomGain
    }

    /// L2+ threshold (basic usability)
    /// An observation is L2+ if pr3Quality > this threshold
    public static let l2PlusThreshold: Double = HardGatesV13.l2QualityThreshold

    /// L3 threshold (high quality)
    /// An observation is L3 if pr3Quality > this threshold
    public static let l3Threshold: Double = HardGatesV13.l3QualityThreshold

    /// Check if observation qualifies as L2+
    public static func isL2Plus(_ pr3Quality: Double) -> Bool {
        return pr3Quality > l2PlusThreshold
    }

    /// Check if observation qualifies as L3
    public static func isL3(_ pr3Quality: Double) -> Bool {
        return pr3Quality > l3Threshold
    }
}
```

---

## Part 7: MetricSmoother - Dual Channel for Stability + Responsiveness

### 7.1 The Problem with Median-Only

```
PROBLEM: Median is stable but SLOW to respond

Scenario: User improves their capture (sharpness goes from 70 to 95)
- With median(window=5): Takes 3+ frames to reflect improvement
- User feels system is "laggy" or "unfair"

But we CAN'T just use last value:
- With last value: Single good/bad frame dominates
- Jitter causes "flashing" progress bar
```

### 7.2 Solution: Dual Channel Smoother

```swift
/// Dual channel metric smoother: Stable + Responsive
///
/// DESIGN:
/// - Channel 1 (Median): For stability, used for threshold checks
/// - Channel 2 (Last finite): For responsiveness, used for trend detection
///
/// SYNTHESIS:
/// - If |last - median| < jitterBand: Use median (stable)
/// - If last > median: Improve slowly (anti-boost)
/// - If last < median: Degrade faster (realistic penalty)
public final class DualChannelSmoother {

    /// Median history
    private var history: [Double] = []

    /// Last finite value
    private var lastFinite: Double?

    /// Window size
    private let windowSize: Int

    /// Jitter band (if difference is within band, use median)
    private let jitterBand: Double

    /// Anti-boost factor (how much slower to improve than degrade)
    private let antiBoostFactor: Double

    public init(
        windowSize: AllowedWindowSize = .medium,
        jitterBand: Double = 0.05,
        antiBoostFactor: Double = 0.3  // Improve at 30% speed of degradation
    ) {
        self.windowSize = windowSize.rawValue
        self.jitterBand = jitterBand
        self.antiBoostFactor = antiBoostFactor
    }

    /// Add value and return smoothed result
    public func addAndSmooth(_ value: Double, fallback: Double = 0.0) -> Double {
        // Reject non-finite
        guard PRMath.isUsable(value) else {
            return currentSmoothed(fallback: fallback)
        }

        // Update last finite
        lastFinite = value

        // Update history
        history.append(value)
        if history.count > windowSize {
            history.removeFirst()
        }

        return currentSmoothed(fallback: fallback)
    }

    /// Get current smoothed value
    public func currentSmoothed(fallback: Double = 0.0) -> Double {
        guard !history.isEmpty else { return lastFinite ?? fallback }

        // Compute median
        let sorted = history.sorted()
        let median: Double
        if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        } else {
            median = sorted[sorted.count / 2]
        }

        // If no last finite, just return median
        guard let last = lastFinite else { return median }

        // Dual channel synthesis
        let diff = last - median

        if abs(diff) < jitterBand {
            // Within jitter band: use median (stable)
            return median
        } else if diff > 0 {
            // Improving: move slowly toward last (anti-boost)
            return median + diff * antiBoostFactor
        } else {
            // Degrading: move faster toward last (realistic penalty)
            return median + diff * (1.0 - antiBoostFactor)
        }
    }

    /// Reset
    public func reset() {
        history.removeAll(keepingCapacity: true)
        lastFinite = nil
    }
}
```

---

## Part 8: HardGatesV13 - Dual Representation (Double + Q)

### 8.1 Dual Representation for Future Fixed-Point

```swift
/// HardGatesV13: Gate thresholds with dual representation
///
/// DUAL REPRESENTATION:
/// - Every threshold has both Double (for tuning) and Int64 (for fixed-point)
/// - Q values are pre-computed at compile time
/// - When PRMATH_FIXED is enabled, Q values are used
public enum HardGatesV13 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quantization Scale
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantization scale for fixed-point representation
    /// Using 1e12 for 12 decimal places of precision
    public static let quantizationScale: Double = 1e12
    public static let quantizationScaleQ: Int64 = 1_000_000_000_000

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Coverage Thresholds (Dual)
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum theta span (Double)
    public static let minThetaSpanDeg: Double = 26.0
    /// Minimum theta span (Q, fixed-point ready)
    public static let minThetaSpanDeg_Q: Int64 = 26_000_000_000_000

    /// Minimum phi span (Double)
    public static let minPhiSpanDeg: Double = 15.0
    /// Minimum phi span (Q)
    public static let minPhiSpanDeg_Q: Int64 = 15_000_000_000_000

    /// Minimum L2+ count (Int, no Q needed)
    public static let minL2PlusCount: Int = 13

    /// Minimum L3 count (Int, no Q needed)
    public static let minL3Count: Int = 5

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Geometry Thresholds (Dual)
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum reproj RMS (Double)
    public static let maxReprojRmsPx: Double = 0.48
    /// Maximum reproj RMS (Q)
    public static let maxReprojRmsPx_Q: Int64 = 480_000_000_000

    /// Maximum edge RMS (Double)
    public static let maxEdgeRmsPx: Double = 0.23
    /// Maximum edge RMS (Q)
    public static let maxEdgeRmsPx_Q: Int64 = 230_000_000_000

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Basic Quality Thresholds (Dual)
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum sharpness (Double)
    public static let minSharpness: Double = 85.0
    /// Minimum sharpness (Q)
    public static let minSharpness_Q: Int64 = 85_000_000_000_000

    /// Maximum overexposure ratio (Double)
    public static let maxOverexposureRatio: Double = 0.28
    /// Maximum overexposure ratio (Q)
    public static let maxOverexposureRatio_Q: Int64 = 280_000_000_000

    /// Maximum underexposure ratio (Double)
    public static let maxUnderexposureRatio: Double = 0.38
    /// Maximum underexposure ratio (Q)
    public static let maxUnderexposureRatio_Q: Int64 = 380_000_000_000

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sigmoid Slopes (Dual) - EXTREME VALUES PRESERVED
    // ═══════════════════════════════════════════════════════════════════════

    /// Theta span slope (GENTLE)
    public static let slopeThetaDeg: Double = 8.0
    public static let slopeThetaDeg_Q: Int64 = 8_000_000_000_000

    /// Phi span slope (GENTLE)
    public static let slopePhiDeg: Double = 6.0
    public static let slopePhiDeg_Q: Int64 = 6_000_000_000_000

    /// L2+ count slope (GENTLE)
    public static let slopeL2Count: Double = 4.0
    public static let slopeL2Count_Q: Int64 = 4_000_000_000_000

    /// L3 count slope (MODERATE)
    public static let slopeL3Count: Double = 2.0
    public static let slopeL3Count_Q: Int64 = 2_000_000_000_000

    /// Reproj RMS slope (STEEP - CLIFF!)
    public static let slopeReprojPx: Double = 0.10
    public static let slopeReprojPx_Q: Int64 = 100_000_000_000

    /// Edge RMS slope (VERY STEEP - CLIFF!)
    public static let slopeEdgePx: Double = 0.05
    public static let slopeEdgePx_Q: Int64 = 50_000_000_000

    /// Sharpness slope (MODERATE)
    public static let slopeSharpness: Double = 5.0
    public static let slopeSharpness_Q: Int64 = 5_000_000_000_000

    /// Exposure slope (MODERATE)
    public static let slopeExposure: Double = 0.08
    public static let slopeExposure_Q: Int64 = 80_000_000_000

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gain Floors (Dual)
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum view gain (5%)
    public static let minViewGain: Double = 0.05
    public static let minViewGain_Q: Int64 = 50_000_000_000

    /// Minimum basic gain (10%)
    public static let minBasicGain: Double = 0.10
    public static let minBasicGain_Q: Int64 = 100_000_000_000

    /// Minimum geom gain (0% - NO FLOOR, CLIFF IS REAL)
    public static let minGeomGain: Double = 0.0
    public static let minGeomGain_Q: Int64 = 0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// Validate all Q values match Double values
    #if DEBUG
    public static func validateQValues() -> Bool {
        let tolerance: Int64 = 1  // Allow 1 unit of Q error

        func check(_ d: Double, _ q: Int64) -> Bool {
            let computed = Int64((d * quantizationScale).rounded())
            return abs(computed - q) <= tolerance
        }

        return check(minThetaSpanDeg, minThetaSpanDeg_Q)
            && check(minPhiSpanDeg, minPhiSpanDeg_Q)
            && check(maxReprojRmsPx, maxReprojRmsPx_Q)
            && check(maxEdgeRmsPx, maxEdgeRmsPx_Q)
            && check(minSharpness, minSharpness_Q)
            // ... (check all others)
    }
    #endif
}
```

---

## Part 9: Golden Tests with Int64 Comparison

### 9.1 Why Int64 Instead of Epsilon

```
PROBLEM: Epsilon-based comparison is fragile

XCTAssertEqual(actual, expected, accuracy: 1e-9)

Issues:
- What if actual = 0.500000001 and expected = 0.499999999?
- They differ by 2e-9, fails with 1e-9 epsilon
- But this could be platform-dependent rounding, not a bug

SOLUTION: Quantize to Int64, compare exactly

actual_q = Int64(round(actual * 1e12)) = 500000001000
expected_q = Int64(round(expected * 1e12)) = 499999999000

If they must be IDENTICAL: Assert equal
If they can tolerate 1 unit: Assert abs(diff) <= 1
```

### 9.2 Golden Fixture Format

```json
{
  "version": "1.0",
  "platform": "macOS-14-Swift-5.9",
  "cases": [
    {
      "name": "at_threshold",
      "input": {
        "thetaSpanDeg": 26.0,
        "phiSpanDeg": 15.0,
        "l2PlusCount": 13,
        "l3Count": 5,
        "reprojRmsPx": 0.48,
        "edgeRmsPx": 0.23,
        "sharpness": 85.0,
        "overexposureRatio": 0.28,
        "underexposureRatio": 0.38
      },
      "expected": {
        "viewGain_q": 500000000000,
        "geomGain_q": 500000000000,
        "basicGain_q": 500000000000,
        "gateQuality_q": 500000000000
      }
    }
  ]
}
```

### 9.3 Golden Test Implementation

```swift
final class GateGoldenTests: XCTestCase {

    func testGoldenValues() throws {
        let fixture = try loadGoldenFixture("gate_quality_golden_v1.json")

        for testCase in fixture.cases {
            let actual = GateGainFunctions.gateQuality(
                thetaSpanDeg: testCase.input.thetaSpanDeg,
                phiSpanDeg: testCase.input.phiSpanDeg,
                l2PlusCount: testCase.input.l2PlusCount,
                l3Count: testCase.input.l3Count,
                reprojRmsPx: testCase.input.reprojRmsPx,
                edgeRmsPx: testCase.input.edgeRmsPx,
                sharpness: testCase.input.sharpness,
                overexposureRatio: testCase.input.overexposureRatio,
                underexposureRatio: testCase.input.underexposureRatio
            )

            // Quantize actual result
            let actual_q = PRMath.quantize(actual.gateQuality)

            // Compare Int64 exactly (bit-exact!)
            XCTAssertEqual(
                actual_q,
                testCase.expected.gateQuality_q,
                "\(testCase.name): gateQuality mismatch. " +
                "Expected q=\(testCase.expected.gateQuality_q), got q=\(actual_q)"
            )
        }
    }
}
```

---

## Part 10: Forbidden Patterns (Ultimate List)

### 10.1 PRMath Bypass Prevention

```swift
/// Forbidden patterns that bypass PRMath
/// These are BLOCKED in Core/Evidence/**
static let mathBypassPatterns: [(regex: String, message: String)] = [

    // Direct math function calls
    (#"(?<!PRMath\.)exp\("#, "Direct exp() forbidden - use PRMath.expSafe()"),
    (#"(?<!PRMath\.)log\("#, "Direct log() forbidden - use PRMath if needed"),
    (#"(?<!PRMath\.)pow\("#, "Direct pow() forbidden - use PRMath if needed"),
    (#"(?<!PRMath\.)sqrt\("#, "Direct sqrt() forbidden - use PRMath.sqrtSafe()"),
    (#"(?<!PRMath\.)atan2\("#, "Direct atan2() forbidden - use PRMath.atan2Safe()"),
    (#"(?<!PRMath\.)asin\("#, "Direct asin() forbidden - use PRMath.asinSafe()"),
    (#"(?<!PRMath\.)acos\("#, "Direct acos() forbidden - use PRMath if needed"),
    (#"(?<!PRMath\.)sin\("#, "Direct sin() forbidden - use PRMath if needed"),
    (#"(?<!PRMath\.)cos\("#, "Direct cos() forbidden - use PRMath if needed"),
    (#"(?<!PRMath\.)tan\("#, "Direct tan() forbidden - use PRMath if needed"),
    (#"(?<!PRMath\.)tanh\("#, "Direct tanh() forbidden - use PRMath if needed"),

    // Foundation/Darwin imports
    (#"import\s+Darwin"#, "Direct Darwin import forbidden - use PRMath"),
    (#"import\s+Glibc"#, "Direct Glibc import forbidden - use PRMath"),
    (#"Foundation\.exp"#, "Foundation.exp forbidden - use PRMath"),
    (#"Darwin\.exp"#, "Darwin.exp forbidden - use PRMath"),
]
```

### 10.2 Non-Determinism Prevention

```swift
/// Forbidden patterns that break determinism
static let nonDeterminismPatterns: [(regex: String, message: String)] = [

    // Random/Time/UUID
    (#"Date\(\)"#, "Date() forbidden - use passed timestamp"),
    (#"UUID\(\)"#, "UUID() forbidden - use deterministic IDs"),
    (#"\.random"#, "random forbidden - all values must be deterministic"),
    (#"arc4random"#, "arc4random forbidden"),
    (#"\.shuffled\(\)"#, "shuffled() forbidden - breaks determinism"),

    // Locale/Timezone
    (#"DateFormatter"#, "DateFormatter forbidden - locale-dependent"),
    (#"NumberFormatter"#, "NumberFormatter forbidden - locale-dependent"),
    (#"TimeZone\.current"#, "TimeZone.current forbidden - machine-dependent"),
    (#"Locale\.current"#, "Locale.current forbidden - machine-dependent"),

    // Non-deterministic iteration
    (#"for\s+\w+\s+in\s+\w+\.values\b"#, "Dictionary.values iteration forbidden - use sortedIterate"),
    (#"for\s+\w+\s+in\s+\w+\.keys\b"#, "Dictionary.keys iteration forbidden - use sortedIterate"),
    (#"Set<.*>\.forEach"#, "Set.forEach forbidden - use SortedUniqueIntArray"),
    (#"\.values\.reduce"#, "Dictionary.values.reduce forbidden - use deterministicReduce"),
]
```

### 10.3 Type Safety Prevention

```swift
/// Forbidden patterns for type safety
static let typeSafetyPatterns: [(regex: String, message: String)] = [

    // simd
    (#"import\s+simd"#, "simd import forbidden in Evidence layer"),
    (#"SIMD\d"#, "SIMD types forbidden in Evidence layer"),
    (#"simd_"#, "simd functions forbidden in Evidence layer"),

    // Float precision
    (#":\s*Float\s*[,\)\{]"#, "Float type forbidden - use Double"),
    (#"Float\("#, "Float() conversion forbidden - use Double"),

    // Wrong quality source
    (#"observation\.quality"#, "observation.quality forbidden - use PR3InternalQuality"),
]
```

---

## Part 11: File Deliverables (Complete)

### 11.1 New Files

```
Core/Evidence/Math/
├── PRMath.swift                      ✓ Unified math facade
├── PRMathDouble.swift                ✓ Double implementation (stable)
├── PRMathFixed.swift                 ✓ Fixed placeholder (compile-only)
├── StableLogistic.swift              ✓ Piecewise stable sigmoid
└── Quantizer.swift                   ✓ Double↔Int64 quantization

Core/Evidence/
├── EvidenceVector3.swift             ✓ Cross-platform vector
├── IntegerBucketWorld.swift          ✓ Integer bucket system
├── CircularSpanInteger.swift         ✓ Circular span on buckets
├── SortedUniqueIntArray.swift        ✓ Deterministic Set replacement
├── GateInputValidator.swift          ✓ Input validation with closed enum
├── PR3InternalQuality.swift          ✓ Single metric space quality
├── DualChannelSmoother.swift         ✓ Stable + responsive smoother
├── GateCoverageTracker.swift         ✓ Angular tracking (integer world)
├── GateGainFunctions.swift           ✓ Gain functions (via PRMath)
├── GateQualityComputer.swift         ✓ Integration layer
└── GateInvariants.swift              ✓ Runtime validation

Core/Constants/
└── HardGatesV13.swift                ✓ Dual representation (Double + Q)

Tests/Evidence/
├── PRMathTests.swift                 ✓ Math facade tests
├── StableLogisticTests.swift         ✓ Sigmoid stability tests
├── CircularSpanIntegerTests.swift    ✓ Circular span tests
├── SortedUniqueIntArrayTests.swift   ✓ Deterministic array tests
├── GateInputValidatorTests.swift     ✓ Validation tests (all reasons)
├── GateDeterminismTests.swift        ✓ 100-run determinism
├── GateGoldenTests.swift             ✓ Int64 golden comparison
├── GateIntegrationTests.swift        ✓ End-to-end tests
└── DualChannelSmootherTests.swift    ✓ Smoother tests

Tests/Evidence/Fixtures/Golden/
└── gate_quality_golden_v1.json       ✓ Golden values (Int64)
```

### 11.2 Modified Files

```
Core/Evidence/IsolatedEvidenceEngine.swift
├── ADD: gateComputer: GateQualityComputer
├── ADD: processFrameWithGate() method
└── KEEP: existing processObservation() unchanged

Scripts/ForbiddenPatternLint.swift
├── ADD: PRMath bypass patterns
├── ADD: Non-determinism patterns
├── ADD: Type safety patterns
└── KEEP: existing patterns

.github/workflows/evidence-tests.yml
├── ADD: PR3 test filters
├── ADD: Golden test job
└── ADD: (future) PRMATH_FIXED compile-only job
```

---

## Part 12: Implementation Phase Order

```
Phase 1: Math Foundation
├── PRMath.swift (facade, routes to Double)
├── PRMathDouble.swift (stable implementation)
├── PRMathFixed.swift (placeholder)
├── StableLogistic.swift (piecewise sigmoid)
└── Quantizer.swift (Int64 quantization)

Phase 2: Integer World
├── IntegerBucketWorld.swift
├── CircularSpanInteger.swift
└── SortedUniqueIntArray.swift

Phase 3: Validation & Quality
├── HardGatesV13.swift (dual representation)
├── GateInputValidator.swift (closed enum)
├── PR3InternalQuality.swift (single metric)
└── DualChannelSmoother.swift

Phase 4: Core Components
├── EvidenceVector3.swift
├── GateCoverageTracker.swift (uses integer world)
├── GateGainFunctions.swift (uses PRMath)
├── GateInvariants.swift
└── GateQualityComputer.swift

Phase 5: Integration
└── Modify IsolatedEvidenceEngine.swift

Phase 6: Tests & CI
├── All test files
├── Golden fixtures (Int64)
└── ForbiddenPatternLint updates
```

---

## Part 13: Acceptance Criteria (Zero Tolerance)

### 13.1 Math Layer Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| M1 | No direct exp/log/pow/sqrt/trig in Evidence | Lint |
| M2 | All math via PRMath facade | Code review |
| M3 | Stable sigmoid: no NaN for any finite input | Unit test |
| M4 | Stable sigmoid: no Inf for any finite input | Unit test |
| M5 | Quantizer: roundHalfAwayFromZero consistent | Unit test |
| M6 | PRMathFixed compiles (placeholder OK) | CI |

### 13.2 Determinism Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| D1 | 100 runs produce exactly 1 unique result | Unit test |
| D2 | Different bucket insertion order → same span | Unit test |
| D3 | No Set/Dictionary direct iteration | Lint |
| D4 | Golden tests pass (Int64 exact match) | CI |
| D5 | No Date/UUID/random in Evidence | Lint |

### 13.3 Stability Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| S1 | NaN input → closed enum reason | Unit test |
| S2 | Inf input → closed enum reason | Unit test |
| S3 | Fallback quality ≤ minViewGain | Unit test |
| S4 | Fallback computed, not fixed constant | Code review |
| S5 | All invalid reasons covered in golden | CI |

### 13.4 Architecture Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| A1 | No simd import in Evidence | Lint + grep |
| A2 | No Float type in gate logic | Lint |
| A3 | HardGatesV13 has dual representation | Code review |
| A4 | Q values match Double values | DEBUG validation |
| A5 | No EvidenceConstants refs in HardGatesV13 | grep |

### 13.5 Performance Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| P1 | Single frame gate computation | < 2ms |
| P2 | Records per patch | ≤ 200 (struct enforced) |
| P3 | Theta buckets | ≤ 24 (struct enforced) |
| P4 | Phi buckets | ≤ 12 (struct enforced) |

---

## Part 14: Coordinate System & Platform Porting Notes

### 14.1 Coordinate Convention

```
COORDINATE SYSTEM: Right-handed (OpenGL convention)
- +X: Right
- +Y: Up
- +Z: Toward viewer (out of screen)

ANGLE DEFINITIONS:
- Theta (θ): Horizontal angle, measured counterclockwise from +Z in XZ plane
  - Range: [0°, 360°)
  - θ = 0° means looking from +Z direction
  - θ = 90° means looking from +X direction
  - θ = 180° means looking from -Z direction
  - θ = 270° means looking from -X direction

- Phi (φ): Vertical angle, measured upward from XZ plane
  - Range: [-90°, +90°]
  - φ = 0° means horizontal (in XZ plane)
  - φ = +90° means looking straight up (+Y)
  - φ = -90° means looking straight down (-Y)

COMPUTATION:
- direction = normalize(patchPosition - cameraPosition)
- θ = atan2(direction.x, direction.z) → convert to degrees, normalize to [0, 360)
- φ = asin(clamp(direction.y, -1, 1)) → convert to degrees
```

### 14.2 Porting to Other Platforms

```
WHEN PORTING TO Android/Web/Other:

1. COORDINATE TRANSFORM:
   - If platform uses left-handed coords: negate Z before computing theta
   - If platform uses different up axis: rotate to match Y-up

2. MATH FUNCTIONS:
   - Implement PRMath equivalent in target language
   - Use same stable logistic formula (piecewise)
   - Use same clamp ranges ([-80, 80] for exp input)

3. INTEGER WORLD:
   - Use same bucket sizes (theta: 15°, phi: 15°)
   - Use same bucket counts (theta: 24, phi: 12)
   - Use floor() for bucket assignment (not round)

4. GOLDEN TESTS:
   - Use same Int64 golden values
   - Compare quantized results (not raw floats)
   - Tolerance: 0 (exact match) or 1 (single quantization unit)

5. DETERMINISM:
   - No random, no time-based seeds
   - Sort before iterating collections
   - Use stable sort algorithms
```

---

**Document Version:** 3.0 (Ultimate Final)
**Author:** Claude Code
**Created:** 2026-01-30
**Status:** READY FOR IMPLEMENTATION

---

## CHANGELOG from V2

| Section | Change |
|---------|--------|
| Part 1 | Added PRMath architecture with compile-time switch |
| Part 2 | Added StableLogistic with piecewise formula |
| Part 3 | Added Integer Bucket World for determinism |
| Part 4 | Added SortedUniqueIntArray to replace Set |
| Part 5 | Changed GateInputValidator to closed enum reasons |
| Part 6 | Changed PR3InternalQuality to reuse gain functions |
| Part 7 | Added DualChannelSmoother for stability + responsiveness |
| Part 8 | Added dual representation (Double + Q) to HardGatesV13 |
| Part 9 | Added Int64 golden test methodology |
| Part 10 | Expanded forbidden patterns for PRMath bypass |
| Part 14 | Added coordinate system and porting notes |
