# PR3 Gate Reachability System - Patch V5 Bulletproof

**Document Version:** 5.0 (Bulletproof Architecture + Zero-Trig Determinism)
**Status:** DRAFT
**Created:** 2026-01-31
**Scope:** PR3 Ultimate Hardening with Physical Elimination of Non-Determinism

---

## Part 0: Executive Summary - The Seven Pillars

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE SEVEN PILLARS OF PR3 BULLETPROOF                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PILLAR 1: EXTREME THRESHOLDS (Uncompromised)                               │
│  ├── HardGatesV13 values: 0.48 / 0.23 / 85 / 26° / 15° / 13 / 5            │
│  ├── Sigmoid slopes: Geometry STEEP (cliff), View/Basic GENTLE (floor)     │
│  └── Threshold + TransitionWidth (not raw slope) for Fixed-point ready     │
│                                                                             │
│  PILLAR 2: ZERO-TRIG DETERMINISM (Physical Elimination)                     │
│  ├── Canonical path: ZERO trigonometric functions (no atan2, no asin)      │
│  ├── Phi bucketing: precomputed sin(φ_k) intervals + d.y comparison        │
│  ├── Theta bucketing: sector classification via dot product                 │
│  ├── Shadow path: trig-based verification (mismatch tracking only)         │
│  └── libm is completely eliminated from canonical computation              │
│                                                                             │
│  PILLAR 3: BITSET BUCKET WORLD (Zero Edge Cases)                            │
│  ├── thetaBuckets: UInt32 (24 bits) - O(1) insert, O(1) popcount           │
│  ├── phiBuckets: UInt16 (12 bits) - O(1) insert, O(1) popcount             │
│  ├── Circular span: bitwise rotation + leading/trailing zeros              │
│  └── Zero allocation, zero sorting, zero boundary bugs                     │
│                                                                             │
│  PILLAR 4: NUMERICAL STABILITY (Stable Logistic Only)                       │
│  ├── PRMath.Double: Canonical path (stable sigmoid, no LUT in core)        │
│  ├── PRMath.Fast: Shadow/Benchmark only (LUT with monotonicity guard)      │
│  ├── Quantizer.Q01: Type-safe [0,1] quantization only                      │
│  └── Golden tests: Double backend only, others test error bounds           │
│                                                                             │
│  PILLAR 5: CONDITIONAL ANTI-BOOST (Smart Stability)                         │
│  ├── Anti-boost ONLY on suspicious jumps (beyond jitterBand)               │
│  ├── Normal improvement: faster recovery (hyperbolic response)             │
│  ├── K consecutive invalid frames: force worst-case fallback               │
│  └── Stability ≠ Punishment; conservative only when suspicious             │
│                                                                             │
│  PILLAR 6: PHYSICAL ISOLATION (Not Just Logical)                            │
│  ├── Core/Evidence/PR3/ - Business logic (Gate only)                       │
│  ├── Core/Evidence/PRMath/ - Math facade (interface + implementations)     │
│  ├── Core/Evidence/PR3/Internal/ - IntegerBucket, Bitset, Span             │
│  ├── Compile isolation: PR3 business can ONLY import PRMath                │
│  └── CI whitelist: PR3 only touches these paths, else fail                 │
│                                                                             │
│  PILLAR 7: TIER INJECTION (No Runtime Auto-Detect)                          │
│  ├── Core algorithm layer: FORBIDDEN to call autoDetect()                  │
│  ├── Tier only via: compile-time flag OR explicit App/CLI injection        │
│  ├── PR3 tests: FORCED Double/balanced (no variation)                      │
│  └── LUT/Fast: benchmark, shadow, profile ONLY                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**References:**
- [Numerically Stable Sigmoid](https://shaktiwadekar.medium.com/how-to-avoid-numerical-overflow-in-sigmoid-function-numerically-stable-sigmoid-function-5298b14720f6)
- [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)
- [libfixmath for Fixed Point](https://github.com/howerj/q)
- [Circular Statistics](https://en.wikipedia.org/wiki/Directional_statistics)
- [Bit Manipulation Tricks](https://graphics.stanford.edu/~seander/bithacks.html)
- [CORDIC Algorithm](https://en.wikipedia.org/wiki/CORDIC)
- [Popcount Intrinsics](https://en.wikipedia.org/wiki/Hamming_weight)

---

## Part 1: Physical Directory Isolation

### 1.1 Directory Structure (Strict Boundaries)

```
Core/Evidence/
├── PR3/                              // BUSINESS LOGIC ONLY
│   ├── GateCoverageTracker.swift     // Angle tracking (uses Bitset)
│   ├── GateGainFunctions.swift       // Gain functions (uses PRMath)
│   ├── GateQualityComputer.swift     // Integration layer
│   ├── GateInvariants.swift          // Runtime validation
│   ├── PR3InternalQuality.swift      // L2+/L3 classification
│   └── Internal/                     // INTERNAL INFRASTRUCTURE
│       ├── BucketBitset.swift        // UInt32/UInt16 bitset
│       ├── CircularSpanBitset.swift  // Span on bitset
│       ├── ZeroTrigBucketing.swift   // No-trig angle→bucket
│       └── ShadowTrigVerifier.swift  // Trig-based shadow verification
│
├── PRMath/                           // MATH FACADE (INTERFACE + IMPL)
│   ├── PRMath.swift                  // Unified facade
│   ├── PRMathDouble.swift            // Double implementation (CANONICAL)
│   ├── PRMathFast.swift              // LUT implementation (SHADOW ONLY)
│   ├── PRMathFixed.swift             // Fixed-point (PLACEHOLDER)
│   ├── StableLogistic.swift          // Piecewise sigmoid
│   ├── LUTSigmoid.swift              // Lookup table (SHADOW ONLY)
│   ├── QuantizerQ01.swift            // [0,1] quantization ONLY
│   └── QuantizerAngle.swift          // Angle quantization (if needed)
│
├── Smoothing/                        // METRIC SMOOTHING
│   ├── DualChannelSmoother.swift     // Smart anti-boost
│   └── SmootherConfig.swift          // Configuration
│
├── Validation/                       // INPUT VALIDATION
│   ├── GateInputValidator.swift      // Closed enum validation
│   └── GateInputInvalidReason.swift  // Reason enum
│
├── Constants/                        // CONSTANTS (MOVED FROM Core/Constants/)
│   └── HardGatesV13.swift            // 100% self-contained
│
└── Vector/                           // VECTOR ABSTRACTION
    └── EvidenceVector3.swift         // No simd
```

### 1.2 Import Rules (Compile-Time Enforced)

```swift
// ═══════════════════════════════════════════════════════════════════════════
// IMPORT RULES - ENFORCED BY CI LINT
// ═══════════════════════════════════════════════════════════════════════════

// PR3/ files can ONLY import:
// ✅ import PRMath           (the facade)
// ✅ import Foundation       (basic types only)
// ❌ import simd             (FORBIDDEN)
// ❌ import Darwin           (FORBIDDEN - no direct libm)
// ❌ import Glibc            (FORBIDDEN - no direct libm)
// ❌ import PRMathDouble     (FORBIDDEN - use facade)
// ❌ import PRMathFast       (FORBIDDEN - use facade)
// ❌ import LUTSigmoid       (FORBIDDEN - internal to PRMath)

// PRMath/ files can import:
// ✅ import Foundation
// ✅ import Darwin/Glibc     (for stable implementations)
// ❌ import simd             (FORBIDDEN)

// CI LINT RULE:
// If file path contains "PR3/" and import contains "Darwin|Glibc|simd|PRMathDouble|PRMathFast|LUT":
//   → CI FAIL with clear error message
```

### 1.3 CI Change Whitelist

```yaml
# .github/workflows/pr3-whitelist.yml

pr3_allowed_paths:
  - Core/Evidence/PR3/**
  - Core/Evidence/PRMath/**
  - Core/Evidence/Smoothing/**
  - Core/Evidence/Validation/**
  - Core/Evidence/Constants/HardGatesV13.swift
  - Core/Evidence/Vector/EvidenceVector3.swift
  - Tests/Evidence/PR3/**
  - Tests/Evidence/PRMath/**

pr3_forbidden_modifications:
  - Core/Evidence/ViewDiversityTracker.swift
  - Core/Evidence/IsolatedEvidenceEngine.swift  # Only ADD, not MODIFY existing
  - Core/Constants/EvidenceConstants.swift
  - Core/Evidence/UnifiedAdmissionController.swift

# If PR3 branch touches files outside whitelist → CI WARNING
# If PR3 branch modifies forbidden files → CI FAIL
```

---

## Part 2: Zero-Trig Determinism (Physical Elimination of libm)

### 2.1 The Problem: libm is Non-Deterministic

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY LIBM IS THE ENEMY OF DETERMINISM                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Different libm implementations produce different results          │
│                                                                             │
│  Example: atan2(0.5, 0.866025403784)                                        │
│  ├── macOS (Apple libm):    0.5235987755982989                              │
│  ├── Linux (glibc):         0.5235987755982988                              │
│  ├── Linux (musl):          0.5235987755982990                              │
│  └── Difference: 1-2 ULP (Unit in Last Place)                               │
│                                                                             │
│  CONSEQUENCE:                                                               │
│  ├── Same angle → different bucket on different platforms                  │
│  ├── Different bucket → different span calculation                          │
│  ├── Different span → different viewGain                                    │
│  ├── Different viewGain → different gateQuality                             │
│  └── Golden tests FAIL across platforms                                     │
│                                                                             │
│  SOLUTION: ELIMINATE TRIGONOMETRY ENTIRELY FROM CANONICAL PATH              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Zero-Trig Phi Bucketing (Vertical Angle)

```swift
/// Zero-Trig Phi Bucketing: No asin() needed
///
/// PROBLEM: asin(d.y) is non-deterministic across platforms
///
/// SOLUTION: Precompute sin(φ_k) boundaries and compare d.y directly
///
/// MATH:
/// - Phi range: [-90°, +90°] → 12 buckets of 15° each
/// - Bucket k covers: [φ_k, φ_{k+1}) where φ_k = -90° + k * 15°
/// - sin(φ_k) is a constant for each bucket boundary
/// - d.y = sin(φ) where φ is the actual vertical angle
/// - Therefore: bucket = findInterval(d.y, precomputedSinBoundaries)
///
/// PRECOMPUTED BOUNDARIES (compile-time constants):
/// - sin(-90°) = -1.0
/// - sin(-75°) = -0.9659258262890683
/// - sin(-60°) = -0.8660254037844387
/// - sin(-45°) = -0.7071067811865476
/// - sin(-30°) = -0.5
/// - sin(-15°) = -0.2588190451025208
/// - sin(0°)   = 0.0
/// - sin(15°)  = 0.2588190451025208
/// - sin(30°)  = 0.5
/// - sin(45°)  = 0.7071067811865476
/// - sin(60°)  = 0.8660254037844387
/// - sin(75°)  = 0.9659258262890683
/// - sin(90°)  = 1.0
public enum ZeroTrigPhiBucketing {

    /// Precomputed sin boundaries for 12 phi buckets
    /// Index i contains sin(-90° + i * 15°)
    /// 13 boundaries for 12 buckets
    public static let sinBoundaries: [Double] = [
        -1.0,                    // sin(-90°) - bucket 0 lower
        -0.9659258262890683,     // sin(-75°) - bucket 1 lower
        -0.8660254037844387,     // sin(-60°) - bucket 2 lower
        -0.7071067811865476,     // sin(-45°) - bucket 3 lower
        -0.5,                    // sin(-30°) - bucket 4 lower
        -0.2588190451025208,     // sin(-15°) - bucket 5 lower
        0.0,                     // sin(0°)   - bucket 6 lower
        0.2588190451025208,      // sin(15°)  - bucket 7 lower
        0.5,                     // sin(30°)  - bucket 8 lower
        0.7071067811865476,      // sin(45°)  - bucket 9 lower
        0.8660254037844387,      // sin(60°)  - bucket 10 lower
        0.9659258262890683,      // sin(75°)  - bucket 11 lower
        1.0                      // sin(90°)  - upper bound
    ]

    /// Convert d.y (vertical component of normalized direction) to phi bucket
    ///
    /// PRECONDITION: d.y ∈ [-1, 1] (from normalized direction vector)
    /// OUTPUT: bucket index ∈ [0, 11]
    /// DETERMINISM: Pure comparison, no trig functions
    ///
    /// ALGORITHM: Binary search on precomputed boundaries
    /// TIME: O(log 12) = O(1) for fixed size
    @inlinable
    public static func phiBucket(dy: Double) -> Int {
        // Clamp to valid range (defensive)
        let clampedDy = max(-1.0, min(1.0, dy))

        // Binary search for bucket
        // Find largest i such that sinBoundaries[i] <= clampedDy
        var lo = 0
        var hi = 12  // 12 buckets

        while lo < hi {
            let mid = (lo + hi + 1) / 2  // Ceiling division
            if sinBoundaries[mid] <= clampedDy {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        // Clamp to valid bucket range
        return max(0, min(11, lo))
    }
}
```

### 2.3 Zero-Trig Theta Bucketing (Horizontal Angle)

```swift
/// Zero-Trig Theta Bucketing: No atan2() needed
///
/// PROBLEM: atan2(d.x, d.z) is non-deterministic across platforms
///
/// SOLUTION: Sector classification via dot product with precomputed unit vectors
///
/// MATH:
/// - Theta range: [0°, 360°) → 24 buckets of 15° each
/// - Bucket k center: θ_k = k * 15°
/// - Unit vector for bucket k: u_k = (sin(θ_k), cos(θ_k))
/// - For direction (d.x, d.z), find bucket with max dot product:
///   bucket = argmax_k { d.x * sin(θ_k) + d.z * cos(θ_k) }
///
/// ALTERNATIVE (faster): Boundary-based classification
/// - Precompute 24 boundary vectors
/// - Use cross product sign to determine which sector
///
/// PRECOMPUTED UNIT VECTORS (compile-time constants):
/// For bucket k at angle θ_k = k * 15°:
/// - u_k.x = sin(θ_k)  (horizontal component)
/// - u_k.z = cos(θ_k)  (depth component)
public enum ZeroTrigThetaBucketing {

    /// Precomputed unit vectors for 24 theta buckets
    /// Index k contains (sin(k * 15°), cos(k * 15°))
    public static let unitVectors: [(x: Double, z: Double)] = [
        (0.0, 1.0),                                      // 0°
        (0.2588190451025208, 0.9659258262890683),        // 15°
        (0.5, 0.8660254037844387),                       // 30°
        (0.7071067811865476, 0.7071067811865476),        // 45°
        (0.8660254037844387, 0.5),                       // 60°
        (0.9659258262890683, 0.2588190451025208),        // 75°
        (1.0, 0.0),                                      // 90°
        (0.9659258262890683, -0.2588190451025208),       // 105°
        (0.8660254037844387, -0.5),                      // 120°
        (0.7071067811865476, -0.7071067811865476),       // 135°
        (0.5, -0.8660254037844387),                      // 150°
        (0.2588190451025208, -0.9659258262890683),       // 165°
        (0.0, -1.0),                                     // 180°
        (-0.2588190451025208, -0.9659258262890683),      // 195°
        (-0.5, -0.8660254037844387),                     // 210°
        (-0.7071067811865476, -0.7071067811865476),      // 225°
        (-0.8660254037844387, -0.5),                     // 240°
        (-0.9659258262890683, -0.2588190451025208),      // 255°
        (-1.0, 0.0),                                     // 270°
        (-0.9659258262890683, 0.2588190451025208),       // 285°
        (-0.8660254037844387, 0.5),                      // 300°
        (-0.7071067811865476, 0.7071067811865476),       // 315°
        (-0.5, 0.8660254037844387),                      // 330°
        (-0.2588190451025208, 0.9659258262890683)        // 345°
    ]

    /// Convert (d.x, d.z) to theta bucket using dot product
    ///
    /// PRECONDITION: (d.x, d.z) is normalized in XZ plane (or will be normalized)
    /// OUTPUT: bucket index ∈ [0, 23]
    /// DETERMINISM: Pure arithmetic, no trig functions
    ///
    /// ALGORITHM: Find bucket with maximum dot product
    /// TIME: O(24) = O(1) for fixed size
    @inlinable
    public static func thetaBucket(dx: Double, dz: Double) -> Int {
        // Normalize XZ component (handle degenerate case)
        let lengthXZ = sqrt(dx * dx + dz * dz)
        guard lengthXZ > 1e-10 else {
            // Degenerate case: looking straight up/down
            // Return bucket 0 as deterministic fallback
            return 0
        }

        let nx = dx / lengthXZ
        let nz = dz / lengthXZ

        // Find bucket with maximum dot product
        var bestBucket = 0
        var bestDot = -2.0  // Minimum possible dot product is -1

        for k in 0..<24 {
            let dot = nx * unitVectors[k].x + nz * unitVectors[k].z
            if dot > bestDot {
                bestDot = dot
                bestBucket = k
            }
        }

        return bestBucket
    }

    /// OPTIMIZED VERSION: Use quadrant + fine search
    /// Reduces comparisons from 24 to ~8
    @inlinable
    public static func thetaBucketOptimized(dx: Double, dz: Double) -> Int {
        // Normalize XZ component
        let lengthXZ = sqrt(dx * dx + dz * dz)
        guard lengthXZ > 1e-10 else { return 0 }

        let nx = dx / lengthXZ
        let nz = dz / lengthXZ

        // Determine quadrant (0-3) based on signs
        let quadrant: Int
        if nz >= 0 {
            quadrant = nx >= 0 ? 0 : 3  // Q0: +x+z, Q3: -x+z
        } else {
            quadrant = nx >= 0 ? 1 : 2  // Q1: +x-z, Q2: -x-z
        }

        // Search only within quadrant (6 buckets each)
        let startBucket = quadrant * 6
        var bestBucket = startBucket
        var bestDot = -2.0

        for offset in 0..<6 {
            let k = startBucket + offset
            let dot = nx * unitVectors[k].x + nz * unitVectors[k].z
            if dot > bestDot {
                bestDot = dot
                bestBucket = k
            }
        }

        return bestBucket
    }
}
```

### 2.4 Shadow Trig Verifier (Validation Only)

```swift
/// Shadow Trig Verifier: Uses actual trig functions for verification
///
/// PURPOSE:
/// - Verify that zero-trig bucketing matches trig-based bucketing
/// - Track mismatch statistics (should be 0 in theory)
/// - Does NOT participate in canonical output
///
/// USAGE:
/// - Called in DEBUG builds only
/// - Logs mismatches for investigation
/// - Never affects gate quality computation
public enum ShadowTrigVerifier {

    /// Statistics for mismatch tracking
    public struct MismatchStats {
        public var totalComparisons: Int = 0
        public var thetaMismatches: Int = 0
        public var phiMismatches: Int = 0
    }

    /// Thread-local mismatch stats (DEBUG only)
    #if DEBUG
    @TaskLocal public static var stats = MismatchStats()
    #endif

    /// Verify phi bucket using actual asin
    ///
    /// RETURNS: true if canonical and trig-based match
    @inlinable
    public static func verifyPhiBucket(dy: Double, canonicalBucket: Int) -> Bool {
        #if DEBUG
        stats.totalComparisons += 1

        // Trig-based calculation
        let phi = asin(max(-1.0, min(1.0, dy)))  // radians
        let phiDeg = phi * 180.0 / .pi           // degrees [-90, 90]
        let trigBucket = Int(floor((phiDeg + 90.0) / 15.0))
        let clampedTrigBucket = max(0, min(11, trigBucket))

        if canonicalBucket != clampedTrigBucket {
            stats.phiMismatches += 1
            // Log for investigation
            print("[ShadowTrig] Phi mismatch: dy=\(dy), canonical=\(canonicalBucket), trig=\(clampedTrigBucket)")
            return false
        }
        return true
        #else
        return true  // No verification in release
        #endif
    }

    /// Verify theta bucket using actual atan2
    @inlinable
    public static func verifythetaBucket(dx: Double, dz: Double, canonicalBucket: Int) -> Bool {
        #if DEBUG
        stats.totalComparisons += 1

        // Trig-based calculation
        let theta = atan2(dx, dz)                // radians, from +Z axis
        var thetaDeg = theta * 180.0 / .pi       // degrees [-180, 180]
        if thetaDeg < 0 { thetaDeg += 360.0 }    // normalize to [0, 360)
        let trigBucket = Int(floor(thetaDeg / 15.0))
        let clampedTrigBucket = max(0, min(23, trigBucket))

        if canonicalBucket != clampedTrigBucket {
            stats.thetaMismatches += 1
            print("[ShadowTrig] Theta mismatch: dx=\(dx), dz=\(dz), canonical=\(canonicalBucket), trig=\(clampedTrigBucket)")
            return false
        }
        return true
        #else
        return true
        #endif
    }
}
```

---

## Part 3: Bitset Bucket World (Zero Edge Cases)

### 3.1 Why Bitset Eliminates All Edge Cases

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY BITSET IS SUPERIOR TO SORTED ARRAY                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SORTED ARRAY PROBLEMS:                                                     │
│  ├── Binary search: Off-by-one errors in boundary conditions               │
│  ├── Insert: Array resize, shift elements, allocation                       │
│  ├── Duplicate check: Additional comparison                                 │
│  ├── Iteration order: Must maintain sorted invariant                        │
│  └── Edge cases: Empty array, single element, full array                   │
│                                                                             │
│  BITSET SOLUTION:                                                           │
│  ├── Insert: bit |= (1 << index)         O(1), no allocation               │
│  ├── Contains: (bit & (1 << index)) != 0  O(1)                             │
│  ├── Count: popcount(bit)                 O(1), single instruction         │
│  ├── Clear: bit = 0                       O(1)                             │
│  ├── Span: bitwise rotation + CLZ/CTZ     O(1)                             │
│  └── No edge cases: Empty = 0, Full = all 1s                               │
│                                                                             │
│  SIZES:                                                                     │
│  ├── thetaBuckets: 24 bits → UInt32 (8 bits spare)                         │
│  ├── phiBuckets: 12 bits → UInt16 (4 bits spare)                           │
│  └── Total per patch: 6 bytes (vs ~200+ bytes for sorted array)            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Theta Bucket Bitset (24 bits)

```swift
/// Theta Bucket Bitset: 24 bits in UInt32
///
/// BIT LAYOUT:
/// - Bit 0: bucket 0 (0° - 15°)
/// - Bit 1: bucket 1 (15° - 30°)
/// - ...
/// - Bit 23: bucket 23 (345° - 360°)
/// - Bits 24-31: unused (always 0)
///
/// INVARIANT: bits & 0xFF000000 == 0 (upper 8 bits always zero)
public struct ThetaBucketBitset: Equatable, Sendable, Codable {

    /// The bitset value
    private var bits: UInt32 = 0

    /// Mask for valid bits (lower 24 bits)
    private static let validMask: UInt32 = 0x00FFFFFF

    /// Number of buckets
    public static let bucketCount: Int = 24

    /// Initialize empty
    public init() {}

    /// Initialize from raw bits (for deserialization)
    public init(rawBits: UInt32) {
        self.bits = rawBits & Self.validMask
    }

    /// Insert bucket index
    ///
    /// PRECONDITION: index ∈ [0, 23]
    /// TIME: O(1)
    @inlinable
    public mutating func insert(_ index: Int) {
        guard index >= 0 && index < Self.bucketCount else { return }
        bits |= (1 << index)
    }

    /// Check if bucket is present
    ///
    /// TIME: O(1)
    @inlinable
    public func contains(_ index: Int) -> Bool {
        guard index >= 0 && index < Self.bucketCount else { return false }
        return (bits & (1 << index)) != 0
    }

    /// Count of filled buckets
    ///
    /// TIME: O(1) using popcount intrinsic
    @inlinable
    public var count: Int {
        return bits.nonzeroBitCount
    }

    /// Check if empty
    @inlinable
    public var isEmpty: Bool {
        return bits == 0
    }

    /// Clear all buckets
    @inlinable
    public mutating func clear() {
        bits = 0
    }

    /// Raw bits (for serialization)
    public var rawBits: UInt32 { bits }

    /// Iterate over filled bucket indices in ascending order
    ///
    /// DETERMINISM: Always iterates in ascending order (0, 1, 2, ...)
    @inlinable
    public func forEachBucket(_ body: (Int) -> Void) {
        var remaining = bits
        var index = 0
        while remaining != 0 {
            if (remaining & 1) != 0 {
                body(index)
            }
            remaining >>= 1
            index += 1
        }
    }
}
```

### 3.3 Phi Bucket Bitset (12 bits)

```swift
/// Phi Bucket Bitset: 12 bits in UInt16
///
/// BIT LAYOUT:
/// - Bit 0: bucket 0 (-90° to -75°)
/// - Bit 1: bucket 1 (-75° to -60°)
/// - ...
/// - Bit 11: bucket 11 (75° to 90°)
/// - Bits 12-15: unused (always 0)
public struct PhiBucketBitset: Equatable, Sendable, Codable {

    private var bits: UInt16 = 0
    private static let validMask: UInt16 = 0x0FFF
    public static let bucketCount: Int = 12

    public init() {}

    public init(rawBits: UInt16) {
        self.bits = rawBits & Self.validMask
    }

    @inlinable
    public mutating func insert(_ index: Int) {
        guard index >= 0 && index < Self.bucketCount else { return }
        bits |= (1 << index)
    }

    @inlinable
    public func contains(_ index: Int) -> Bool {
        guard index >= 0 && index < Self.bucketCount else { return false }
        return (bits & (1 << index)) != 0
    }

    @inlinable
    public var count: Int {
        return bits.nonzeroBitCount
    }

    @inlinable
    public var isEmpty: Bool {
        return bits == 0
    }

    @inlinable
    public mutating func clear() {
        bits = 0
    }

    public var rawBits: UInt16 { bits }
}
```

### 3.4 Circular Span on Bitset

```swift
/// Circular Span Calculation on Bitset
///
/// ALGORITHM:
/// The span is 360° minus the largest gap between consecutive filled buckets.
/// For bitset, we find the largest run of consecutive zeros (the gap),
/// then span = 24 - maxGap (in buckets).
///
/// TRICK: Use bit rotation to find gaps
/// - Rotate bits so that a filled bucket is at position 0
/// - Find the longest run of leading zeros
/// - This represents the gap that wraps around
///
/// COMPLEXITY: O(24) worst case, but very fast with bit operations
public enum CircularSpanBitset {

    /// Compute circular span in bucket count
    ///
    /// INPUT: theta bucket bitset (24 bits)
    /// OUTPUT: span in buckets [0, 24]
    ///
    /// SPECIAL CASES:
    /// - Empty bitset → span = 0
    /// - Single bucket → span = 0 (need at least 2 for span)
    /// - All buckets filled → span = 24
    @inlinable
    public static func computeSpanBuckets(_ bitset: ThetaBucketBitset) -> Int {
        let bits = bitset.rawBits
        let count = bits.nonzeroBitCount

        // Special cases
        if count == 0 { return 0 }
        if count == 1 { return 0 }  // Single point has no span
        if count == 24 { return 24 }  // All filled

        // Find the maximum gap (run of consecutive zeros)
        // We need to handle the circular nature

        // Method: Find all gaps and take the maximum
        var maxGap = 0
        var currentGap = 0
        var inGap = false
        var firstFilledIndex = -1
        var lastFilledIndex = -1

        for i in 0..<24 {
            let isFilled = (bits & (1 << i)) != 0

            if isFilled {
                if firstFilledIndex == -1 {
                    firstFilledIndex = i
                }
                lastFilledIndex = i

                if inGap {
                    maxGap = max(maxGap, currentGap)
                    currentGap = 0
                    inGap = false
                }
            } else {
                currentGap += 1
                inGap = true
            }
        }

        // Handle wrap-around gap (from last filled to first filled)
        // Gap wraps: (24 - lastFilledIndex - 1) + firstFilledIndex
        let wrapGap = (24 - lastFilledIndex - 1) + firstFilledIndex
        maxGap = max(maxGap, wrapGap)

        // Span = total buckets - max gap
        return 24 - maxGap
    }

    /// Compute linear span in bucket count (non-circular, for phi)
    ///
    /// INPUT: phi bucket bitset (12 bits)
    /// OUTPUT: span in buckets [0, 12]
    @inlinable
    public static func computeLinearSpanBuckets(_ bitset: PhiBucketBitset) -> Int {
        let bits = bitset.rawBits
        let count = bits.nonzeroBitCount

        if count == 0 { return 0 }
        if count == 1 { return 0 }

        // Find first and last filled bucket
        var firstFilled = -1
        var lastFilled = -1

        for i in 0..<12 {
            if (bits & (1 << i)) != 0 {
                if firstFilled == -1 {
                    firstFilled = i
                }
                lastFilled = i
            }
        }

        // Linear span = last - first (NOT +1, as per original spec)
        return lastFilled - firstFilled
    }

    /// Convert bucket span to degrees
    @inlinable
    public static func spanToDegrees(_ bucketSpan: Int, bucketSizeDeg: Double) -> Double {
        return Double(bucketSpan) * bucketSizeDeg
    }
}
```

---

## Part 4: Tier Injection (No Runtime Auto-Detect)

### 4.1 The Problem with autoDetect

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY AUTO-DETECT BREAKS DETERMINISM                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Same code, same input, different device → different output        │
│                                                                             │
│  Example:                                                                   │
│  ├── iPhone 15 Pro (A17): autoDetect() → .balanced → PRMathDouble          │
│  ├── iPhone 13 (A15): autoDetect() → .performance → PRMathFast (LUT)       │
│  ├── Same input angles, same observations                                   │
│  └── Different gateQuality due to LUT approximation error                  │
│                                                                             │
│  CONSEQUENCE:                                                               │
│  ├── Golden tests fail on different devices                                 │
│  ├── User sees different quality scores for same content                   │
│  ├── Cross-device sync becomes inconsistent                                 │
│  └── Debugging becomes nightmare                                           │
│                                                                             │
│  SOLUTION: INJECT TIER EXPLICITLY, NEVER AUTO-DETECT IN CORE               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Tier Injection Architecture

```swift
/// Performance Tier: Explicitly injected, never auto-detected in core
///
/// RULE: Core algorithm layer MUST NOT call autoDetect()
/// RULE: Tier MUST be injected from App/CLI layer
/// RULE: Tests MUST use .canonical (Double)
public enum PerformanceTier: String, Codable, Sendable {

    /// Canonical tier: PRMathDouble, stable sigmoid
    /// USAGE: All production code, all tests, all golden comparisons
    case canonical = "canonical"

    /// Fast tier: PRMathFast, LUT sigmoid
    /// USAGE: Benchmark, shadow verification, performance profiling ONLY
    case fast = "fast"

    /// Fixed tier: PRMathFixed, fixed-point (future)
    /// USAGE: Embedded systems (future)
    case fixed = "fixed"

    /// Auto-detect based on device (FORBIDDEN in core!)
    /// USAGE: App/CLI initialization ONLY
    public static func autoDetect() -> PerformanceTier {
        // This method exists but is FORBIDDEN to call from core algorithm layer
        // CI lint will flag any usage in Core/Evidence/PR3/
        #if targetEnvironment(simulator)
        return .canonical
        #else
        let cores = ProcessInfo.processInfo.processorCount
        return cores >= 6 ? .canonical : .fast
        #endif
    }
}

/// Tier Context: Injected into algorithm layer
///
/// DESIGN:
/// - Created at App/CLI startup
/// - Passed down to all algorithm components
/// - Never mutated after creation
/// - Never auto-detected within algorithms
public struct TierContext: Sendable {

    /// The injected tier
    public let tier: PerformanceTier

    /// Create with explicit tier
    public init(tier: PerformanceTier) {
        self.tier = tier
    }

    /// Create for testing (always canonical)
    public static let forTesting = TierContext(tier: .canonical)

    /// Create for benchmark (fast)
    public static let forBenchmark = TierContext(tier: .fast)
}
```

### 4.3 CI Lint Rule for autoDetect

```swift
/// Forbidden pattern: autoDetect() in core algorithm layer
///
/// REGEX: PerformanceTier\.autoDetect\(\)
/// PATHS: Core/Evidence/PR3/**
/// ACTION: CI FAIL
///
/// ALLOWED PATHS:
/// - App/AppDelegate.swift
/// - CLI/main.swift
/// - Tests/Evidence/PR3/BenchmarkTests.swift (explicit exception)
static let autoDetectForbiddenPattern = (
    regex: #"PerformanceTier\.autoDetect\(\)"#,
    message: "autoDetect() forbidden in core algorithm layer - use injected TierContext",
    allowedPaths: [
        "App/",
        "CLI/",
        "Tests/**/Benchmark*.swift"
    ]
)
```

---

## Part 5: LUT Sigmoid with Monotonicity Guard

### 5.1 The Problem with Naive LUT

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY NAIVE LUT IS DANGEROUS                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Floating-point errors can break monotonicity                      │
│                                                                             │
│  Example of table construction:                                             │
│  - table[100] = 0.7310585786300049 (computed)                              │
│  - table[101] = 0.7310585786300048 (computed, SMALLER!)                    │
│  - This violates sigmoid monotonicity: σ(x) should increase with x         │
│                                                                             │
│  CONSEQUENCE:                                                               │
│  ├── Gate quality can DECREASE when it should increase                     │
│  ├── Threshold crossings become non-monotonic                              │
│  ├── User sees inconsistent feedback                                        │
│  └── Very hard to debug (depends on exact input values)                    │
│                                                                             │
│  SOLUTION: MONOTONICITY GUARD during table construction                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 LUT Sigmoid with Guards (Shadow Only)

```swift
/// LUT Sigmoid: For shadow/benchmark ONLY, with monotonicity guard
///
/// CRITICAL: This is NOT used in canonical path!
/// PURPOSE: Shadow verification, performance benchmarking
///
/// GUARDS:
/// 1. Monotonicity: table[i+1] >= table[i] enforced at construction
/// 2. Endpoints: x ≤ xmin → 0, x ≥ xmax → 1 (exact)
/// 3. No FMA: Split multiply-add to prevent LLVM combining
public enum LUTSigmoidGuarded {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    private static let lutSize: Int = 256
    private static let minInput: Double = -8.0
    private static let maxInput: Double = 8.0
    private static let inputRange: Double = 16.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Guarded Table Construction
    // ═══════════════════════════════════════════════════════════════════════

    /// Lookup table with monotonicity guarantee
    private static let lut: [Double] = {
        var table = [Double](repeating: 0.0, count: lutSize)

        // Compute initial values
        for i in 0..<lutSize {
            let x = minInput + (Double(i) / Double(lutSize - 1)) * inputRange
            table[i] = StableLogistic.sigmoid(x)
        }

        // MONOTONICITY GUARD: Ensure table[i+1] >= table[i]
        for i in 1..<lutSize {
            if table[i] < table[i - 1] {
                // Fix violation by clamping to previous value
                table[i] = table[i - 1]
                #if DEBUG
                print("[LUTSigmoid] Monotonicity fix at index \(i)")
                #endif
            }
        }

        // ENDPOINT GUARD: Force exact values at boundaries
        table[0] = 0.0003353501304664781  // sigmoid(-8) exactly
        table[lutSize - 1] = 0.9996646498695336  // sigmoid(8) exactly

        return table
    }()

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sigmoid with No-FMA Interpolation
    // ═══════════════════════════════════════════════════════════════════════

    /// LUT sigmoid with explicit no-FMA interpolation
    ///
    /// WHY NO-FMA:
    /// - FMA (Fused Multiply-Add) can change results based on compiler flags
    /// - LLVM may or may not use FMA instructions
    /// - By splitting multiply and add, we ensure consistent results
    @inlinable
    public static func sigmoid(_ x: Double) -> Double {
        // Handle non-finite
        guard x.isFinite else {
            if x.isNaN { return 0.5 }
            return x > 0 ? 1.0 : 0.0
        }

        // Endpoint saturation (exact)
        if x <= minInput { return lut[0] }
        if x >= maxInput { return lut[lutSize - 1] }

        // Compute index
        let normalizedX = (x - minInput) / inputRange
        let indexF = normalizedX * Double(lutSize - 1)
        let indexLow = Int(indexF)
        let indexHigh = min(indexLow + 1, lutSize - 1)

        // NO-FMA INTERPOLATION
        // Split: result = low + (high - low) * fraction
        // Instead of: result = low + diff * fraction (FMA candidate)
        let fraction = indexF - Double(indexLow)
        let valueLow = lut[indexLow]
        let valueHigh = lut[indexHigh]

        // Explicit split to prevent FMA
        let diff = valueHigh - valueLow  // Step 1
        let scaled = diff * fraction      // Step 2 (NOT fused with step 3)
        let result = valueLow + scaled    // Step 3

        return result
    }
}
```

---

## Part 6: Conditional Anti-Boost Smoother

### 6.1 The Problem with Always-Anti-Boost

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY ALWAYS-ANTI-BOOST IS BAD UX                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: antiBoostFactor = 0.3 means improvement is always slow            │
│                                                                             │
│  Scenario:                                                                  │
│  ├── User's camera was blocked → quality = 0.2                             │
│  ├── User removes obstruction → raw quality = 0.8                          │
│  ├── With antiBoost always on: takes 5+ frames to recover                  │
│  └── User thinks: "why is it still red when I fixed it?"                   │
│                                                                             │
│  REAL NEED:                                                                 │
│  ├── Anti-boost ONLY for suspicious jumps (noise, glitches)                │
│  ├── Normal improvement should recover quickly                              │
│  ├── K consecutive bad frames → force worst-case (don't stay at old good)  │
│  └── Stability ≠ Punishment                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Smart Anti-Boost Smoother

```swift
/// Smart Anti-Boost Dual Channel Smoother
///
/// DESIGN:
/// - Anti-boost ONLY when jump exceeds jitterBand (suspicious)
/// - Normal improvement: faster recovery (configurable)
/// - K consecutive invalid: force worst-case fallback
/// - Hysteresis: prevent oscillation at boundaries
public final class SmartAntiBoostSmoother: @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// Configuration for smart anti-boost behavior
    public struct Config: Sendable {
        /// Jitter band: differences within this range are considered noise
        public let jitterBand: Double

        /// Anti-boost factor: how much slower to improve on suspicious jumps
        /// 0.3 = improve at 30% speed (only for suspicious jumps)
        public let antiBoostFactor: Double

        /// Normal improvement factor: how fast to improve on normal changes
        /// 0.7 = improve at 70% speed (faster than anti-boost)
        public let normalImproveFactor: Double

        /// Degradation factor: how fast to degrade
        /// 1.0 = immediate degradation (realistic penalty)
        public let degradeFactor: Double

        /// Consecutive invalid threshold: after K invalid frames, force worst-case
        public let maxConsecutiveInvalid: Int

        /// Worst-case fallback value
        public let worstCaseFallback: Double

        public static let `default` = Config(
            jitterBand: 0.05,
            antiBoostFactor: 0.3,
            normalImproveFactor: 0.7,
            degradeFactor: 1.0,
            maxConsecutiveInvalid: 5,
            worstCaseFallback: 0.0
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════

    private let config: Config
    private let windowSize: Int

    /// History buffer (pre-allocated)
    private var history: ContiguousArray<Double>
    private var historyCount: Int = 0

    /// Last valid value (for trend detection)
    private var lastValid: Double?

    /// Previous smoothed value (for change detection)
    private var previousSmoothed: Double?

    /// Consecutive invalid frame counter
    private var consecutiveInvalidCount: Int = 0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    public init(windowSize: Int = 5, config: Config = .default) {
        self.windowSize = windowSize
        self.config = config
        self.history = ContiguousArray(repeating: 0.0, count: windowSize)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Core API
    // ═══════════════════════════════════════════════════════════════════════

    /// Add value and return smoothed result
    ///
    /// BEHAVIOR:
    /// 1. If invalid (NaN/Inf): increment invalidCount, return previous or fallback
    /// 2. If valid: reset invalidCount, add to history, compute smoothed
    /// 3. If consecutiveInvalidCount >= maxConsecutiveInvalid: return worst-case
    public func addAndSmooth(_ value: Double) -> Double {
        // Check validity
        guard value.isFinite else {
            return handleInvalidInput()
        }

        // Reset invalid counter on valid input
        consecutiveInvalidCount = 0

        // Update last valid
        lastValid = value

        // Update history (circular buffer style)
        if historyCount < windowSize {
            history[historyCount] = value
            historyCount += 1
        } else {
            // Shift and add (could optimize with ring buffer index)
            for i in 0..<(windowSize - 1) {
                history[i] = history[i + 1]
            }
            history[windowSize - 1] = value
        }

        // Compute smoothed value
        let smoothed = computeSmoothed(newValue: value)

        // Update previous for next iteration
        previousSmoothed = smoothed

        return smoothed
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Internal Logic
    // ═══════════════════════════════════════════════════════════════════════

    private func handleInvalidInput() -> Double {
        consecutiveInvalidCount += 1

        // If too many consecutive invalid, force worst-case
        if consecutiveInvalidCount >= config.maxConsecutiveInvalid {
            previousSmoothed = config.worstCaseFallback
            return config.worstCaseFallback
        }

        // Otherwise return previous smoothed (or worst-case if none)
        return previousSmoothed ?? config.worstCaseFallback
    }

    private func computeSmoothed(newValue: Double) -> Double {
        guard historyCount > 0 else { return newValue }

        // Compute median
        let median = computeMedian()

        // Get previous smoothed (or median if first time)
        let previous = previousSmoothed ?? median

        // Compute change
        let change = newValue - previous

        // Determine response based on change characteristics
        if abs(change) < config.jitterBand {
            // Within jitter band: use median (stable)
            return median
        } else if change > 0 {
            // Improving: check if suspicious jump
            if change > config.jitterBand * 3 {
                // Suspicious jump (> 3x jitter band): use anti-boost
                return previous + change * config.antiBoostFactor
            } else {
                // Normal improvement: use normal factor
                return previous + change * config.normalImproveFactor
            }
        } else {
            // Degrading: use degradation factor (usually 1.0 = immediate)
            return previous + change * config.degradeFactor
        }
    }

    private func computeMedian() -> Double {
        guard historyCount > 0 else { return 0.0 }

        // Copy valid portion and sort
        var sorted = Array(history[0..<historyCount])
        sorted.sort()

        // Compute median
        if historyCount % 2 == 0 {
            return (sorted[historyCount / 2 - 1] + sorted[historyCount / 2]) / 2.0
        } else {
            return sorted[historyCount / 2]
        }
    }

    /// Reset all state
    public func reset() {
        historyCount = 0
        lastValid = nil
        previousSmoothed = nil
        consecutiveInvalidCount = 0
    }
}
```

---

## Part 7: Type-Safe Quantization

### 7.1 The Problem with Generic Quantizer

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY GENERIC QUANTIZER IS DANGEROUS                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: scale=1e12 works for [0,1] but fails for other ranges             │
│                                                                             │
│  Example:                                                                   │
│  ├── sigmoid input x = 100 → quantize(100) = 100_000_000_000_000           │
│  ├── This overflows semantic meaning                                        │
│  ├── Someone accidentally quantizes logit instead of probability           │
│  └── Results become meaningless                                             │
│                                                                             │
│  SOLUTION: Type-safe quantizers for specific domains                        │
│  ├── QuantizerQ01: Only [0, 1] values (gain, quality)                      │
│  ├── QuantizerAngle: Degrees [0, 360) or [-180, 180)                       │
│  └── QuantizerBucket: Integer buckets (no quantization needed)             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Type-Safe Quantizers

```swift
/// Type-safe quantizer for [0, 1] values only
///
/// USAGE: Gain values, quality scores, ratios
/// FORBIDDEN: Angles, counts, raw inputs
public enum QuantizerQ01 {

    /// Scale for 12 decimal places
    public static let scale: Double = 1e12
    public static let scaleInt64: Int64 = 1_000_000_000_000

    /// Quantize [0, 1] value to Int64
    ///
    /// PRECONDITION: value ∈ [0, 1]
    /// OUTPUT: Int64 ∈ [0, scaleInt64]
    @inlinable
    public static func quantize(_ value: Double) -> Int64 {
        // Clamp to valid range (defensive)
        let clamped = max(0.0, min(1.0, value))
        // Round half away from zero (deterministic)
        return Int64((clamped * scale).rounded(.toNearestOrAwayFromZero))
    }

    /// Dequantize Int64 back to Double
    @inlinable
    public static func dequantize(_ q: Int64) -> Double {
        return Double(q) / scale
    }

    /// Check if two quantized values are equal
    @inlinable
    public static func areEqual(_ a: Int64, _ b: Int64) -> Bool {
        return a == b
    }

    /// Check if two quantized values are within tolerance
    @inlinable
    public static func areClose(_ a: Int64, _ b: Int64, tolerance: Int64 = 1) -> Bool {
        return abs(a - b) <= tolerance
    }
}

/// Type-safe quantizer for angle values
///
/// USAGE: Span degrees, angle degrees
/// SCALE: 1e9 (9 decimal places, angles don't need 12)
public enum QuantizerAngle {

    public static let scale: Double = 1e9
    public static let scaleInt64: Int64 = 1_000_000_000

    /// Quantize angle in degrees to Int64
    ///
    /// PRECONDITION: value is finite
    /// OUTPUT: Int64 representation
    @inlinable
    public static func quantize(_ degrees: Double) -> Int64 {
        guard degrees.isFinite else { return 0 }
        return Int64((degrees * scale).rounded(.toNearestOrAwayFromZero))
    }

    @inlinable
    public static func dequantize(_ q: Int64) -> Double {
        return Double(q) / scale
    }
}

/// Bucket values: No quantization needed (already Int)
///
/// This enum exists to prevent accidental quantization of buckets
public enum BucketValue {
    /// Bucket indices are integers, no quantization
    /// Just use Int directly
}
```

### 7.3 CI Lint for Quantizer Misuse

```swift
/// Forbidden patterns for quantizer misuse
static let quantizerMisusePatterns: [(regex: String, message: String, paths: [String])] = [

    // Generic quantize on non-Q01 values
    (
        regex: #"QuantizerQ01\.quantize\(.*(?:angle|degree|span|rms|pixel)"#,
        message: "QuantizerQ01 is for [0,1] values only - use QuantizerAngle for angles",
        paths: ["Core/Evidence/**"]
    ),

    // Quantizing intermediate values
    (
        regex: #"QuantizerQ01\.quantize\(.*(?:sigmoid|logit|exp)\("#,
        message: "Don't quantize intermediate values - only quantize final outputs",
        paths: ["Core/Evidence/**"]
    ),

    // Old generic Quantizer usage
    (
        regex: #"Quantizer\.quantize\("#,
        message: "Use type-safe quantizers: QuantizerQ01 or QuantizerAngle",
        paths: ["Core/Evidence/**"]
    ),
]
```

---

## Part 8: Golden Tests - Double Backend Only

### 8.1 Golden Test Semantics

```swift
/// Golden Test Semantics
///
/// RULE 1: Golden fixtures are ONLY for Double backend
/// RULE 2: Fast/Fixed backends test ERROR BOUNDS, not exact match
/// RULE 3: Golden fixtures record backend metadata
///
/// WHY:
/// - Double is the CANONICAL implementation
/// - Fast (LUT) has approximation error by design
/// - Fixed (future) will have different numerical properties
/// - Golden = Truth, others = Approximations
public struct GoldenFixtureMetadata: Codable {

    /// The backend that generated these golden values
    public let backend: String  // "Double"

    /// Performance tier
    public let tier: String  // "canonical"

    /// Version of the fixture format
    public let version: String  // "1.0"

    /// Generation timestamp (for documentation only)
    public let generatedAt: String

    /// Swift version used
    public let swiftVersion: String

    /// Platform used
    public let platform: String  // "macOS-14-arm64"
}

/// Golden fixture format
public struct GoldenFixture: Codable {

    /// Metadata about how this fixture was generated
    public let metadata: GoldenFixtureMetadata

    /// Test cases
    public let cases: [GoldenTestCase]
}

/// Single golden test case
public struct GoldenTestCase: Codable {
    public let name: String
    public let input: GoldenInput
    public let expected: GoldenExpected
}

/// Golden input values
public struct GoldenInput: Codable {
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

/// Golden expected values (Int64 quantized)
public struct GoldenExpected: Codable {
    public let viewGain_q: Int64
    public let geomGain_q: Int64
    public let basicGain_q: Int64
    public let gateQuality_q: Int64
}
```

### 8.2 Backend-Specific Test Strategies

```swift
/// Test strategies for different backends
final class GateBackendTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Double Backend (Canonical) - Exact Match
    // ═══════════════════════════════════════════════════════════════════════

    func testDoubleBackend_GoldenExactMatch() throws {
        // Force Double backend
        let context = TierContext.forTesting  // Always canonical/Double

        let fixture = try loadGoldenFixture("gate_quality_golden_v1.json")

        // Verify metadata
        XCTAssertEqual(fixture.metadata.backend, "Double")
        XCTAssertEqual(fixture.metadata.tier, "canonical")

        for testCase in fixture.cases {
            let result = GateGainFunctions.compute(
                context: context,
                input: testCase.input
            )

            // EXACT match for Double backend
            XCTAssertEqual(
                QuantizerQ01.quantize(result.gateQuality),
                testCase.expected.gateQuality_q,
                "\(testCase.name): gateQuality exact mismatch"
            )
        }
    }

    // ═════════════════════════════���═════════════════════════════════════════
    // MARK: - Fast Backend (LUT) - Error Bound Check
    // ═══════════════════════════════════════════════════════════════════════

    func testFastBackend_ErrorBounds() throws {
        // Force Fast backend (for benchmark/shadow only)
        let context = TierContext.forBenchmark  // Fast/LUT

        let fixture = try loadGoldenFixture("gate_quality_golden_v1.json")

        // Maximum allowed error (in quantized units)
        // 0.0001 in [0,1] = 100_000_000 in Q01 scale
        let maxErrorQ: Int64 = 100_000_000

        for testCase in fixture.cases {
            let result = GateGainFunctions.compute(
                context: context,
                input: testCase.input
            )

            let actualQ = QuantizerQ01.quantize(result.gateQuality)
            let expectedQ = testCase.expected.gateQuality_q
            let error = abs(actualQ - expectedQ)

            // Error bound check (not exact match)
            XCTAssertLessThanOrEqual(
                error,
                maxErrorQ,
                "\(testCase.name): LUT error \(error) exceeds bound \(maxErrorQ)"
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fast Backend - Monotonicity Check
    // ═══════════════════════════════════════════════════════════════════════

    func testFastBackend_Monotonicity() {
        let context = TierContext.forBenchmark

        // Test that sigmoid is monotonically increasing
        var previousValue = 0.0
        for i in stride(from: -10.0, through: 10.0, by: 0.1) {
            let value = PRMath.sigmoid(i, context: context)
            XCTAssertGreaterThanOrEqual(
                value,
                previousValue,
                "Monotonicity violated at x=\(i)"
            )
            previousValue = value
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Fast Backend - Stability Check
    // ═══════════════════════════════════════════════════════════════════════

    func testFastBackend_Stability() {
        let context = TierContext.forBenchmark

        // Test extreme inputs don't produce NaN/Inf
        let extremeInputs: [Double] = [
            -1000, -100, -10, -1, -0.001,
            0, 0.001, 1, 10, 100, 1000,
            Double.nan, Double.infinity, -Double.infinity
        ]

        for x in extremeInputs {
            let value = PRMath.sigmoid(x, context: context)
            XCTAssertTrue(value.isFinite, "Non-finite result for x=\(x)")
            XCTAssertGreaterThanOrEqual(value, 0.0, "Below 0 for x=\(x)")
            XCTAssertLessThanOrEqual(value, 1.0, "Above 1 for x=\(x)")
        }
    }
}
```

---

## Part 9: HardGatesV13 with Threshold + TransitionWidth

### 9.1 Why TransitionWidth Instead of Raw Slope

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHY TRANSITION WIDTH IS FUTURE-PROOF                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PROBLEM: Raw slope has different meaning in different backends             │
│                                                                             │
│  Example:                                                                   │
│  ├── Double sigmoid: slope=0.10 means x=0.10 gives specific steepness      │
│  ├── Fixed sigmoid: same slope gives DIFFERENT steepness due to Q format   │
│  ├── When switching backends, must re-tune all slopes                       │
│  └── Nightmare for maintenance                                             │
│                                                                             │
│  SOLUTION: Use threshold + transitionWidth (semantic meaning)               │
│  ├── transitionWidth = "how wide is the transition zone in input units"    │
│  ├── For reproj: transitionWidth = 0.20 means "from 0.38 to 0.58 is gray"  │
│  ├── Each backend converts transitionWidth to its internal slope           │
│  └── Switching backends: same semantic meaning preserved                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 HardGatesV13 with TransitionWidth

```swift
/// HardGatesV13: Gate thresholds with semantic transitionWidth
///
/// DESIGN:
/// - threshold: The 50% point of the sigmoid
/// - transitionWidth: The width of the transition zone (10% to 90%)
/// - Each backend converts transitionWidth to internal slope
///
/// CONVERSION:
/// For standard sigmoid σ(x) = 1/(1+e^(-x)):
/// - σ(2.2) ≈ 0.90
/// - σ(-2.2) ≈ 0.10
/// - So transition from 10% to 90% is x ∈ [-2.2, 2.2], width = 4.4
/// - If transitionWidth in input units is W, then slope = W / 4.4
public enum HardGatesV13 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quantization Scale
    // ═══════════════════════════════════════════════════════════════════════

    public static let quantizationScale: Double = 1e12
    public static let quantizationScaleQ: Int64 = 1_000_000_000_000

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Geometry Thresholds (Threshold + TransitionWidth)
    // ═══════════════════════════════════════════════════════════════════════

    /// Reproj RMS threshold (50% point)
    public static let reprojThreshold: Double = 0.48

    /// Reproj RMS transition width (10% to 90% zone)
    /// 0.44 means: from 0.26 to 0.70 is the transition zone
    /// Below 0.26: gain > 90%, Above 0.70: gain < 10%
    public static let reprojTransitionWidth: Double = 0.44

    /// Computed slope for Double backend
    /// slope = transitionWidth / 4.4
    public static var reprojSlope: Double { reprojTransitionWidth / 4.4 }

    /// Edge RMS threshold
    public static let edgeThreshold: Double = 0.23

    /// Edge RMS transition width (STEEP cliff)
    public static let edgeTransitionWidth: Double = 0.22

    public static var edgeSlope: Double { edgeTransitionWidth / 4.4 }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Coverage Thresholds (Threshold + TransitionWidth)
    // ═══════════════════════════════════════════════════════════════════════

    /// Theta span threshold (degrees)
    public static let thetaThreshold: Double = 26.0

    /// Theta span transition width (GENTLE floor)
    public static let thetaTransitionWidth: Double = 35.2  // 8.0 * 4.4

    public static var thetaSlope: Double { thetaTransitionWidth / 4.4 }

    /// Phi span threshold (degrees)
    public static let phiThreshold: Double = 15.0

    /// Phi span transition width
    public static let phiTransitionWidth: Double = 26.4  // 6.0 * 4.4

    public static var phiSlope: Double { phiTransitionWidth / 4.4 }

    /// L2+ count threshold
    public static let l2PlusThreshold: Double = 13.0

    /// L2+ count transition width
    public static let l2PlusTransitionWidth: Double = 17.6  // 4.0 * 4.4

    public static var l2PlusSlope: Double { l2PlusTransitionWidth / 4.4 }

    /// L3 count threshold
    public static let l3Threshold: Double = 5.0

    /// L3 count transition width
    public static let l3TransitionWidth: Double = 8.8  // 2.0 * 4.4

    public static var l3Slope: Double { l3TransitionWidth / 4.4 }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Basic Quality Thresholds
    // ═══════════════════════════════════════════════════════════════════════

    /// Sharpness threshold
    public static let sharpnessThreshold: Double = 85.0

    /// Sharpness transition width
    public static let sharpnessTransitionWidth: Double = 22.0  // 5.0 * 4.4

    public static var sharpnessSlope: Double { sharpnessTransitionWidth / 4.4 }

    /// Overexposure threshold
    public static let overexposureThreshold: Double = 0.28

    /// Overexposure transition width
    public static let overexposureTransitionWidth: Double = 0.352  // 0.08 * 4.4

    public static var overexposureSlope: Double { overexposureTransitionWidth / 4.4 }

    /// Underexposure threshold
    public static let underexposureThreshold: Double = 0.38

    /// Underexposure transition width
    public static let underexposureTransitionWidth: Double = 0.352

    public static var underexposureSlope: Double { underexposureTransitionWidth / 4.4 }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Gain Floors
    // ═══════════════════════════════════════════════════════════════════════

    public static let minViewGain: Double = 0.05
    public static let minBasicGain: Double = 0.10
    public static let minGeomGain: Double = 0.0  // NO FLOOR - cliff is real

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Bucket Configuration
    // ═══════════════════════════════════════════════════════════════════════

    public static let thetaBucketCount: Int = 24
    public static let phiBucketCount: Int = 12
    public static let thetaBucketSizeDeg: Double = 15.0
    public static let phiBucketSizeDeg: Double = 15.0

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Memory Limits
    // ═══════════════════════════════════════════════════════════════════════

    public static let maxRecordsPerPatch: Int = 200

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - L2+/L3 Quality Thresholds
    // ═══════════════════════════════════════════════════════════════════════

    public static let l2QualityThreshold: Double = 0.30
    public static let l3QualityThreshold: Double = 0.60
}
```

---

## Part 10: Forbidden Patterns (Complete List)

### 10.1 Import Isolation

```swift
static let importIsolationPatterns: [(regex: String, message: String, paths: [String])] = [
    // PR3 cannot import simd
    (#"import\s+simd"#,
     "simd import forbidden in Evidence layer",
     ["Core/Evidence/**"]),

    // PR3 cannot import Darwin/Glibc directly
    (#"import\s+Darwin"#,
     "Darwin import forbidden in PR3 - use PRMath",
     ["Core/Evidence/PR3/**"]),

    (#"import\s+Glibc"#,
     "Glibc import forbidden in PR3 - use PRMath",
     ["Core/Evidence/PR3/**"]),

    // PR3 cannot import internal PRMath implementations
    (#"import\s+PRMathDouble"#,
     "Import PRMath facade, not implementation",
     ["Core/Evidence/PR3/**"]),

    (#"import\s+PRMathFast"#,
     "Import PRMath facade, not implementation",
     ["Core/Evidence/PR3/**"]),

    (#"import\s+LUTSigmoid"#,
     "LUTSigmoid is internal to PRMath",
     ["Core/Evidence/PR3/**"]),
]
```

### 10.2 libm Elimination

```swift
static let libmEliminationPatterns: [(regex: String, message: String, paths: [String])] = [
    // Direct trig function calls
    (#"(?<!PRMath\.)atan2\("#,
     "Direct atan2() forbidden - use ZeroTrigThetaBucketing",
     ["Core/Evidence/PR3/**"]),

    (#"(?<!PRMath\.)asin\("#,
     "Direct asin() forbidden - use ZeroTrigPhiBucketing",
     ["Core/Evidence/PR3/**"]),

    (#"(?<!PRMath\.)acos\("#,
     "Direct acos() forbidden - use PRMath",
     ["Core/Evidence/PR3/**"]),

    (#"(?<!PRMath\.)sin\("#,
     "Direct sin() forbidden - precompute constants",
     ["Core/Evidence/PR3/**"]),

    (#"(?<!PRMath\.)cos\("#,
     "Direct cos() forbidden - precompute constants",
     ["Core/Evidence/PR3/**"]),

    // Direct exp/log
    (#"(?<!PRMath\.)exp\("#,
     "Direct exp() forbidden - use PRMath.expSafe",
     ["Core/Evidence/**"]),

    (#"(?<!PRMath\.)log\("#,
     "Direct log() forbidden - use PRMath if needed",
     ["Core/Evidence/**"]),
]
```

### 10.3 Determinism Violations

```swift
static let determinismPatterns: [(regex: String, message: String, paths: [String])] = [
    // Random/Time
    (#"Date\(\)"#,
     "Date() forbidden - use passed timestamp",
     ["Core/Evidence/**"]),

    (#"UUID\(\)"#,
     "UUID() forbidden - use deterministic IDs",
     ["Core/Evidence/**"]),

    (#"\.random"#,
     "random forbidden - all values must be deterministic",
     ["Core/Evidence/**"]),

    // Non-deterministic iteration
    (#"for\s+\w+\s+in\s+\w+\.values\b"#,
     "Dictionary.values iteration forbidden - use sortedIterate",
     ["Core/Evidence/**"]),

    (#"for\s+\w+\s+in\s+\w+\.keys\b"#,
     "Dictionary.keys iteration forbidden - use sortedIterate",
     ["Core/Evidence/**"]),

    (#"Set<.*>\.forEach"#,
     "Set.forEach forbidden - use BucketBitset",
     ["Core/Evidence/**"]),

    // autoDetect in core
    (#"PerformanceTier\.autoDetect\(\)"#,
     "autoDetect() forbidden in core - use injected TierContext",
     ["Core/Evidence/PR3/**"]),
]
```

### 10.4 Type Safety

```swift
static let typeSafetyPatterns: [(regex: String, message: String, paths: [String])] = [
    // Float precision
    (#":\s*Float\s*[,\)\{]"#,
     "Float type forbidden - use Double",
     ["Core/Evidence/**"]),

    (#"Float\("#,
     "Float() conversion forbidden - use Double",
     ["Core/Evidence/**"]),

    // Wrong quality source
    (#"observation\.quality"#,
     "observation.quality forbidden - use PR3InternalQuality",
     ["Core/Evidence/PR3/**"]),

    // Generic quantizer
    (#"Quantizer\.quantize\("#,
     "Use type-safe QuantizerQ01 or QuantizerAngle",
     ["Core/Evidence/**"]),
]
```

---

## Part 11: File Deliverables (Complete)

### 11.1 New Files

```
Core/Evidence/PR3/
├── GateCoverageTracker.swift         ✓ Uses Bitset, ZeroTrig
├── GateGainFunctions.swift           ✓ Uses PRMath facade
├── GateQualityComputer.swift         ✓ Integration layer
├── GateInvariants.swift              ✓ Runtime validation
├── PR3InternalQuality.swift          ✓ L2+/L3 classification
└── Internal/
    ├── BucketBitset.swift            ✓ UInt32/UInt16 bitset
    ├── CircularSpanBitset.swift      ✓ Span on bitset
    ├── ZeroTrigBucketing.swift       ✓ No-trig angle→bucket
    └── ShadowTrigVerifier.swift      ✓ Trig verification (DEBUG)

Core/Evidence/PRMath/
├── PRMath.swift                      ✓ Unified facade
├── PRMathDouble.swift                ✓ Double implementation (CANONICAL)
├── PRMathFast.swift                  ✓ LUT implementation (SHADOW ONLY)
├── PRMathFixed.swift                 ✓ Fixed placeholder
├── StableLogistic.swift              ✓ Piecewise sigmoid
├── LUTSigmoidGuarded.swift           ✓ LUT with monotonicity guard
├── QuantizerQ01.swift                ✓ [0,1] quantization
└── QuantizerAngle.swift              ✓ Angle quantization

Core/Evidence/Smoothing/
├── SmartAntiBoostSmoother.swift      ✓ Conditional anti-boost
└── SmootherConfig.swift              ✓ Configuration

Core/Evidence/Validation/
├── GateInputValidator.swift          ✓ Closed enum validation
└── GateInputInvalidReason.swift      ✓ Reason enum

Core/Evidence/Constants/
└── HardGatesV13.swift                ✓ Threshold + TransitionWidth

Core/Evidence/Vector/
└── EvidenceVector3.swift             ✓ No simd

Core/Evidence/Tier/
├── PerformanceTier.swift             ✓ Tier enum
└── TierContext.swift                 ✓ Injected context

Tests/Evidence/PR3/
├── GateGainFunctionsTests.swift      ✓ Gain function tests
├── GateCoverageTrackerTests.swift    ✓ Tracker tests
├── ZeroTrigBucketingTests.swift      ✓ Zero-trig accuracy tests
├── BitsetSpanTests.swift             ✓ Bitset span tests
├── GateDeterminismTests.swift        ✓ 100-run determinism
├── GateGoldenTests.swift             ✓ Golden tests (Double only)
├── GateFastBackendTests.swift        ✓ Error bound tests
├── GateIntegrationTests.swift        ✓ End-to-end tests
└── SmartSmootherTests.swift          ✓ Smoother tests

Tests/Evidence/Fixtures/Golden/
└── gate_quality_golden_v1.json       ✓ Golden values (Int64)
```

---

## Part 12: Acceptance Criteria (Extended)

### 12.1 Zero-Trig Determinism

| ID | Criterion | Verification |
|----|-----------|--------------|
| ZT1 | No atan2() in canonical path | Lint + grep |
| ZT2 | No asin() in canonical path | Lint + grep |
| ZT3 | No sin()/cos() runtime calls (only precomputed) | Lint |
| ZT4 | Shadow verifier shows 0 mismatches on test suite | Unit test |
| ZT5 | Same bucket on iOS/Linux for all test angles | CI cross-platform |

### 12.2 Bitset Correctness

| ID | Criterion | Verification |
|----|-----------|--------------|
| BT1 | ThetaBucketBitset.count == popcount(bits) | Unit test |
| BT2 | PhiBucketBitset maintains sorted iteration | Unit test |
| BT3 | CircularSpanBitset handles wrap-around | Unit test |
| BT4 | Bitset uses no heap allocation | Code review |
| BT5 | Bitset iteration is deterministic | Unit test |

### 12.3 Tier Injection

| ID | Criterion | Verification |
|----|-----------|--------------|
| TI1 | No autoDetect() in Core/Evidence/PR3/ | Lint |
| TI2 | All tests use TierContext.forTesting | Code review |
| TI3 | Golden tests only run on Double backend | Unit test |
| TI4 | Fast backend tests check error bounds | Unit test |

### 12.4 Smoother Behavior

| ID | Criterion | Verification |
|----|-----------|--------------|
| SM1 | Anti-boost only on suspicious jumps | Unit test |
| SM2 | Normal improvement uses normalImproveFactor | Unit test |
| SM3 | K consecutive invalid → worst-case | Unit test |
| SM4 | No stuck at old good value | Unit test |

### 12.5 Quantization Safety

| ID | Criterion | Verification |
|----|-----------|--------------|
| QS1 | QuantizerQ01 only used for [0,1] values | Lint |
| QS2 | No generic Quantizer in PR3 | Lint |
| QS3 | Golden fixtures record metadata | Unit test |

---

## Part 13: Implementation Phase Order (Final)

```
Phase 1: Math Foundation (Zero Dependencies)
├── PRMath.swift (facade)
├── PRMathDouble.swift (canonical)
├── StableLogistic.swift
├── QuantizerQ01.swift
├── QuantizerAngle.swift
└── TierContext.swift

Phase 2: Zero-Trig Bucketing
├── ZeroTrigPhiBucketing.swift (precomputed sin boundaries)
├── ZeroTrigThetaBucketing.swift (precomputed unit vectors)
└── ShadowTrigVerifier.swift (DEBUG only)

Phase 3: Bitset Infrastructure
├── ThetaBucketBitset.swift (UInt32)
├── PhiBucketBitset.swift (UInt16)
└── CircularSpanBitset.swift

Phase 4: Constants & Validation
├── HardGatesV13.swift (threshold + transitionWidth)
├── GateInputValidator.swift
├── GateInputInvalidReason.swift
└── EvidenceVector3.swift

Phase 5: Smoothing
├── SmartAntiBoostSmoother.swift
└── SmootherConfig.swift

Phase 6: Core Components
├── GateCoverageTracker.swift (uses Bitset, ZeroTrig)
├── GateGainFunctions.swift (uses PRMath)
├── PR3InternalQuality.swift
└── GateInvariants.swift

Phase 7: Integration
├── GateQualityComputer.swift
└── Modify IsolatedEvidenceEngine.swift (ADD only)

Phase 8: Shadow/Benchmark (Optional)
├── PRMathFast.swift
└── LUTSigmoidGuarded.swift

Phase 9: Tests
├── All test files
├── Golden fixtures
└── Cross-platform CI

Phase 10: CI
├── ForbiddenPatternLint updates
├── Whitelist enforcement
└── Cross-platform golden validation
```

---

## CHANGELOG from V4

| Section | Change |
|---------|--------|
| Part 0 | Added Pillar 2 (Zero-Trig) and Pillar 7 (Tier Injection) |
| Part 1 | Physical directory isolation with strict import rules |
| Part 2 | Zero-Trig Determinism (atan2/asin completely eliminated) |
| Part 3 | Bitset Bucket World (UInt32/UInt16, no sorted array) |
| Part 4 | Tier Injection (no autoDetect in core) |
| Part 5 | LUT with monotonicity guard and no-FMA interpolation |
| Part 6 | Smart Anti-Boost (conditional, not always-on) |
| Part 7 | Type-safe quantizers (Q01, Angle, not generic) |
| Part 8 | Golden tests Double-only, others test error bounds |
| Part 9 | Threshold + TransitionWidth (not raw slope) |
| Part 10 | Extended forbidden patterns for new rules |

---

## Summary: V5 Key Innovations

1. **Zero-Trig Determinism**: libm completely eliminated from canonical path
2. **Bitset Bucket World**: UInt32/UInt16 bitsets, O(1) operations, zero edge cases
3. **Physical Isolation**: Strict directory boundaries, compile-time import rules
4. **Tier Injection**: No autoDetect in core, explicit injection only
5. **Smart Anti-Boost**: Conditional stability, not punishment
6. **Type-Safe Quantization**: Q01 for gains, Angle for degrees, no misuse
7. **TransitionWidth Semantics**: Future-proof for Fixed-point upgrade
8. **Golden = Double Only**: Other backends test error bounds, not exact match
9. **Shadow Verification**: Trig-based validation in DEBUG, mismatch tracking
10. **LUT Monotonicity Guard**: Enforced at construction, no-FMA interpolation

**Document Version:** 5.0 (Bulletproof Architecture + Zero-Trig Determinism)
**Author:** Claude Code
**Created:** 2026-01-31
**Status:** READY FOR IMPLEMENTATION
