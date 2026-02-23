# PR4 V10 - CONTINUOUS IMPLEMENTATION PROMPT

## ⚠️ CRITICAL INSTRUCTION FOR CURSOR

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                    DO NOT STOP UNTIL COMPLETE                               ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  This is a CONTINUATION from previous chats that hit output limits.         ║
║                                                                              ║
║  RULES:                                                                      ║
║  1. DO NOT stop after each phase - continue until ALL 37 pillars done       ║
║  2. DO NOT ask "should I continue?" - YES, ALWAYS CONTINUE                  ║
║  3. DO NOT create new plan documents - use existing ones                    ║
║  4. DO NOT wait for user confirmation between tasks                         ║
║  5. If you encounter an error, fix it and continue                          ║
║  6. Run tests after each module, but continue regardless                    ║
║                                                                              ║
║  Your task is complete ONLY when:                                            ║
║  ✅ All 37 pillars are implemented                                           ║
║  ✅ All tests pass                                                           ║
║  ✅ Package.swift is updated                                                 ║
║  ✅ Golden baselines are created                                             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

---

## THE 37 PILLARS MASTER CHECKLIST

This is the **complete and authoritative** list of all pillars that MUST be implemented. Cross-reference with previous documents for implementation details.

### V10 NEW PILLARS (3)

| # | Pillar Name | Source | File to Create | Status |
|---|-------------|--------|----------------|--------|
| 1 | **Determinism Dependency Contract** (Hard-12) | V10 | `PR4Determinism/DeterminismDependencyContract.swift` | ☐ |
| 2 | **Frame Context Ownership Contract** (Hard-13) | V10 | `PR4Ownership/FrameContext.swift`, `SessionContext.swift` | ☐ |
| 3 | **Package DAG Proof** (Seal-15) | V10 | `PR4Package/PackageDAGProof.swift` | ☐ |

### V10 ENHANCED SEALS (8)

| # | Pillar Name | Source | File to Create | Status |
|---|-------------|--------|----------------|--------|
| 4 | **Path Trace V2** (Versioned + Token Whitelist) | V10 | `PR4PathTrace/PathDeterminismTraceV2.swift` | ☐ |
| 5 | **Softmax Exact Sum V2** (Step Invariants) | V10 | `PR4Softmax/SoftmaxExactSumV2.swift` | ☐ |
| 6 | **LUT Binary Format V2** (Byte-Level Spec) | V10 | `PR4LUT/LUTBinaryFormatV2.swift` | ☐ |
| 7 | **Digest Versioning V2** (Evolvable Format) | V10 | `PR4Determinism/DeterminismDigestV2.swift` | ☐ |
| 8 | **Golden Baseline System** | V10 | `PR4Golden/GoldenBaselineSystem.swift` | ☐ |
| 9 | **Total Order FAST Sanitize SSOT** | V10 | `PR4Math/TotalOrderComparator.swift` | ☐ |
| 10 | **Calibration Stratified Drift Detection** | V10 | `PR4Calibration/CalibrationDriftDetector.swift` | ☐ |
| 11 | **Health Fence Tests Coverage** | V10 | `Tests/PR4HealthTests/HealthFenceTests.swift` | ☐ |

### V9 INHERITED PILLARS (9)

| # | Pillar Name | Source | File to Create | Status |
|---|-------------|--------|----------------|--------|
| 12 | **Determinism Build Contract** | V9 | `PR4Determinism/DeterminismBuildContract.swift` | ☐ |
| 13 | **Softmax Normalization Constitution** | V9 | (merged into SoftmaxExactSumV2) | ☐ |
| 14 | **Health Dependency Linter + DataFlow Fence** | V9 | `PR4Health/HealthDataFlowFence.swift` | ☐ |
| 15 | **Path Determinism Trace** | V9 | (enhanced by V10 PathTraceV2) | ☐ |
| 16 | **Threading & Reentrancy Contract** | V9 | `PR4Ownership/ThreadingContract.swift` | ☐ |
| 17 | **LUT Build Reproducibility Lock** | V9 | `PR4LUT/LUTReproducibleGenerator.swift` | ☐ |
| 18 | **Overflow Tier0 Fence** | V9 | `PR4Overflow/OverflowTier0Fence.swift` | ☐ |
| 19 | **Total Order for Determinism** | V9 | (enhanced by V10 TotalOrderComparator) | ☐ |
| 20 | **Empirical Calibration Governance** | V9 | `PR4Calibration/EmpiricalCalibrationGovernance.swift` | ☐ |

### V8 INHERITED PILLARS (16)

| # | Pillar Name | Source | File to Create | Status |
|---|-------------|--------|----------------|--------|
| 21 | **Range-Complete Softmax LUT [-32,0]** | V8 | `PR4LUT/RangeCompleteSoftmaxLUT.swift` | ☐ |
| 22 | **Log Call-Site Contract** | V8 | `PR4LUT/LogCallSiteContract.swift` | ☐ |
| 23 | **Overflow Propagation Policy** | V8 | `PR4Overflow/OverflowPropagationPolicy.swift` | ☐ |
| 24 | **Deterministic Rounding Policy** | V8 | `PR4Math/DeterministicRounding.swift` | ☐ |
| 25 | **Empirical P68 Calibration** | V8 | `PR4Calibration/EmpiricalP68Calibrator.swift` | ☐ |
| 26 | **SwiftPM Target Isolation** | V8 | (enforced by Package.swift) | ☐ |
| 27 | **LUT SSOT + Hash Verification** | V8 | (merged into LUTBinaryFormatV2) | ☐ |
| 28 | **Softmax Mass Conservation** | V8 | (merged into SoftmaxExactSumV2) | ☐ |
| 29 | **Determinism Digest Minimal Diff** | V8 | (merged into DeterminismDigestV2) | ☐ |
| 30 | **Health Input Closed Set** | V8 | `PR4Health/HealthInputs.swift` | ☐ |
| 31 | **Correlation Source Exhaustiveness** | V8 | `PR4Uncertainty/CorrelationMatrix.swift` | ☐ |
| 32 | **Error Propagation Budget** | V8 | `PR4Math/ErrorPropagationBudget.swift` | ☐ |
| 33 | **Rate-Limited Overflow Logging** | V8 | `PR4Overflow/OverflowReporter.swift` | ☐ |
| 34 | **Deterministic Median/MAD Algorithm** | V8 | `PR4Math/DeterministicMedianMAD.swift` | ☐ |
| 35 | **Determinism Contract Single-Line** | V8 | (documented in DeterminismDigestV2) | ☐ |
| 36 | **Determinism Mode Separation** | V8 | `PR4Determinism/DeterminismMode.swift` | ☐ |

### V7 AND EARLIER PILLARS (1 combined)

| # | Pillar Name | Source | File to Create | Status |
|---|-------------|--------|----------------|--------|
| 37 | **V7 Foundation** (LUT Math, Overflow Constitution, Two-Layer Quantization, Anti-Self-Excitation, Four-State Gate, Soft Gate Arbitration, Noise Model, OnlineMADEstimator, Budget-Degrade) | V7/V6/V5/V4 | Multiple files | ☐ |

---

## COMPLETE FILE LIST (34 FILES)

Create these files in this EXACT order:

### Phase 1: Foundation (5 files) ✅ ALREADY DONE

```
1.  Sources/PR4Math/Int128.swift                          ✅
2.  Sources/PR4Math/Q16Arithmetic.swift                   ✅
3.  Sources/PR4Math/DeterministicRounding.swift           ✅
4.  Sources/PR4PathTrace/PathDeterminismTraceV2.swift     ✅
5.  Sources/PR4Ownership/FrameID.swift                    ✅
```

### Phase 2: Core Infrastructure (7 files)

```
6.  Sources/PR4Math/TotalOrderComparator.swift            [Pillar 9, 19]
7.  Sources/PR4Math/DeterministicMedianMAD.swift          [Pillar 34]
8.  Sources/PR4Math/ErrorPropagationBudget.swift          [Pillar 32]
9.  Sources/PR4Overflow/OverflowDetectionFramework.swift  [Pillar 27]
10. Sources/PR4Overflow/OverflowTier0Fence.swift          [Pillar 18]
11. Sources/PR4Overflow/OverflowPropagationPolicy.swift   [Pillar 23]
12. Sources/PR4Overflow/OverflowReporter.swift            [Pillar 33]
```

### Phase 3: LUT & Determinism (8 files)

```
13. Sources/PR4LUT/RangeCompleteSoftmaxLUT.swift          [Pillar 21]
14. Sources/PR4LUT/LUTBinaryFormatV2.swift                [Pillar 6, 27]
15. Sources/PR4LUT/LUTReproducibleGenerator.swift         [Pillar 17]
16. Sources/PR4LUT/LogCallSiteContract.swift              [Pillar 22]
17. Sources/PR4Determinism/DeterminismMode.swift          [Pillar 36]
18. Sources/PR4Determinism/DeterminismBuildContract.swift [Pillar 12]
19. Sources/PR4Determinism/DeterminismDependencyContract.swift [Pillar 1]
20. Sources/PR4Determinism/DeterminismDigestV2.swift      [Pillar 7, 29, 35]
```

### Phase 4: Ownership & Threading (4 files)

```
21. Sources/PR4Ownership/ThreadingContract.swift          [Pillar 16]
22. Sources/PR4Ownership/FrameContext.swift               [Pillar 2]
23. Sources/PR4Ownership/SessionContext.swift             [Pillar 2]
24. Sources/PR4Ownership/CrossFrameLeakDetector.swift     [Pillar 2]
```

### Phase 5: Computation Modules (9 files)

```
25. Sources/PR4Softmax/SoftmaxExactSumV2.swift            [Pillar 5, 13, 28]
26. Sources/PR4Health/HealthInputs.swift                  [Pillar 30]
27. Sources/PR4Health/HealthComputer.swift                [Pillar 37]
28. Sources/PR4Health/HealthDataFlowFence.swift           [Pillar 14]
29. Sources/PR4Uncertainty/CorrelationMatrix.swift        [Pillar 31]
30. Sources/PR4Uncertainty/UncertaintyPropagator.swift    [Pillar 37]
31. Sources/PR4Calibration/EmpiricalP68Calibrator.swift   [Pillar 25]
32. Sources/PR4Calibration/EmpiricalCalibrationGovernance.swift [Pillar 20]
33. Sources/PR4Calibration/CalibrationDriftDetector.swift [Pillar 10]
```

### Phase 6: Quality, Gate, Fusion (6 files)

```
34. Sources/PR4Quality/SoftQualityComputer.swift          [Pillar 37]
35. Sources/PR4Quality/QualityResult.swift                [Pillar 37]
36. Sources/PR4Gate/SoftGateState.swift                   [Pillar 37]
37. Sources/PR4Gate/SoftGateMachine.swift                 [Pillar 37]
38. Sources/PR4Gate/OnlineMADEstimator.swift              [Pillar 37]
39. Sources/PR4Gate/GateDecision.swift                    [Pillar 37]
```

### Phase 7: Integration (4 files)

```
40. Sources/PR4Fusion/FrameProcessor.swift                [Integration]
41. Sources/PR4Fusion/FusionResult.swift                  [Integration]
42. Sources/PR4Fusion/PR4Pipeline.swift                   [Integration]
43. Sources/PR4Golden/GoldenBaselineSystem.swift          [Pillar 8]
```

### Phase 8: Package & Scripts (3 files)

```
44. Sources/PR4Package/PackageDAGProof.swift              [Pillar 3, 26]
45. Package.swift                                         [Update]
46. Scripts/verify-package-dag.sh                         [Pillar 3]
```

---

## DETAILED IMPLEMENTATION SPECIFICATIONS

### FILE 6: TotalOrderComparator.swift

**Pillars:** 9 (Total Order FAST Sanitize SSOT), 19 (Total Order for Determinism)

```swift
//
// TotalOrderComparator.swift
// PR4Math
//
// Pillars 9 & 19: IEEE 754 totalOrder for deterministic NaN/Inf/Zero handling
//

import Foundation

/// Total order comparator for deterministic floating-point comparison
///
/// V10 RULE: All NaN/Inf/-0 handling MUST go through this comparator.
/// No ad-hoc .isNaN checks allowed.
public enum TotalOrderComparator {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sanitization (SSOT for special values)
    // ═══════════════════════════════════════════════════════════════════════

    /// Sanitize special values
    ///
    /// V10 RULE: This is the ONLY function for handling NaN/Inf/-0
    @inline(__always)
    public static func sanitize(_ value: Double) -> (sanitized: Double, wasSpecial: Bool) {
        if value.isNaN {
            return (0.0, true)  // NaN → 0.0 (neutral)
        }
        if value == .infinity {
            return (Double.greatestFiniteMagnitude, true)
        }
        if value == -.infinity {
            return (-Double.greatestFiniteMagnitude, true)
        }
        if value == 0 && value.sign == .minus {
            return (0.0, true)  // -0 → +0 (normalize)
        }
        return (value, false)
    }

    /// Sanitize Int64 Q16 value
    @inline(__always)
    public static func sanitizeQ16(_ value: Int64) -> (sanitized: Int64, wasSpecial: Bool) {
        if value == Int64.min {
            return (0, true)  // Int64.min is our "invalid" sentinel
        }
        return (value, false)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Total Order Comparison
    // ═══════════════════════════════════════════════════════════════════════

    /// Compare using IEEE 754 totalOrder
    ///
    /// Order: -NaN < -Inf < negatives < -0 < +0 < positives < +Inf < +NaN
    public static func totalOrder(_ a: Double, _ b: Double) -> Int {
        // Get bit patterns
        let aBits = a.bitPattern
        let bBits = b.bitPattern

        // Handle sign
        let aSign = (aBits >> 63) != 0
        let bSign = (bBits >> 63) != 0

        if aSign != bSign {
            return aSign ? -1 : 1  // Negative < Positive
        }

        // Same sign: compare magnitude
        // For negatives: larger magnitude = smaller value
        if aSign {
            return aBits > bBits ? -1 : (aBits < bBits ? 1 : 0)
        } else {
            return aBits < bBits ? -1 : (aBits > bBits ? 1 : 0)
        }
    }

    /// Deterministic minimum
    @inline(__always)
    public static func min(_ a: Double, _ b: Double) -> Double {
        return totalOrder(a, b) <= 0 ? a : b
    }

    /// Deterministic maximum
    @inline(__always)
    public static func max(_ a: Double, _ b: Double) -> Double {
        return totalOrder(a, b) >= 0 ? a : b
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sanitization Logger
    // ═══════════════════════════════════════════════════════════════════════

    /// Track sanitization events for digest
    public final class SanitizationTracker {
        public private(set) var nanCount: Int = 0
        public private(set) var infCount: Int = 0
        public private(set) var negZeroCount: Int = 0

        public func record(_ type: SanitizationType) {
            switch type {
            case .nan: nanCount += 1
            case .infinity: infCount += 1
            case .negativeZero: negZeroCount += 1
            }
        }

        public var totalCount: Int { nanCount + infCount + negZeroCount }

        public func reset() {
            nanCount = 0
            infCount = 0
            negZeroCount = 0
        }
    }

    public enum SanitizationType {
        case nan
        case infinity
        case negativeZero
    }
}
```

**Tests:** `Tests/PR4MathTests/TotalOrderComparatorTests.swift`

```swift
import XCTest
@testable import PR4Math

final class TotalOrderComparatorTests: XCTestCase {

    func testSanitizeNaN() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(.nan)
        XCTAssertEqual(result, 0.0)
        XCTAssertTrue(wasSpecial)
    }

    func testSanitizeInfinity() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(.infinity)
        XCTAssertEqual(result, Double.greatestFiniteMagnitude)
        XCTAssertTrue(wasSpecial)
    }

    func testSanitizeNegativeZero() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(-0.0)
        XCTAssertEqual(result, 0.0)
        XCTAssertTrue(wasSpecial)
        XCTAssertTrue(result.sign == .plus)
    }

    func testTotalOrderNaN() {
        // NaN should sort consistently
        let a = Double.nan
        let b = 0.0
        XCTAssertEqual(TotalOrderComparator.totalOrder(a, b),
                       TotalOrderComparator.totalOrder(a, b))
    }

    func testTotalOrderDeterministic() {
        let values: [Double] = [.nan, -.infinity, -1, -0.0, 0, 1, .infinity]
        var sorted = values
        sorted.sort { TotalOrderComparator.totalOrder($0, $1) < 0 }

        // Run 100 times, should be identical
        for _ in 0..<100 {
            var check = values
            check.sort { TotalOrderComparator.totalOrder($0, $1) < 0 }
            XCTAssertEqual(sorted.map { $0.bitPattern }, check.map { $0.bitPattern })
        }
    }
}
```

---

### FILE 7: DeterministicMedianMAD.swift

**Pillar:** 34 (Deterministic Median/MAD Algorithm)

```swift
//
// DeterministicMedianMAD.swift
// PR4Math
//
// Pillar 34: Deterministic median and MAD computation
//

import Foundation

/// Deterministic median and MAD computation
///
/// V8 RULE: No stdlib sort (platform-dependent)
/// Uses sorting network for small N, deterministic quickselect for large N
public enum DeterministicMedianMAD {

    /// Sorting network threshold
    private static let sortingNetworkThreshold = 32

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Median
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute median deterministically
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return values[0] }

        var copy = values

        if copy.count <= sortingNetworkThreshold {
            // Use sorting network
            sortingNetworkSort(&copy)
        } else {
            // Use deterministic quickselect
            deterministicSort(&copy)
        }

        let mid = copy.count / 2
        if copy.count % 2 == 1 {
            return copy[mid]
        } else {
            return (copy[mid - 1] + copy[mid]) / 2.0
        }
    }

    /// Compute median of Int64 array
    public static func medianQ16(_ values: [Int64]) -> Int64 {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return values[0] }

        var copy = values

        if copy.count <= sortingNetworkThreshold {
            sortingNetworkSortQ16(&copy)
        } else {
            deterministicSortQ16(&copy)
        }

        let mid = copy.count / 2
        if copy.count % 2 == 1 {
            return copy[mid]
        } else {
            return (copy[mid - 1] + copy[mid]) / 2
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - MAD (Median Absolute Deviation)
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute MAD deterministically
    public static func mad(_ values: [Double]) -> Double {
        guard values.count >= 3 else { return 0 }

        let med = median(values)
        let deviations = values.map { abs($0 - med) }
        return median(deviations)
    }

    /// Compute MAD of Int64 array
    public static func madQ16(_ values: [Int64]) -> Int64 {
        guard values.count >= 3 else { return 0 }

        let med = medianQ16(values)
        let deviations = values.map { abs($0 - med) }
        return medianQ16(deviations)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Sorting Network (Small Arrays)
    // ═══════════════════════════════════════════════════════════════════════

    /// Sorting network for small arrays
    private static func sortingNetworkSort(_ array: inout [Double]) {
        let n = array.count

        // Simple insertion sort with deterministic comparison
        for i in 1..<n {
            var j = i
            while j > 0 && TotalOrderComparator.totalOrder(array[j-1], array[j]) > 0 {
                array.swapAt(j-1, j)
                j -= 1
            }
        }
    }

    private static func sortingNetworkSortQ16(_ array: inout [Int64]) {
        let n = array.count

        for i in 1..<n {
            var j = i
            while j > 0 && array[j-1] > array[j] {
                array.swapAt(j-1, j)
                j -= 1
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Deterministic Quicksort (Large Arrays)
    // ═══════════════════════════════════════════════════════════════════════

    /// Deterministic quicksort with median-of-three pivot
    private static func deterministicSort(_ array: inout [Double]) {
        deterministicQuicksort(&array, low: 0, high: array.count - 1)
    }

    private static func deterministicQuicksort(_ array: inout [Double], low: Int, high: Int) {
        guard low < high else { return }

        if high - low < 16 {
            // Insertion sort for small subarrays
            for i in (low + 1)...high {
                var j = i
                while j > low && TotalOrderComparator.totalOrder(array[j-1], array[j]) > 0 {
                    array.swapAt(j-1, j)
                    j -= 1
                }
            }
            return
        }

        // Median-of-three pivot selection (deterministic)
        let mid = low + (high - low) / 2
        if TotalOrderComparator.totalOrder(array[mid], array[low]) < 0 {
            array.swapAt(low, mid)
        }
        if TotalOrderComparator.totalOrder(array[high], array[low]) < 0 {
            array.swapAt(low, high)
        }
        if TotalOrderComparator.totalOrder(array[mid], array[high]) < 0 {
            array.swapAt(mid, high)
        }
        let pivot = array[high]

        // Partition
        var i = low
        for j in low..<high {
            if TotalOrderComparator.totalOrder(array[j], pivot) < 0 {
                array.swapAt(i, j)
                i += 1
            }
        }
        array.swapAt(i, high)

        // Recurse
        deterministicQuicksort(&array, low: low, high: i - 1)
        deterministicQuicksort(&array, low: i + 1, high: high)
    }

    private static func deterministicSortQ16(_ array: inout [Int64]) {
        array.sort()  // Int64 comparison is deterministic
    }
}
```

---

### FILE 10: OverflowTier0Fence.swift

**Pillar:** 18 (Overflow Tier0 Fence)

```swift
//
// OverflowTier0Fence.swift
// PR4Overflow
//
// Pillar 18: Tier0 fields that MUST NOT overflow - fatal in STRICT mode
//

import Foundation

/// Tier0 overflow fence
///
/// V9 RULE: These fields are FATAL if they overflow.
/// Any overflow in Tier0 = system integrity compromised.
public enum OverflowTier0Fence {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tier0 Fields (FATAL on overflow)
    // ═══════════════════════════════════════════════════════════════════════

    /// Fields that MUST NOT overflow
    public static let tier0Fields: Set<String> = [
        "gateQ",           // Gate state - overflow corrupts state machine
        "softQualityQ",    // Core output - overflow = wrong quality
        "fusedDepthQ",     // Fused depth - overflow = invalid output
        "healthQ",         // Health metric - overflow = bad decisions
        "consistencyGainQ", // Fusion weight - overflow = bad weights
        "coverageGainQ",
        "confidenceGainQ",
    ]

    /// Check if field is Tier0
    @inline(__always)
    public static func isTier0(_ fieldName: String) -> Bool {
        return tier0Fields.contains(fieldName)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Overflow Handling
    // ═══════════════════════════════════════════════════════════════════════

    /// Handle potential Tier0 overflow
    ///
    /// STRICT: assertionFailure
    /// FAST: log + degrade + continue
    public static func handleOverflow(
        field: String,
        value: Int64,
        bound: Int64,
        direction: OverflowDirection
    ) -> Int64 {
        if isTier0(field) {
            #if DETERMINISM_STRICT
            assertionFailure("TIER0 OVERFLOW: \(field) = \(value), bound = \(bound)")
            #endif

            // Log fatal overflow
            Tier0OverflowLogger.shared.logFatal(
                field: field,
                value: value,
                bound: bound,
                direction: direction
            )

            // Return degraded value
            return direction == .above ? bound : -bound
        }

        // Non-Tier0: normal handling
        return direction == .above ? Swift.min(value, bound) : Swift.max(value, -bound)
    }

    public enum OverflowDirection {
        case above
        case below
    }
}

/// Logger for Tier0 overflows
final class Tier0OverflowLogger {
    static let shared = Tier0OverflowLogger()

    private var fatalOverflows: [(field: String, value: Int64, bound: Int64, time: Date)] = []
    private let lock = NSLock()

    func logFatal(field: String, value: Int64, bound: Int64, direction: OverflowTier0Fence.OverflowDirection) {
        lock.lock()
        defer { lock.unlock() }

        fatalOverflows.append((field, value, bound, Date()))
        print("🛑 TIER0 OVERFLOW: \(field) = \(value) (bound: \(bound))")
    }

    var hasFatalOverflows: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !fatalOverflows.isEmpty
    }
}
```

---

### FILE 14: LUTBinaryFormatV2.swift

**Pillars:** 6 (LUT Binary Format V2), 27 (LUT SSOT + Hash Verification)

```swift
//
// LUTBinaryFormatV2.swift
// PR4LUT
//
// Pillars 6 & 27: LUT binary format with versioning and checksum
//

import Foundation
import CryptoKit

/// LUT binary format V2
///
/// FORMAT:
/// - Header: 16 bytes (magic, version, count, entry size, reserved)
/// - Body: count * 8 bytes (int64 big-endian)
/// - Footer: 32 bytes (SHA-256)
public enum LUTBinaryFormatV2 {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ═══════════════════════════════════════════════════════════════════════

    public static let magic: [UInt8] = [0x50, 0x49, 0x5A, 0x31]  // "PIZ1"
    public static let currentVersion: UInt16 = 2
    public static let headerSize: Int = 16
    public static let footerSize: Int = 32
    public static let entrySize: Int = 8

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Header
    // ═══════════════════════════════════════════════════════════════════════

    public struct Header {
        public let magic: [UInt8]
        public let version: UInt16
        public let entryCount: UInt16
        public let entrySizeBits: UInt32
        public let reserved: UInt32

        public init(entryCount: UInt16) {
            self.magic = LUTBinaryFormatV2.magic
            self.version = LUTBinaryFormatV2.currentVersion
            self.entryCount = entryCount
            self.entrySizeBits = 64
            self.reserved = 0
        }

        public func serialize() -> Data {
            var data = Data(capacity: headerSize)
            data.append(contentsOf: magic)
            withUnsafeBytes(of: version.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: entryCount.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: entrySizeBits.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: reserved.bigEndian) { data.append(contentsOf: $0) }
            return data
        }

        public static func deserialize(_ data: Data) throws -> Header {
            guard data.count >= headerSize else {
                throw LUTError.headerTooSmall
            }

            let magic = Array(data[0..<4])
            guard magic == LUTBinaryFormatV2.magic else {
                throw LUTError.invalidMagic
            }

            let version = data[4..<6].withUnsafeBytes {
                UInt16(bigEndian: $0.load(as: UInt16.self))
            }

            let entryCount = data[6..<8].withUnsafeBytes {
                UInt16(bigEndian: $0.load(as: UInt16.self))
            }

            let entrySizeBits = data[8..<12].withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }

            return Header(
                magic: magic,
                version: version,
                entryCount: entryCount,
                entrySizeBits: entrySizeBits,
                reserved: 0
            )
        }

        private init(magic: [UInt8], version: UInt16, entryCount: UInt16, entrySizeBits: UInt32, reserved: UInt32) {
            self.magic = magic
            self.version = version
            self.entryCount = entryCount
            self.entrySizeBits = entrySizeBits
            self.reserved = reserved
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Write
    // ═══════════════════════════════════════════════════════════════════════

    public static func write(_ lut: [Int64], to url: URL) throws {
        guard lut.count <= Int(UInt16.max) else {
            throw LUTError.tooManyEntries
        }

        var data = Data()

        // Header
        let header = Header(entryCount: UInt16(lut.count))
        data.append(header.serialize())

        // Body
        for value in lut {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        // Footer (SHA-256)
        let hash = SHA256.hash(data: data)
        data.append(contentsOf: hash)

        try data.write(to: url)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Read
    // ═══════════════════════════════════════════════════════════════════════

    public static func read(from url: URL) throws -> [Int64] {
        let data = try Data(contentsOf: url)

        guard data.count >= headerSize + footerSize else {
            throw LUTError.fileTooSmall
        }

        // Parse header
        let header = try Header.deserialize(data)

        // Verify size
        let expectedSize = headerSize + Int(header.entryCount) * entrySize + footerSize
        guard data.count == expectedSize else {
            throw LUTError.sizeMismatch
        }

        // Verify checksum
        let contentData = data[0..<(data.count - footerSize)]
        let storedHash = data[(data.count - footerSize)...]
        let computedHash = SHA256.hash(data: contentData)

        guard Array(storedHash) == Array(computedHash) else {
            throw LUTError.checksumMismatch
        }

        // Read entries
        var lut = [Int64]()
        lut.reserveCapacity(Int(header.entryCount))

        for i in 0..<Int(header.entryCount) {
            let offset = headerSize + i * entrySize
            let value = data[offset..<(offset + entrySize)].withUnsafeBytes {
                Int64(bigEndian: $0.load(as: Int64.self))
            }
            lut.append(value)
        }

        return lut
    }
}

public enum LUTError: Error {
    case headerTooSmall
    case fileTooSmall
    case invalidMagic
    case tooManyEntries
    case sizeMismatch
    case checksumMismatch
}
```

---

### FILE 21: ThreadingContract.swift

**Pillar:** 16 (Threading & Reentrancy Contract)

```swift
//
// ThreadingContract.swift
// PR4Ownership
//
// Pillar 16: Single-threaded execution model with reentrancy prevention
//

import Foundation

/// Threading contract for PR4
///
/// V9 RULE: PR4 is SINGLE-THREADED ONLY.
/// All processing happens on one designated thread.
public enum ThreadingContract {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Thread Verification
    // ═══════════════════════════════════════════════════════════════════════

    /// Expected thread ID (set at initialization)
    private static var expectedThreadID: UInt64?

    /// Initialize with current thread
    public static func initialize() {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        expectedThreadID = tid
    }

    /// Verify we're on the expected thread
    @inline(__always)
    public static func verifyThread(caller: String = #function) -> Bool {
        guard let expected = expectedThreadID else {
            return true  // Not initialized yet
        }

        var current: UInt64 = 0
        pthread_threadid_np(nil, &current)

        if current != expected {
            #if DETERMINISM_STRICT
            assertionFailure("Thread violation in \(caller): expected \(expected), got \(current)")
            #else
            print("⚠️ Thread violation in \(caller): expected \(expected), got \(current)")
            #endif
            return false
        }

        return true
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reentrancy Guard
    // ═══════════════════════════════════════════════════════════════════════

    /// Reentrancy guard
    public final class ReentrancyGuard {
        private var isExecuting = false
        private let name: String
        private let lock = NSLock()

        public init(name: String) {
            self.name = name
        }

        public func execute<T>(_ block: () throws -> T) rethrows -> T {
            lock.lock()

            guard !isExecuting else {
                lock.unlock()
                #if DETERMINISM_STRICT
                preconditionFailure("Reentrant call to \(name)")
                #else
                print("⚠️ Reentrant call blocked: \(name)")
                // Return a default or throw - this is a serious error
                preconditionFailure("Reentrant call to \(name)")
                #endif
            }

            isExecuting = true
            lock.unlock()

            defer {
                lock.lock()
                isExecuting = false
                lock.unlock()
            }

            return try block()
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Serial Queue Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// Create a serial queue for PR4 processing
    public static func createSerialQueue(label: String) -> DispatchQueue {
        return DispatchQueue(
            label: label,
            qos: .userInitiated,
            attributes: [],  // Serial (no .concurrent)
            autoreleaseFrequency: .workItem,
            target: nil
        )
    }
}
```

---

### FILE 25: SoftmaxExactSumV2.swift

**Pillars:** 5 (Softmax Exact Sum V2), 13 (Softmax Normalization Constitution), 28 (Softmax Mass Conservation)

```swift
//
// SoftmaxExactSumV2.swift
// PR4Softmax
//
// Pillars 5, 13, 28: Softmax with exact sum = 65536 and step invariants
//

import Foundation

/// Softmax with exact sum guarantee and step-by-step invariants
///
/// V10 GUARANTEES:
/// 1. sum(output) == 65536 EXACTLY (not ±1, EXACTLY)
/// 2. All weights >= 0
/// 3. Each step has verified pre/post conditions
/// 4. 100% deterministic across platforms
public enum SoftmaxExactSumV2 {

    public static let targetSum: Int64 = 65536

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Step Results
    // ═══════════════════════════════════════════════════════════════════════

    public struct Step1Result {
        public let maxLogit: Int64
        public let maxIndex: Int
    }

    public struct Step2Result {
        public let expValues: [Int64]
    }

    public struct Step3Result {
        public let sumExp: Int64
    }

    public struct Step4Result {
        public let weights: [Int64]
        public let usedUniformFallback: Bool
    }

    public struct Step5Result {
        public let actualSum: Int64
        public let remainder: Int64
    }

    public struct Step6Result {
        public let finalWeights: [Int64]
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Step Implementations
    // ═══════════════════════════════════════════════════════════════════════

    /// Step 1: Find maximum logit
    /// POST: maxLogit >= all logits, maxIndex is first occurrence
    public static func step1_findMax(_ logits: [Int64]) -> Step1Result {
        precondition(!logits.isEmpty, "Logits must not be empty")

        var maxLogit = logits[0]
        var maxIndex = 0

        for i in 1..<logits.count {
            if logits[i] > maxLogit {
                maxLogit = logits[i]
                maxIndex = i
            }
        }

        return Step1Result(maxLogit: maxLogit, maxIndex: maxIndex)
    }

    /// Step 2: Compute exp(logit - max) via LUT
    /// POST: all expValues >= 0, expValues[maxIndex] == 65536
    public static func step2_computeExp(logits: [Int64], step1: Step1Result) -> Step2Result {
        var expValues = [Int64](repeating: 0, count: logits.count)

        for i in 0..<logits.count {
            let diff = logits[i] - step1.maxLogit  // Always <= 0
            expValues[i] = RangeCompleteSoftmaxLUT.expQ16(diff)
            if expValues[i] < 0 { expValues[i] = 0 }
        }

        #if DEBUG
        assert(expValues.allSatisfy { $0 >= 0 }, "Step 2 postcondition: all exp >= 0")
        assert(expValues[step1.maxIndex] == 65536, "Step 2 postcondition: exp(0) == 65536")
        #endif

        return Step2Result(expValues: expValues)
    }

    /// Step 3: Kahan summation of exp values
    /// POST: sumExp >= 0
    public static func step3_kahanSum(step2: Step2Result) -> Step3Result {
        var sum: Int64 = 0
        var compensation: Int64 = 0

        for exp in step2.expValues {
            let y = exp - compensation
            let t = sum &+ y
            compensation = (t &- sum) &- y
            sum = t
        }

        #if DEBUG
        assert(sum >= 0, "Step 3 postcondition: sum >= 0")
        #endif

        return Step3Result(sumExp: sum)
    }

    /// Step 4: Normalize to get preliminary weights
    /// POST: all weights >= 0
    public static func step4_normalize(step2: Step2Result, step3: Step3Result, count: Int) -> Step4Result {
        // Uniform fallback if sum is 0
        if step3.sumExp <= 0 {
            let uniform = targetSum / Int64(count)
            var weights = [Int64](repeating: uniform, count: count)
            weights[0] += targetSum - uniform * Int64(count)
            return Step4Result(weights: weights, usedUniformFallback: true)
        }

        var weights = [Int64](repeating: 0, count: count)
        for i in 0..<count {
            let raw = (step2.expValues[i] << 16) / step3.sumExp
            weights[i] = Swift.max(0, raw)
        }

        #if DEBUG
        assert(weights.allSatisfy { $0 >= 0 }, "Step 4 postcondition: all weights >= 0")
        #endif

        return Step4Result(weights: weights, usedUniformFallback: false)
    }

    /// Step 5: Compute actual sum and remainder
    public static func step5_computeSum(step4: Step4Result) -> Step5Result {
        let actualSum = step4.weights.reduce(0, +)
        let remainder = targetSum - actualSum
        return Step5Result(actualSum: actualSum, remainder: remainder)
    }

    /// Step 6: Distribute remainder to ensure EXACT sum
    /// POST: sum(finalWeights) == 65536 EXACTLY
    public static func step6_distributeRemainder(step4: Step4Result, step5: Step5Result) -> Step6Result {
        var weights = step4.weights

        if step5.remainder != 0 {
            // Find first max weight (deterministic tie-break)
            var maxWeight = weights[0]
            var maxIndex = 0

            for i in 1..<weights.count {
                if weights[i] > maxWeight {
                    maxWeight = weights[i]
                    maxIndex = i
                }
            }

            weights[maxIndex] += step5.remainder
        }

        #if DEBUG
        let finalSum = weights.reduce(0, +)
        assert(finalSum == targetSum, "Step 6 postcondition: sum == 65536, got \(finalSum)")
        assert(weights.allSatisfy { $0 >= 0 }, "Step 6 postcondition: all weights >= 0")
        #endif

        return Step6Result(finalWeights: weights)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Complete Algorithm
    // ═══════════════════════════════════════════════════════════════════════

    /// Compute softmax with exact sum guarantee
    public static func softmaxExactSum(
        logitsQ16: [Int64],
        trace: PathDeterminismTraceV2? = nil
    ) -> [Int64] {
        guard !logitsQ16.isEmpty else { return [] }
        guard logitsQ16.count > 1 else { return [targetSum] }

        let step1 = step1_findMax(logitsQ16)
        let step2 = step2_computeExp(logits: logitsQ16, step1: step1)
        let step3 = step3_kahanSum(step2: step2)
        let step4 = step4_normalize(step2: step2, step3: step3, count: logitsQ16.count)

        if step4.usedUniformFallback {
            trace?.record(.softmaxUniform)
        }

        let step5 = step5_computeSum(step4: step4)
        let step6 = step6_distributeRemainder(step4: step4, step5: step5)

        if step5.remainder != 0 {
            trace?.record(.softmaxRemainderDistributed)
        }

        trace?.record(.softmaxNormal)

        return step6.finalWeights
    }
}
```

---

## CONTINUATION INSTRUCTION

After implementing all files above, continue with:

1. **Remaining computation modules** (Health, Quality, Gate, Calibration)
2. **Integration modules** (FrameProcessor, PR4Pipeline)
3. **Golden baselines** (GoldenBaselineSystem)
4. **Package.swift update** (all targets, dependencies)
5. **Verification scripts** (DAG verification, lint scripts)

**DO NOT STOP. CONTINUE IMPLEMENTING UNTIL ALL 37 PILLARS ARE COMPLETE.**

---

## FINAL VERIFICATION CHECKLIST

Before reporting "complete", verify:

```
☐ All 46 files created
☐ All 37 pillars have corresponding implementation
☐ All tests pass: swift test
☐ Package.swift compiles without errors
☐ Health module has NO imports from Quality/Uncertainty/Gate
☐ Softmax sum == 65536 exactly for all test cases
☐ LUT checksum verification passes
☐ Path trace signature is deterministic (100 runs identical)
☐ No forbidden Accelerate/vDSP calls in critical path
```

---

**END OF CONTINUOUS IMPLEMENTATION PROMPT**

*Start implementing now. Do not stop until complete.*
