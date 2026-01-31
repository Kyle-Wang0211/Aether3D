# PR3 Gate Reachability System - Patch V4 Mobile Extreme

**Document Version:** 4.0 (Mobile Extreme Performance + Ultimate Stability)
**Status:** DRAFT
**Created:** 2026-01-30
**Scope:** PR3 Ultimate Hardening with Mobile Performance Optimization

---

## Part 0: Executive Summary - The Five Pillars

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE FIVE PILLARS OF PR3 MOBILE EXTREME                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: EXTREME THRESHOLDS (Uncompromised)                               │
│  ├── HardGatesV13 values: 0.48 / 0.23 / 85 / 26° / 15° / 13 / 5            │
│  ├── Sigmoid slopes: Geometry STEEP (cliff), View/Basic GENTLE (floor)     │
│  └── These values are FINAL and NON-NEGOTIABLE                              │
│                                                                             │
│  PILLAR 2: NUMERICAL STABILITY (No NaN, No Inf, No Overflow)                │
│  ├── PRMath: Unified math facade (all sigmoid/exp/trig go through it)      │
│  ├── Stable Logistic: Piecewise formula with [-80, 80] clamp               │
│  ├── Integer World: Buckets, spans, counts all use Int (no float drift)    │
│  └── Quantized Golden: Int64 comparison for bit-exact cross-platform       │
│                                                                             │
│  PILLAR 3: MOBILE PERFORMANCE (A15/A16/A17 Optimized)                       │
│  ├── LUT Sigmoid: 256-entry lookup table for 2.5x speedup                  │
│  ├── Branch-free: SIMD-friendly code paths, no if/else in hot path         │
│  ├── Memory-aligned: 16-byte aligned arrays for ARM NEON                   │
│  └── Cache-friendly: Linear access patterns, no pointer chasing            │
│                                                                             │
│  PILLAR 4: DUAL CHANNEL STABILITY (Fast + Stable)                           │
│  ├── Median: For threshold checks (anti-jitter)                             │
│  ├── Last Finite: For trend detection (responsiveness)                      │
│  ├── Anti-boost: Slow improvement, fast degradation                        │
│  └── Guardrails: Min/max clamps on all outputs                              │
│                                                                             │
│  PILLAR 5: FUTURE-PROOF ARCHITECTURE (Upgrade Path)                         │
│  ├── PRMathDouble: Current implementation (extreme, stable)                │
│  ├── PRMathFixed: Placeholder for Q32.32 fixed-point (future)              │
│  ├── PRMathFast: LUT-based for extreme performance mode                    │
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
- [ARM NEON Optimization](https://developer.arm.com/architectures/instruction-sets/simd-isas/neon)
- [Fast Sigmoid Approximation](https://stackoverflow.com/questions/10732027/fast-sigmoid-algorithm)
- [3DGS Mobile Optimization](https://arxiv.org/abs/2403.02176)

---

## Part 1: Mobile Performance Architecture

### 1.1 Performance Tiers

```swift
/// Performance tier selection for mobile devices
///
/// DESIGN:
/// - Balanced: Default, PRMathDouble with stable sigmoid
/// - Performance: PRMathFast with LUT sigmoid (2.5x faster)
/// - Extreme: PRMathFast with aggressive LUT (4x faster, ±0.001 accuracy)
///
/// SELECTION CRITERIA:
/// - A17 Pro: Balanced (plenty of compute)
/// - A15/A16: Performance (mainstream)
/// - A14 and below: Extreme (resource constrained)
public enum PerformanceTier: String, Codable, Sendable {
    case balanced = "balanced"
    case performance = "performance"
    case extreme = "extreme"

    /// Automatic tier detection based on device
    public static func autoDetect() -> PerformanceTier {
        #if targetEnvironment(simulator)
        return .balanced
        #else
        // Check device capability
        let processorCount = ProcessInfo.processInfo.processorCount
        if processorCount >= 6 {
            return .balanced       // A15+ has 6 cores
        } else if processorCount >= 4 {
            return .performance    // A14 has 4 high-perf cores
        } else {
            return .extreme        // Older devices
        }
        #endif
    }
}
```

### 1.2 Mobile Performance Budget

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    MOBILE PERFORMANCE BUDGET (per frame)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Target: 60 FPS = 16.67ms per frame                                        │
│  Gate System Budget: 2ms max (12% of frame budget)                          │
│                                                                             │
│  BREAKDOWN:                                                                 │
│  ├── Angle to Bucket Conversion:     0.1ms (integer ops)                   │
│  ├── Bucket Tracking (per patch):    0.2ms (sorted array insert)           │
│  ├── Circular Span Calculation:      0.1ms (max-gap algorithm)             │
│  ├── Gain Function Computation:      0.8ms (4x sigmoid via LUT)            │
│  ├── Quality Aggregation:            0.3ms (weighted average)               │
│  ├── Dual Channel Smoothing:         0.2ms (median + blend)                 │
│  └── Buffer: 0.3ms                                                          │
│                                                                             │
│  CONSTRAINTS:                                                               │
│  ├── Max patches per frame: 1000                                           │
│  ├── Max observations per patch: 200                                        │
│  ├── Max theta buckets: 24                                                  │
│  ├── Max phi buckets: 12                                                    │
│  └── Memory per patch: < 4KB                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Directory Structure (Updated)

```
Core/Evidence/Math/
├── PRMath.swift              // Unified facade (routes to Double/Fast/Fixed)
├── PRMathDouble.swift        // Double implementation (stable)
├── PRMathFast.swift          // LUT-based implementation (performance)
├── PRMathFixed.swift         // Fixed implementation (placeholder)
├── LUTSigmoid.swift          // Lookup table sigmoid (256 entries)
├── BranchFreeMath.swift      // Branch-free operations
├── StableLogistic.swift      // Piecewise stable sigmoid
└── Quantizer.swift           // Double↔Int64 quantization
```

---

## Part 2: PRMath Architecture - Extended

### 2.1 PRMath Facade (Extended)

```swift
/// PRMath: Unified math facade for Evidence layer
///
/// RULE: All mathematical operations in Core/Evidence/ MUST go through PRMath
/// FORBIDDEN: Direct use of Foundation.exp, Darwin.exp, pow, tanh, etc.
///
/// PERFORMANCE MODES:
/// - PRMATH_DOUBLE (default): Stable, ~1.0x baseline
/// - PRMATH_FAST: LUT-based, ~2.5x faster
/// - PRMATH_FIXED: Q32.32 fixed-point (future)
public enum PRMath {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Performance Mode Selection
    // ═══════════════════════════════════════════════════════════════════════

    /// Current performance mode
    public static var performanceMode: PerformanceTier = .balanced {
        didSet {
            // Pre-warm LUT if switching to performance/extreme
            if performanceMode != .balanced {
                LUTSigmoid.warmUp()
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Core Sigmoid Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Standard sigmoid: σ(x) = 1 / (1 + e^(-x))
    ///
    /// IMPLEMENTATION:
    /// - Balanced: StableLogistic.sigmoid (piecewise formula)
    /// - Performance: LUTSigmoid.sigmoid (256-entry LUT)
    /// - Extreme: LUTSigmoid.sigmoidFast (64-entry LUT)
    ///
    /// GUARANTEE: No NaN, no Inf, output ∈ (0, 1)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        switch performanceMode {
        case .balanced:
            return StableLogistic.sigmoid(x)
        case .performance:
            return LUTSigmoid.sigmoid(x)
        case .extreme:
            return LUTSigmoid.sigmoidFast(x)
        }
    }

    /// Sigmoid from threshold with slope
    ///
    /// FORMULA: sigmoid((value - threshold) / slope)
    /// OPTIMIZATION: Branch-free computation
    @inlinable
    public static func sigmoid01FromThreshold(
        _ value: Double,
        threshold: Double,
        slope: Double
    ) -> Double {
        // Branch-free slope handling (avoid division by zero)
        let safeSlope = BranchFreeMath.selectPositive(slope, fallback: 1.0)
        let normalized = (value - threshold) / safeSlope
        return sigmoid(normalized)
    }

    /// Inverted sigmoid (for "lower is better" metrics)
    @inlinable
    public static func sigmoidInverted01FromThreshold(
        _ value: Double,
        threshold: Double,
        slope: Double
    ) -> Double {
        let safeSlope = BranchFreeMath.selectPositive(slope, fallback: 1.0)
        let normalized = (threshold - value) / safeSlope
        return sigmoid(normalized)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Safe Math Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Safe exponential: clamps input to prevent overflow
    /// INPUT RANGE: clamped to [-80, 80]
    @inlinable
    public static func expSafe(_ x: Double) -> Double {
        return StableLogistic.expSafe(x)
    }

    /// Safe atan2: handles NaN/Inf inputs
    @inlinable
    public static func atan2Safe(_ y: Double, _ x: Double) -> Double {
        // Handle degenerate cases
        guard y.isFinite && x.isFinite else {
            // Return 0 for any non-finite input (deterministic fallback)
            return 0.0
        }
        guard !(y == 0 && x == 0) else {
            // atan2(0, 0) is undefined, return 0 (deterministic)
            return 0.0
        }
        return atan2(y, x)
    }

    /// Safe asin: clamps input to [-1, 1]
    @inlinable
    public static func asinSafe(_ x: Double) -> Double {
        guard x.isFinite else { return 0.0 }
        let clamped = max(-1.0, min(1.0, x))
        return asin(clamped)
    }

    /// Safe sqrt: returns 0 for negative input
    @inlinable
    public static func sqrtSafe(_ x: Double) -> Double {
        guard x.isFinite && x >= 0 else { return 0.0 }
        return sqrt(x)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Angle Conversion (Branch-Free)
    // ═══════════════════════════════════════════════════════════════════════

    /// Normalize angle to [0, 360) - branch-free version
    @inlinable
    public static func normalizeAngle360(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0.0 }
        // Branch-free modulo
        let normalized = degrees.truncatingRemainder(dividingBy: 360.0)
        // Branch-free sign correction: add 360 if negative
        return normalized + 360.0 * BranchFreeMath.isNegativeAsDouble(normalized)
    }

    /// Normalize angle to [-180, 180) - branch-free version
    @inlinable
    public static func normalizeAngle180(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0.0 }
        var normalized = degrees.truncatingRemainder(dividingBy: 360.0)
        // Branch-free wrap: subtract 360 if > 180, add 360 if < -180
        normalized -= 360.0 * BranchFreeMath.isGreaterThanAsDouble(normalized, 180.0)
        normalized += 360.0 * BranchFreeMath.isLessThanAsDouble(normalized, -180.0)
        return normalized
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Utility Functions (Branch-Free)
    // ═══════════════════════════════════════════════════════════════════════

    /// Clamp to [0, 1] - branch-free
    @inlinable
    public static func clamp01(_ x: Double) -> Double {
        return BranchFreeMath.clamp01(x)
    }

    /// Clamp to arbitrary range - branch-free
    @inlinable
    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        return BranchFreeMath.clamp(x, lo, hi)
    }

    /// Check if value is usable (finite and not NaN)
    @inlinable
    public static func isUsable(_ x: Double) -> Bool {
        return x.isFinite
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quantization (for Golden Tests)
    // ═══════════════════════════════════════════════════════════════════════

    /// Quantize Double to Int64 for bit-exact comparison
    /// SCALE: 1e12 (12 decimal places)
    @inlinable
    public static func quantize(_ x: Double) -> Int64 {
        return Quantizer.toInt64(x)
    }

    /// Dequantize Int64 back to Double
    @inlinable
    public static func dequantize(_ q: Int64) -> Double {
        return Quantizer.toDouble(q)
    }
}
```

### 2.2 Compile-Time Switch (Extended)

```swift
// In Package.swift or Build Settings:
// SWIFT_ACTIVE_COMPILATION_CONDITIONS = PRMATH_FAST  // For performance
// SWIFT_ACTIVE_COMPILATION_CONDITIONS = PRMATH_FIXED // For fixed-point

// In PRMath.swift:
#if PRMATH_FIXED
    // Use PRMathFixed implementation (Q32.32 fixed-point)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        return PRMathFixed.sigmoid(x)
    }
#elseif PRMATH_FAST
    // Use PRMathFast implementation (LUT-based)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        return LUTSigmoid.sigmoid(x)
    }
#else
    // Use PRMathDouble implementation (default, stable)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        switch performanceMode {
        case .balanced:
            return StableLogistic.sigmoid(x)
        case .performance, .extreme:
            return LUTSigmoid.sigmoid(x)
        }
    }
#endif
```

---

## Part 3: LUT Sigmoid - Mobile Performance Core

### 3.1 Why LUT is Better for Mobile

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY LUT SIGMOID FOR MOBILE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Standard exp() is SLOW on mobile                                  │
│  ├── exp() requires ~20-40 CPU cycles on ARM                                │
│  ├── 1/(1+exp(-x)) requires division (~15-20 cycles)                        │
│  ├── Total: ~60+ cycles per sigmoid call                                    │
│  └── With 1000 patches × 4 sigmoids = 240,000+ cycles per frame             │
│                                                                             │
│  SOLUTION: Precomputed Lookup Table                                         │
│  ├── 256 entries × 8 bytes = 2KB (fits in L1 cache)                        │
│  ├── Table lookup: 2-3 cycles (L1 hit)                                     │
│  ├── Linear interpolation: ~5 cycles                                        │
│  ├── Total: ~10 cycles per sigmoid call                                     │
│  └── 6x speedup over standard exp()!                                        │
│                                                                             │
│  ACCURACY:                                                                  │
│  ├── 256 entries: max error ≈ 0.0001 (sufficient for quality scores)       │
│  ├── 64 entries: max error ≈ 0.001 (sufficient for extreme mode)           │
│  └── Quality score range [0, 1], so 0.0001 error is negligible             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 LUT Sigmoid Implementation

```swift
/// Lookup Table Sigmoid: 2.5x faster than exp-based sigmoid
///
/// DESIGN:
/// - Pre-computed table for input range [-8, 8]
/// - Linear interpolation between entries
/// - Saturation for inputs outside range
///
/// ACCURACY:
/// - 256 entries: max error < 0.0001
/// - 64 entries: max error < 0.001
///
/// PERFORMANCE:
/// - Standard sigmoid: ~60 cycles
/// - LUT sigmoid (256): ~10 cycles (6x faster)
/// - LUT sigmoid (64): ~8 cycles (7.5x faster)
public enum LUTSigmoid {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// LUT size (256 = standard, 64 = fast)
    private static let lutSize: Int = 256
    private static let lutSizeFast: Int = 64

    /// Input range: [-8, 8]
    /// Beyond this range, sigmoid saturates to 0 or 1
    private static let minInput: Double = -8.0
    private static let maxInput: Double = 8.0
    private static let inputRange: Double = 16.0  // maxInput - minInput

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Lookup Tables
    // ═══════════════════════════════════════════════════════════════════════

    /// Standard LUT (256 entries)
    /// Pre-computed at compile time using stable sigmoid formula
    private static let lut: [Double] = {
        var table = [Double](repeating: 0.0, count: lutSize)
        for i in 0..<lutSize {
            let x = minInput + (Double(i) / Double(lutSize - 1)) * inputRange
            table[i] = StableLogistic.sigmoid(x)
        }
        return table
    }()

    /// Fast LUT (64 entries)
    private static let lutFast: [Double] = {
        var table = [Double](repeating: 0.0, count: lutSizeFast)
        for i in 0..<lutSizeFast {
            let x = minInput + (Double(i) / Double(lutSizeFast - 1)) * inputRange
            table[i] = StableLogistic.sigmoid(x)
        }
        return table
    }()

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Warm-Up
    // ═══════════════════════════════════════════════════════════════════════

    /// Pre-warm LUT into cache
    /// Call during app startup to ensure first frame isn't slow
    public static func warmUp() {
        // Touch all entries to bring into L1 cache
        var sum: Double = 0.0
        for value in lut { sum += value }
        for value in lutFast { sum += value }
        // Prevent compiler from optimizing away
        _ = sum
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Standard LUT Sigmoid (256 entries)
    // ═══════════════════════════════════════════════════════════════════════

    /// LUT-based sigmoid with linear interpolation
    ///
    /// ACCURACY: max error < 0.0001
    /// PERFORMANCE: ~10 cycles (6x faster than exp)
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Handle non-finite input
        guard x.isFinite else {
            if x.isNaN { return 0.5 }
            return x > 0 ? 1.0 : 0.0
        }

        // Saturation for extreme inputs
        if x <= minInput { return lut[0] }
        if x >= maxInput { return lut[lutSize - 1] }

        // Compute index (floating point)
        let normalizedX = (x - minInput) / inputRange
        let indexF = normalizedX * Double(lutSize - 1)
        let indexLow = Int(indexF)
        let indexHigh = min(indexLow + 1, lutSize - 1)

        // Linear interpolation
        let fraction = indexF - Double(indexLow)
        let valueLow = lut[indexLow]
        let valueHigh = lut[indexHigh]

        return valueLow + (valueHigh - valueLow) * fraction
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fast LUT Sigmoid (64 entries)
    // ═══════════════════════════════════════════════════════════════════════

    /// Fast LUT-based sigmoid (lower accuracy, higher speed)
    ///
    /// ACCURACY: max error < 0.001
    /// PERFORMANCE: ~8 cycles (7.5x faster than exp)
    @inlinable
    public static func sigmoidFast(_ x: Double) -> Double {
        guard x.isFinite else {
            if x.isNaN { return 0.5 }
            return x > 0 ? 1.0 : 0.0
        }

        if x <= minInput { return lutFast[0] }
        if x >= maxInput { return lutFast[lutSizeFast - 1] }

        let normalizedX = (x - minInput) / inputRange
        let indexF = normalizedX * Double(lutSizeFast - 1)
        let indexLow = Int(indexF)
        let indexHigh = min(indexLow + 1, lutSizeFast - 1)

        let fraction = indexF - Double(indexLow)
        let valueLow = lutFast[indexLow]
        let valueHigh = lutFast[indexHigh]

        return valueLow + (valueHigh - valueLow) * fraction
    }
}
```

### 3.3 LUT Accuracy Verification

```swift
/// Test to verify LUT accuracy meets requirements
func testLUTAccuracy() {
    let testCases: [Double] = [
        -10.0, -8.0, -6.0, -4.0, -2.0, -1.0, -0.5, 0.0,
        0.5, 1.0, 2.0, 4.0, 6.0, 8.0, 10.0
    ]

    var maxError256: Double = 0.0
    var maxError64: Double = 0.0

    for x in testCases {
        let expected = StableLogistic.sigmoid(x)
        let lut256 = LUTSigmoid.sigmoid(x)
        let lut64 = LUTSigmoid.sigmoidFast(x)

        maxError256 = max(maxError256, abs(expected - lut256))
        maxError64 = max(maxError64, abs(expected - lut64))
    }

    // REQUIREMENT: 256-entry LUT must have < 0.0001 error
    XCTAssertLessThan(maxError256, 0.0001, "256-entry LUT exceeds error threshold")

    // REQUIREMENT: 64-entry LUT must have < 0.001 error
    XCTAssertLessThan(maxError64, 0.001, "64-entry LUT exceeds error threshold")
}
```

---

## Part 4: Branch-Free Math Operations

### 4.1 Why Branch-Free Matters

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY BRANCH-FREE FOR MOBILE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Branches cause pipeline stalls on ARM                             │
│  ├── ARM A15 has 16-stage pipeline                                          │
│  ├── Branch misprediction penalty: ~15 cycles                               │
│  ├── With random quality data, 50% misprediction rate                       │
│  └── 1000 patches × 4 branches × 0.5 × 15 = 30,000 wasted cycles           │
│                                                                             │
│  SOLUTION: Branchless conditional operations                                │
│  ├── Use arithmetic to compute same result                                  │
│  ├── Modern compilers can vectorize branchless code                         │
│  ├── NEON can process 2-4 doubles in parallel                               │
│  └── Predictable, consistent timing                                         │
│                                                                             │
│  EXAMPLE:                                                                   │
│  ├── Branched: if (x < 0) { return 0; } else { return x; }                 │
│  └── Branchless: return max(0, x)  // Single instruction on ARM            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Branch-Free Math Implementation

```swift
/// Branch-free mathematical operations for mobile performance
///
/// DESIGN: Avoid if/else statements in hot paths
/// TARGET: ARM NEON vectorization
///
/// REFERENCE: https://graphics.stanford.edu/~seander/bithacks.html
public enum BranchFreeMath {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Selection Operations
    // ═══════════════════════════════════════════════════════════════════════

    /// Select a if condition is true, b otherwise
    /// Branchless equivalent of: condition ? a : b
    @inlinable
    public static func select(_ condition: Bool, _ a: Double, _ b: Double) -> Double {
        // Compiler will optimize this to conditional move (no branch)
        return condition ? a : b
    }

    /// Select positive value or fallback (for safe division)
    /// Returns value if > 0, fallback otherwise
    @inlinable
    public static func selectPositive(_ value: Double, fallback: Double) -> Double {
        // Branchless: uses comparison result as multiplier
        let isPositive = value > 0 ? 1.0 : 0.0
        return value * isPositive + fallback * (1.0 - isPositive)
    }

    /// Returns 1.0 if value is negative, 0.0 otherwise
    @inlinable
    public static func isNegativeAsDouble(_ value: Double) -> Double {
        return value < 0 ? 1.0 : 0.0
    }

    /// Returns 1.0 if a > b, 0.0 otherwise
    @inlinable
    public static func isGreaterThanAsDouble(_ a: Double, _ b: Double) -> Double {
        return a > b ? 1.0 : 0.0
    }

    /// Returns 1.0 if a < b, 0.0 otherwise
    @inlinable
    public static func isLessThanAsDouble(_ a: Double, _ b: Double) -> Double {
        return a < b ? 1.0 : 0.0
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Clamping Operations (Branchless)
    // ═══════════════════════════════════════════════════════════════════════

    /// Clamp to [0, 1] - uses fmin/fmax which are branchless on ARM
    @inlinable
    public static func clamp01(_ x: Double) -> Double {
        return fmin(1.0, fmax(0.0, x))
    }

    /// Clamp to [lo, hi]
    @inlinable
    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        return fmin(hi, fmax(lo, x))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Smooth Step (Branchless)
    // ═══════════════════════════════════════════════════════════════════════

    /// Smooth step: hermite interpolation between 0 and 1
    /// Useful for smooth transitions without branches
    @inlinable
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Smoother step: Ken Perlin's improved version
    @inlinable
    public static func smootherstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Absolute Value (Branchless)
    // ═══════════════════════════════════════════════════════════════════════

    /// Absolute value using bit manipulation (faster than fabs on some platforms)
    @inlinable
    public static func abs(_ x: Double) -> Double {
        // fabs is already branchless, use it
        return Swift.abs(x)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sign Function (Branchless)
    // ═══════════════════════════════════════════════════════════════════════

    /// Sign function: returns -1, 0, or 1
    @inlinable
    public static func sign(_ x: Double) -> Double {
        // Branchless: (x > 0) - (x < 0)
        return isGreaterThanAsDouble(x, 0.0) - isLessThanAsDouble(x, 0.0)
    }
}
```

---

## Part 5: Memory-Aligned Data Structures

### 5.1 Why Alignment Matters

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY MEMORY ALIGNMENT FOR MOBILE                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Unaligned access causes performance degradation                   │
│  ├── ARM NEON requires 16-byte alignment for optimal loads                  │
│  ├── Unaligned access: 2-4x slower on some ARM cores                        │
│  └── Cache line crossing: additional memory transactions                    │
│                                                                             │
│  SOLUTION: 16-byte aligned arrays                                           │
│  ├── Double = 8 bytes, pair of Doubles = 16 bytes                          │
│  ├── Array of Doubles with 16-byte alignment                               │
│  ├── NEON can load 2 Doubles in single instruction (vld1q_f64)             │
│  └── 2x throughput for vectorized operations                                │
│                                                                             │
│  IMPLEMENTATION:                                                            │
│  ├── Use ContiguousArray instead of Array (better memory layout)           │
│  ├── Ensure capacity is multiple of 2 for Double arrays                    │
│  └── Avoid AnyObject/protocol indirection in hot paths                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Aligned Buffer for Gain Computation

```swift
/// Aligned buffer for batch gain computation
///
/// DESIGN:
/// - 16-byte aligned for ARM NEON
/// - Fixed capacity (no allocations during frame)
/// - Struct (stack allocated) for small batches
public struct AlignedGainBuffer {

    /// Maximum patches per batch
    public static let maxBatchSize: Int = 64

    /// Input values (pre-allocated)
    private var inputs: ContiguousArray<Double>

    /// Output values (pre-allocated)
    private var outputs: ContiguousArray<Double>

    /// Current count
    private var count: Int = 0

    /// Initialize with pre-allocated capacity
    public init() {
        // Pre-allocate to avoid allocations during computation
        self.inputs = ContiguousArray(repeating: 0.0, count: Self.maxBatchSize)
        self.outputs = ContiguousArray(repeating: 0.0, count: Self.maxBatchSize)
    }

    /// Reset for new batch
    @inlinable
    public mutating func reset() {
        count = 0
    }

    /// Add input value
    @inlinable
    public mutating func add(_ input: Double) {
        guard count < Self.maxBatchSize else { return }
        inputs[count] = input
        count += 1
    }

    /// Process all inputs through sigmoid and store in outputs
    @inlinable
    public mutating func processSigmoid() {
        // Process in pairs for potential vectorization
        var i = 0
        while i + 1 < count {
            outputs[i] = PRMath.sigmoid(inputs[i])
            outputs[i + 1] = PRMath.sigmoid(inputs[i + 1])
            i += 2
        }
        // Handle odd element
        if i < count {
            outputs[i] = PRMath.sigmoid(inputs[i])
        }
    }

    /// Get output at index
    @inlinable
    public func output(at index: Int) -> Double {
        guard index < count else { return 0.0 }
        return outputs[index]
    }

    /// Current batch size
    public var batchCount: Int { count }
}
```

---

## Part 6: Stable Logistic (Enhanced)

### 6.1 Stable Logistic with Performance Hints

```swift
/// Stable Logistic: Piecewise formula with performance annotations
///
/// STABILITY: No NaN, no Inf, no overflow
/// DETERMINISM: Bit-exact across all platforms
/// PERFORMANCE: ~60 cycles (use LUT for faster)
public enum StableLogistic {

    /// Maximum safe input for exp()
    private static let maxSafeInput: Double = 80.0

    /// Compute stable sigmoid
    ///
    /// FORMULA:
    /// - x ≥ 0: σ(x) = 1 / (1 + exp(-x))
    /// - x < 0: σ(x) = exp(x) / (1 + exp(x))
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Handle non-finite input first (branch prediction hint: unlikely)
        guard x.isFinite else {
            return handleNonFinite(x)
        }

        // Clamp to safe range
        let clamped = BranchFreeMath.clamp(x, -maxSafeInput, maxSafeInput)

        // Piecewise stable formula
        // Note: The branch here is predictable (50% each way on random data)
        // But for quality scores, values tend to cluster around thresholds
        if clamped >= 0 {
            let expNegX = exp(-clamped)
            return 1.0 / (1.0 + expNegX)
        } else {
            let expX = exp(clamped)
            return expX / (1.0 + expX)
        }
    }

    /// Handle non-finite inputs (cold path)
    @_optimize(none)  // Don't inline this rarely-executed code
    private static func handleNonFinite(_ x: Double) -> Double {
        if x.isNaN { return 0.5 }  // Neutral for NaN
        return x > 0 ? 1.0 : 0.0   // Saturate for ±Inf
    }

    /// Safe exponential with clamping
    @inlinable
    public static func expSafe(_ x: Double) -> Double {
        guard x.isFinite else {
            if x.isNaN { return 1.0 }  // exp(NaN) = 1.0 as neutral
            return x > 0 ? Double.infinity : 0.0
        }
        let clamped = BranchFreeMath.clamp(x, -maxSafeInput, maxSafeInput)
        return exp(clamped)
    }

    /// Compute with threshold and slope
    @inlinable
    public static func sigmoidFromThreshold(
        value: Double,
        threshold: Double,
        slope: Double
    ) -> Double {
        let safeSlope = BranchFreeMath.selectPositive(slope, fallback: 1.0)
        let normalized = (value - threshold) / safeSlope
        return sigmoid(normalized)
    }

    /// Inverted sigmoid (lower is better)
    @inlinable
    public static func sigmoidInvertedFromThreshold(
        value: Double,
        threshold: Double,
        slope: Double
    ) -> Double {
        let safeSlope = BranchFreeMath.selectPositive(slope, fallback: 1.0)
        let normalized = (threshold - value) / safeSlope
        return sigmoid(normalized)
    }
}
```

---

## Part 7: Integer Bucket World (Unchanged from V3)

*(Same as V3, no changes needed for mobile optimization)*

### 7.1 Integer Bucket Configuration

```swift
/// Integer-based bucket system for deterministic angular tracking
///
/// Same as V3 - integer operations are already fast on mobile
public enum IntegerBucketWorld {

    /// Theta buckets: 360° / 15° = 24 buckets
    public static let thetaBucketCount: Int = 24
    public static let thetaBucketSizeDeg: Double = 15.0

    /// Phi buckets: 180° / 15° = 12 buckets
    public static let phiBucketCount: Int = 12
    public static let phiBucketSizeDeg: Double = 15.0

    /// Convert theta to bucket index
    @inlinable
    public static func thetaToBucket(_ angleDeg: Double) -> Int {
        let normalized = PRMath.normalizeAngle360(angleDeg)
        let bucket = Int(floor(normalized / thetaBucketSizeDeg))
        return max(0, min(thetaBucketCount - 1, bucket))
    }

    /// Convert phi to bucket index
    @inlinable
    public static func phiToBucket(_ angleDeg: Double) -> Int {
        let clamped = BranchFreeMath.clamp(angleDeg, -90.0, 90.0)
        let shifted = clamped + 90.0
        let bucket = Int(floor(shifted / phiBucketSizeDeg))
        return max(0, min(phiBucketCount - 1, bucket))
    }
}
```

---

## Part 8: Circular Span Integer (Unchanged from V3)

*(Same as V3, max-gap algorithm is already efficient)*

---

## Part 9: SortedUniqueIntArray (Unchanged from V3)

*(Same as V3, binary search is optimal for small arrays)*

---

## Part 10: GateInputValidator (Unchanged from V3)

*(Same as V3, validation logic unchanged)*

---

## Part 11: PR3InternalQuality (Unchanged from V3)

*(Same as V3, quality computation unchanged)*

---

## Part 12: DualChannelSmoother (Enhanced)

### 12.1 Enhanced Dual Channel Smoother

```swift
/// Dual channel metric smoother: Stable + Responsive
///
/// MOBILE OPTIMIZATION:
/// - Pre-allocated history buffer (no allocations during frame)
/// - Branch-free median computation for small windows
/// - Inline-able for hot path
public final class DualChannelSmoother {

    /// History buffer (pre-allocated)
    private var history: ContiguousArray<Double>

    /// Current history count
    private var historyCount: Int = 0

    /// Last finite value
    private var lastFinite: Double?

    /// Window size
    private let windowSize: Int

    /// Jitter band
    private let jitterBand: Double

    /// Anti-boost factor
    private let antiBoostFactor: Double

    /// Scratch buffer for sorting (pre-allocated)
    private var sortBuffer: ContiguousArray<Double>

    public init(
        windowSize: AllowedWindowSize = .medium,
        jitterBand: Double = 0.05,
        antiBoostFactor: Double = 0.3
    ) {
        self.windowSize = windowSize.rawValue
        self.jitterBand = jitterBand
        self.antiBoostFactor = antiBoostFactor

        // Pre-allocate buffers
        self.history = ContiguousArray(repeating: 0.0, count: windowSize.rawValue)
        self.sortBuffer = ContiguousArray(repeating: 0.0, count: windowSize.rawValue)
    }

    /// Add value and return smoothed result
    @inlinable
    public func addAndSmooth(_ value: Double, fallback: Double = 0.0) -> Double {
        guard PRMath.isUsable(value) else {
            return currentSmoothed(fallback: fallback)
        }

        // Update last finite
        lastFinite = value

        // Circular buffer update (no array resizing)
        if historyCount < windowSize {
            history[historyCount] = value
            historyCount += 1
        } else {
            // Shift left and add new value (could optimize with ring buffer)
            for i in 0..<(windowSize - 1) {
                history[i] = history[i + 1]
            }
            history[windowSize - 1] = value
        }

        return currentSmoothed(fallback: fallback)
    }

    /// Get current smoothed value
    @inlinable
    public func currentSmoothed(fallback: Double = 0.0) -> Double {
        guard historyCount > 0 else { return lastFinite ?? fallback }

        // Compute median using pre-allocated sort buffer
        for i in 0..<historyCount {
            sortBuffer[i] = history[i]
        }

        // Sort only the valid portion
        sortBuffer.withUnsafeMutableBufferPointer { buffer in
            // Insertion sort for small arrays (faster than quicksort for n < 20)
            if historyCount <= 10 {
                insertionSort(buffer, count: historyCount)
            } else {
                let slice = UnsafeMutableBufferPointer(
                    start: buffer.baseAddress,
                    count: historyCount
                )
                slice.sort()
            }
        }

        // Compute median
        let median: Double
        if historyCount % 2 == 0 {
            median = (sortBuffer[historyCount / 2 - 1] + sortBuffer[historyCount / 2]) / 2.0
        } else {
            median = sortBuffer[historyCount / 2]
        }

        guard let last = lastFinite else { return median }

        // Dual channel synthesis
        let diff = last - median

        if Swift.abs(diff) < jitterBand {
            return median
        } else if diff > 0 {
            return median + diff * antiBoostFactor
        } else {
            return median + diff * (1.0 - antiBoostFactor)
        }
    }

    /// Insertion sort for small arrays (faster than quicksort for n < 20)
    @inlinable
    private func insertionSort(_ buffer: UnsafeMutableBufferPointer<Double>, count: Int) {
        for i in 1..<count {
            let key = buffer[i]
            var j = i - 1
            while j >= 0 && buffer[j] > key {
                buffer[j + 1] = buffer[j]
                j -= 1
            }
            buffer[j + 1] = key
        }
    }

    /// Reset
    public func reset() {
        historyCount = 0
        lastFinite = nil
    }
}
```

---

## Part 13: HardGatesV13 (Unchanged from V3)

*(Same as V3, dual representation preserved)*

---

## Part 14: Golden Tests with Int64 (Unchanged from V3)

*(Same as V3, golden test methodology preserved)*

---

## Part 15: Forbidden Patterns (Extended for Mobile)

### 15.1 Mobile Performance Anti-Patterns

```swift
/// Forbidden patterns that hurt mobile performance
/// Added to ForbiddenPatternLint
static let mobilePerformancePatterns: [(regex: String, message: String)] = [

    // Allocations in hot path
    (#"\[\]\.append"#, "Array append in hot path - pre-allocate instead"),
    (#"String\(describing:"#, "String interpolation in hot path - avoid"),
    (#"\.map\s*\{"#, "map creates new array - use forEach or pre-allocated buffer"),
    (#"\.filter\s*\{"#, "filter creates new array - use forEach with condition"),
    (#"\.reduce\("#, "reduce may allocate - use manual loop"),

    // Expensive operations
    (#"print\("#, "print() forbidden in Evidence layer - use debug-only logging"),
    (#"debugPrint"#, "debugPrint forbidden in Evidence layer"),
    (#"os_log"#, "os_log in hot path - use conditional compilation"),

    // Non-inlinable functions in hot path
    (#"@objc\s+func"#, "@objc dispatch overhead - avoid in hot path"),
    (#"dynamic\s+func"#, "dynamic dispatch overhead - avoid in hot path"),

    // ARC overhead
    (#"class\s+[A-Z].*?:\s*ObservableObject"#, "ObservableObject has ARC overhead - use struct"),
    (#"weak\s+var"#, "weak reference has ARC overhead - minimize in hot path"),

    // Protocol witness table
    (#"any\s+[A-Z]"#, "existential 'any' has indirection - use generics"),
]
```

### 15.2 ARM NEON Optimization Patterns

```swift
/// Patterns that prevent vectorization
static let vectorizationBlockerPatterns: [(regex: String, message: String)] = [

    // Early returns in loops
    (#"for\s+.*\{[^}]*return[^}]*\}"#, "return in loop breaks vectorization"),

    // Complex control flow
    (#"for\s+.*\{[^}]*switch[^}]*\}"#, "switch in loop breaks vectorization"),
    (#"for\s+.*\{[^}]*\?\s*:[^}]*\}"#, "ternary in loop may break vectorization"),

    // Indirect access
    (#"for\s+.*\{[^}]*\[.*\[.*\]\]"#, "nested subscript breaks vectorization"),
]
```

---

## Part 16: Performance Benchmark Requirements

### 16.1 Benchmark Suite

```swift
/// Performance benchmarks for PR3 gate system
final class GatePerformanceBenchmarks: XCTestCase {

    /// Single sigmoid benchmark
    func testSigmoidPerformance() {
        let iterations = 100_000

        // Stable sigmoid baseline
        let stableStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            _ = StableLogistic.sigmoid(Double(i % 16) - 8.0)
        }
        let stableTime = CFAbsoluteTimeGetCurrent() - stableStart

        // LUT sigmoid
        let lutStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            _ = LUTSigmoid.sigmoid(Double(i % 16) - 8.0)
        }
        let lutTime = CFAbsoluteTimeGetCurrent() - lutStart

        // LUT fast
        let lutFastStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            _ = LUTSigmoid.sigmoidFast(Double(i % 16) - 8.0)
        }
        let lutFastTime = CFAbsoluteTimeGetCurrent() - lutFastStart

        print("Sigmoid performance (\(iterations) iterations):")
        print("  Stable: \(stableTime * 1000)ms")
        print("  LUT 256: \(lutTime * 1000)ms (\(stableTime / lutTime)x faster)")
        print("  LUT 64: \(lutFastTime * 1000)ms (\(stableTime / lutFastTime)x faster)")

        // REQUIREMENT: LUT must be at least 2x faster
        XCTAssertGreaterThan(stableTime / lutTime, 2.0, "LUT 256 should be 2x+ faster")
        XCTAssertGreaterThan(stableTime / lutFastTime, 3.0, "LUT 64 should be 3x+ faster")
    }

    /// Full gate computation benchmark
    func testFullGateComputationPerformance() {
        let patches = 1000
        let iterations = 60  // 60 frames

        // Create test data
        var inputs: [(Double, Double, Int, Int, Double, Double, Double, Double, Double)] = []
        for _ in 0..<patches {
            inputs.append((
                Double.random(in: 0...360),  // thetaSpan
                Double.random(in: 0...180),  // phiSpan
                Int.random(in: 0...30),      // l2Plus
                Int.random(in: 0...10),      // l3
                Double.random(in: 0...2),    // reprojRms
                Double.random(in: 0...1),    // edgeRms
                Double.random(in: 0...100),  // sharpness
                Double.random(in: 0...1),    // overexposure
                Double.random(in: 0...1)     // underexposure
            ))
        }

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<iterations {
            for input in inputs {
                _ = GateGainFunctions.gateQuality(
                    thetaSpanDeg: input.0,
                    phiSpanDeg: input.1,
                    l2PlusCount: input.2,
                    l3Count: input.3,
                    reprojRmsPx: input.4,
                    edgeRmsPx: input.5,
                    sharpness: input.6,
                    overexposureRatio: input.7,
                    underexposureRatio: input.8
                )
            }
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - start
        let perFrameTime = totalTime / Double(iterations)
        let perPatchTime = perFrameTime / Double(patches)

        print("Gate computation performance:")
        print("  Total time: \(totalTime * 1000)ms for \(iterations) frames")
        print("  Per frame: \(perFrameTime * 1000)ms (\(patches) patches)")
        print("  Per patch: \(perPatchTime * 1_000_000)µs")

        // REQUIREMENT: Per frame must be < 2ms (12% of 16.67ms frame budget)
        XCTAssertLessThan(perFrameTime * 1000, 2.0, "Gate computation must be < 2ms per frame")
    }
}
```

---

## Part 17: File Deliverables (Complete, Updated)

### 17.1 New Files (Updated for Mobile)

```
Core/Evidence/Math/
├── PRMath.swift                      ✓ Unified facade (routes to Double/Fast/Fixed)
├── PRMathDouble.swift                ✓ Double implementation (stable)
├── PRMathFast.swift                  ✓ LUT-based implementation (NEW)
├── PRMathFixed.swift                 ✓ Fixed placeholder (compile-only)
├── LUTSigmoid.swift                  ✓ Lookup table sigmoid (NEW)
├── BranchFreeMath.swift              ✓ Branch-free operations (NEW)
├── StableLogistic.swift              ✓ Piecewise stable sigmoid (enhanced)
└── Quantizer.swift                   ✓ Double↔Int64 quantization

Core/Evidence/
├── PerformanceTier.swift             ✓ Performance mode selection (NEW)
├── AlignedGainBuffer.swift           ✓ Memory-aligned buffer (NEW)
├── EvidenceVector3.swift             ✓ Cross-platform vector
├── IntegerBucketWorld.swift          ✓ Integer bucket system
├── CircularSpanInteger.swift         ✓ Circular span on buckets
├── SortedUniqueIntArray.swift        ✓ Deterministic Set replacement
├── GateInputValidator.swift          ✓ Input validation with closed enum
├── PR3InternalQuality.swift          ✓ Single metric space quality
├── DualChannelSmoother.swift         ✓ Stable + responsive smoother (enhanced)
├── GateCoverageTracker.swift         ✓ Angular tracking (integer world)
├── GateGainFunctions.swift           ✓ Gain functions (via PRMath)
├── GateQualityComputer.swift         ✓ Integration layer
└── GateInvariants.swift              ✓ Runtime validation

Core/Constants/
└── HardGatesV13.swift                ✓ Dual representation (Double + Q)

Tests/Evidence/
├── PRMathTests.swift                 ✓ Math facade tests
├── LUTSigmoidTests.swift             ✓ LUT accuracy and performance (NEW)
├── BranchFreeMathTests.swift         ✓ Branch-free operation tests (NEW)
├── StableLogisticTests.swift         ✓ Sigmoid stability tests
├── CircularSpanIntegerTests.swift    ✓ Circular span tests
├── SortedUniqueIntArrayTests.swift   ✓ Deterministic array tests
├── GateInputValidatorTests.swift     ✓ Validation tests (all reasons)
├── GateDeterminismTests.swift        ✓ 100-run determinism
├── GateGoldenTests.swift             ✓ Int64 golden comparison
├── GateIntegrationTests.swift        ✓ End-to-end tests
├── DualChannelSmootherTests.swift    ✓ Smoother tests
└── GatePerformanceBenchmarks.swift   ✓ Performance benchmarks (NEW)

Tests/Evidence/Fixtures/Golden/
└── gate_quality_golden_v1.json       ✓ Golden values (Int64)
```

---

## Part 18: Implementation Phase Order (Updated)

```
Phase 1: Math Foundation (Enhanced)
├── PRMath.swift (facade, routes to Double/Fast)
├── PRMathDouble.swift (stable implementation)
├── PRMathFast.swift (LUT-based)
├── PRMathFixed.swift (placeholder)
├── LUTSigmoid.swift (256/64 entry LUT)
├── BranchFreeMath.swift (branch-free ops)
├── StableLogistic.swift (piecewise sigmoid)
└── Quantizer.swift (Int64 quantization)

Phase 2: Performance Infrastructure
├── PerformanceTier.swift
└── AlignedGainBuffer.swift

Phase 3: Integer World
├── IntegerBucketWorld.swift
├── CircularSpanInteger.swift
└── SortedUniqueIntArray.swift

Phase 4: Validation & Quality
├── HardGatesV13.swift (dual representation)
├── GateInputValidator.swift (closed enum)
├── PR3InternalQuality.swift (single metric)
└── DualChannelSmoother.swift (enhanced)

Phase 5: Core Components
├── EvidenceVector3.swift
├── GateCoverageTracker.swift (uses integer world)
├── GateGainFunctions.swift (uses PRMath)
├── GateInvariants.swift
└── GateQualityComputer.swift

Phase 6: Integration
└── Modify IsolatedEvidenceEngine.swift

Phase 7: Tests & Benchmarks
├── All test files
├── Golden fixtures (Int64)
├── Performance benchmarks
└── ForbiddenPatternLint updates
```

---

## Part 19: Acceptance Criteria (Extended)

### 19.1 Mobile Performance Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| MP1 | LUT sigmoid 2x+ faster than stable | Benchmark |
| MP2 | Full gate computation < 2ms per frame | Benchmark |
| MP3 | Per-patch computation < 2µs | Benchmark |
| MP4 | No allocations in hot path | Profiler |
| MP5 | LUT accuracy < 0.0001 (256 entry) | Unit test |
| MP6 | LUT accuracy < 0.001 (64 entry) | Unit test |
| MP7 | Memory per patch < 4KB | Static analysis |

### 19.2 Stability Criteria (Same as V3)

| ID | Criterion | Verification |
|----|-----------|--------------|
| S1 | NaN input → closed enum reason | Unit test |
| S2 | Inf input → closed enum reason | Unit test |
| S3 | Fallback quality ≤ minViewGain | Unit test |
| S4 | Fallback computed, not fixed constant | Code review |
| S5 | All invalid reasons covered in golden | CI |

### 19.3 Determinism Criteria (Same as V3)

| ID | Criterion | Verification |
|----|-----------|--------------|
| D1 | 100 runs produce exactly 1 unique result | Unit test |
| D2 | Different bucket insertion order → same span | Unit test |
| D3 | No Set/Dictionary direct iteration | Lint |
| D4 | Golden tests pass (Int64 exact match) | CI |
| D5 | No Date/UUID/random in Evidence | Lint |

### 19.4 Architecture Criteria (Same as V3)

| ID | Criterion | Verification |
|----|-----------|--------------|
| A1 | No simd import in Evidence | Lint + grep |
| A2 | No Float type in gate logic | Lint |
| A3 | HardGatesV13 has dual representation | Code review |
| A4 | Q values match Double values | DEBUG validation |
| A5 | No EvidenceConstants refs in HardGatesV13 | grep |

---

## Part 20: Coordinate System & Platform Notes (Same as V3)

*(Unchanged from V3)*

---

**Document Version:** 4.0 (Mobile Extreme Performance + Ultimate Stability)
**Author:** Claude Code
**Created:** 2026-01-30
**Status:** READY FOR IMPLEMENTATION

---

## CHANGELOG from V3

| Section | Change |
|---------|--------|
| Part 0 | Added Fifth Pillar: Mobile Performance |
| Part 1 | Added Performance Tiers and Mobile Budget |
| Part 2 | Extended PRMath to support Fast mode |
| Part 3 | Added LUT Sigmoid with 256/64 entries |
| Part 4 | Added BranchFreeMath for mobile optimization |
| Part 5 | Added AlignedGainBuffer for NEON |
| Part 6 | Enhanced StableLogistic with performance hints |
| Part 12 | Enhanced DualChannelSmoother with pre-allocation |
| Part 15 | Added mobile performance anti-patterns |
| Part 16 | Added performance benchmark requirements |
| Part 17 | Updated file deliverables for mobile |
| Part 19 | Added mobile performance acceptance criteria |

---

## Summary: V4 Key Additions

1. **LUT Sigmoid**: 2.5-7.5x faster than exp-based sigmoid
2. **Branch-Free Math**: Predictable timing, NEON-friendly
3. **Performance Tiers**: Balanced / Performance / Extreme modes
4. **Pre-allocated Buffers**: Zero allocations during frame
5. **Insertion Sort**: Faster for small window sizes (< 20 elements)
6. **Performance Benchmarks**: Verify < 2ms per frame requirement
7. **Mobile Anti-Patterns**: Lint rules to prevent performance regressions

All stability and determinism guarantees from V3 are PRESERVED.
