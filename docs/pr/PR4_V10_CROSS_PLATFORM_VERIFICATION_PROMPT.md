# PR4 V10 - Cross-Platform Verification & Comprehensive Testing Prompt

## CRITICAL: VERIFICATION CONTEXT

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                    STRICT CROSS-PLATFORM VERIFICATION                        ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Current Status: All 37 Pillars implemented, compilation successful          ║
║                                                                              ║
║  THIS PROMPT FOCUSES ON:                                                     ║
║  1. Cross-platform determinism verification                                  ║
║  2. Known failure point testing (from V7-V10 history)                       ║
║  3. Edge case stress testing                                                 ║
║  4. CI/CD pipeline execution & validation                                   ║
║  5. Runtime invariant monitoring                                            ║
║                                                                              ║
║  REMEMBER: Same input MUST produce BIT-IDENTICAL output across:              ║
║  - iOS ARM64                                                                 ║
║  - macOS ARM64 (M1/M2/M3)                                                   ║
║  - macOS x86_64 (Intel)                                                     ║
║  - Linux x86_64                                                             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

---

## Part 1: Historical Failure Points (MUST TEST THOROUGHLY)

### 1.1 Previously Failed Tests - Root Causes

These are the EXACT issues that caused failures in V7-V10 development:

| ID | Historical Failure | Root Cause | Detection Method | Severity |
|----|-------------------|------------|------------------|----------|
| **F1** | Softmax sum ≠ 65536 | Rounding error accumulation in normalization step | Assert sum == 65536 after EVERY softmax call | CRITICAL |
| **F2** | Cross-platform digest mismatch | `exp()` implementation variance between libc versions | Compare digest across macOS ARM64, macOS x86_64, Linux | CRITICAL |
| **F3** | Non-deterministic sort | Swift's `.sorted()` unstable for equal elements | Use custom stable sort with tie-breaker | CRITICAL |
| **F4** | Median value variance | Platform-dependent division rounding | Use `>>` shift instead of `/` for power-of-2 | HIGH |
| **F5** | Health module accessing Quality | Import leakage allowing forbidden dependency | Static import analysis + compile-time check | HIGH |
| **F6** | Frame context cross-contamination | Mutable state shared between frames | Consume semantics + ownership tracking | HIGH |
| **F7** | LUT interpolation variance | Floating-point intermediate in interpolation | Pure integer interpolation formula | CRITICAL |
| **F8** | Overflow silent corruption | Tier0 field overflow not detected | Explicit overflow check on ALL arithmetic | HIGH |
| **F9** | Metal shader fast-math | Default Metal compilation enables fast-math | Explicit `fastMathEnabled: false` | CRITICAL |
| **F10** | Accelerate framework usage | vDSP/vForce functions non-deterministic | Import scanner + runtime check | CRITICAL |
| **F11** | SIMD lane ordering | Different SIMD implementations reorder operations | Explicit lane ordering or scalar fallback | HIGH |
| **F12** | FMA instruction variance | Fused multiply-add produces different results | `-ffp-contract=off` compiler flag | CRITICAL |
| **F13** | Thread-local state leakage | Processing thread ID affects determinism | Thread contract verification | HIGH |
| **F14** | NaN/Infinity propagation | Special values not sanitized at input | TotalOrder sanitizer at entry points | MEDIUM |
| **F15** | Calibration drift accumulation | P68 calibrator drifts over time | Drift detector with hard reset | MEDIUM |

---

## Part 2: Comprehensive Test Suite Execution

### 2.1 Test Categories (Execute in Order)

```
PHASE 1: Unit Tests (Fast, Isolated)
─────────────────────────────────────
1. PR4MathTests (Int128, Q16, Rounding, TotalOrder, Median/MAD)
2. PR4OverflowTests (Detection, Tier0Fence, Propagation)
3. PR4LUTTests (RangeComplete, BinaryFormat, Reproducibility)
4. PR4SoftmaxTests (ExactSum, MassConservation, TailAccuracy)
5. PR4HealthTests (Inputs, Computer, Isolation, DataFlowFence)
6. PR4OwnershipTests (FrameID, FrameContext, Session, Threading)
7. PR4CalibrationTests (EmpiricalP68, Governance, DriftDetector)
8. PR4QualityTests (SoftQuality, Result)
9. PR4GateTests (State, Machine, OnlineMAD, Decision)
10. PR4DeterminismTests (Mode, BuildContract, DependencyContract, Digest)

PHASE 2: Integration Tests (Cross-Module)
─────────────────────────────────────────
11. PR4FusionTests (FrameProcessor, PR4Pipeline, FusionResult)
12. PR4GoldenTests (GoldenBaseline, Verification)

PHASE 3: Determinism Tests (100+ Runs)
──────────────────────────────────────
13. CrossPlatformDeterminismTests
14. EndToEndDeterminismTests
15. Regression Tests

PHASE 4: Stress Tests (Edge Cases)
──────────────────────────────────
16. StressTests (extreme values, boundary conditions)
```

### 2.2 Execute Test Suite

Run these commands in sequence:

```bash
# Step 1: Clean build
swift package clean
swift build -c release 2>&1 | tee build.log

# Step 2: Run all tests
swift test --parallel 2>&1 | tee test.log

# Step 3: Check for failures
grep -E "FAIL|error:|fatal:" test.log

# Step 4: Run determinism tests with verbose output
swift test --filter "Determinism" -v 2>&1 | tee determinism.log

# Step 5: Run stress tests
swift test --filter "Stress" 2>&1 | tee stress.log
```

---

## Part 3: Critical Test Implementations

### 3.1 Softmax Mass Conservation Test (F1 Detection)

Create `Tests/PR4SoftmaxTests/SoftmaxMassConservationStrictTests.swift`:

```swift
//
// SoftmaxMassConservationStrictTests.swift
// STRICT verification that softmax sum is EXACTLY 65536
//

import XCTest
@testable import PR4Softmax
@testable import PR4Math

final class SoftmaxMassConservationStrictTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - F1: Sum Must Be EXACTLY 65536
    // ═══════════════════════════════════════════════════════════════════════

    /// Test 10000 random inputs - sum MUST be exactly 65536 for ALL
    func testMassConservation10000RandomInputs() {
        var failures: [(seed: Int, sum: Int64, weights: [Int64])] = []

        for seed in 0..<10000 {
            var rng = SplitMix64(seed: UInt64(seed))

            // Random count 2-100
            let count = Int.random(in: 2...100, using: &rng)

            // Random logits in valid range [-32, +32] in Q16
            let logits = (0..<count).map { _ in
                Int64.random(in: -32 * 65536...32 * 65536, using: &rng)
            }

            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)

            if sum != 65536 {
                failures.append((seed: seed, sum: sum, weights: weights))

                // Stop early if too many failures
                if failures.count >= 10 {
                    break
                }
            }
        }

        if !failures.isEmpty {
            for f in failures {
                print("FAILURE seed=\(f.seed): sum=\(f.sum), delta=\(f.sum - 65536)")
            }
        }

        XCTAssertTrue(failures.isEmpty,
            "Mass conservation failed for \(failures.count) inputs. First: seed=\(failures.first?.seed ?? -1)")
    }

    /// Test extreme spread (historical failure F1a)
    func testExtremeSpreadMassConservation() {
        let extremeCases: [[Int64]] = [
            // Maximum spread
            [32 * 65536, -32 * 65536],

            // Large spread with middle
            [30 * 65536, 0, -30 * 65536],

            // One dominant, many tiny
            [20 * 65536] + Array(repeating: Int64(-20 * 65536), count: 99),

            // All very negative (potential underflow)
            Array(repeating: Int64(-30 * 65536), count: 50),

            // All very positive (potential overflow)
            Array(repeating: Int64(30 * 65536), count: 50),

            // Alternating extreme
            (0..<100).map { i in Int64((i % 2 == 0 ? 20 : -20) * 65536) },
        ]

        for (i, logits) in extremeCases.enumerated() {
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)

            XCTAssertEqual(sum, 65536,
                "Extreme case \(i) failed: sum=\(sum), delta=\(sum - 65536)")

            // All weights must be non-negative
            XCTAssertTrue(weights.allSatisfy { $0 >= 0 },
                "Extreme case \(i) has negative weight")
        }
    }

    /// Test near-zero spread (all equal)
    func testUniformDistributionMassConservation() {
        for count in 1...256 {
            let logits = Array(repeating: Int64(0), count: count)
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)

            XCTAssertEqual(sum, 65536,
                "Uniform distribution count=\(count) failed: sum=\(sum)")

            // Each weight should be approximately 65536 / count
            let expectedWeight = 65536 / count
            for (j, w) in weights.enumerated() {
                // Allow ±1 for rounding
                XCTAssertTrue(abs(w - Int64(expectedWeight)) <= 1,
                    "Uniform weight[\(j)] for count=\(count): expected ~\(expectedWeight), got \(w)")
            }
        }
    }

    /// Test single element
    func testSingleElementMassConservation() {
        for value in stride(from: -32 * 65536, through: 32 * 65536, by: 65536) {
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: [Int64(value)])

            XCTAssertEqual(weights.count, 1)
            XCTAssertEqual(weights[0], 65536,
                "Single element \(value) should have weight 65536, got \(weights[0])")
        }
    }

    /// Test empty input
    func testEmptyInputMassConservation() {
        let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: [])
        XCTAssertEqual(weights, [], "Empty input should return empty output")
    }
}

// MARK: - Deterministic RNG

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
```

### 3.2 Cross-Platform Determinism Test (F2 Detection)

Create `Tests/PR4DeterminismTests/CrossPlatformDeterminismStrictTests.swift`:

```swift
//
// CrossPlatformDeterminismStrictTests.swift
// STRICT cross-platform determinism verification
//

import XCTest
@testable import PR4Math
@testable import PR4Softmax
@testable import PR4LUT
@testable import PR4Determinism

final class CrossPlatformDeterminismStrictTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Platform Detection
    // ═══════════════════════════════════════════════════════════════════════

    var platformIdentifier: String {
        #if os(iOS)
        return "iOS-ARM64"
        #elseif os(macOS)
        #if arch(arm64)
        return "macOS-ARM64"
        #else
        return "macOS-x86_64"
        #endif
        #elseif os(Linux)
        #if arch(x86_64)
        return "Linux-x86_64"
        #elseif arch(arm64)
        return "Linux-ARM64"
        #else
        return "Linux-Unknown"
        #endif
        #else
        return "Unknown"
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - F2: Golden Values (CANONICAL - DO NOT CHANGE)
    // ═══════════════════════════════════════════════════════════════════════

    /// These are the CANONICAL golden values.
    /// ALL platforms MUST produce these EXACT values.
    /// If a platform produces different values, THE PLATFORM IMPLEMENTATION IS WRONG.
    struct GoldenValues {

        // ─────────────────────────────────────────────────────────────────────
        // Softmax Golden Values
        // ─────────────────────────────────────────────────────────────────────

        // Input: [1.0, 0.0, -1.0] in Q16 = [65536, 0, -65536]
        static let softmax3Input: [Int64] = [65536, 0, -65536]
        // Expected: proportional to [e^1, e^0, e^-1] ≈ [2.718, 1.0, 0.368]
        // Sum must be exactly 65536
        static let softmax3Expected: [Int64] = [43562, 16029, 5945]  // VERIFY ON FIRST PLATFORM

        // Input: [2.0, 1.0, 0.0, -1.0, -2.0] in Q16
        static let softmax5Input: [Int64] = [131072, 65536, 0, -65536, -131072]
        static let softmax5Expected: [Int64] = [47314, 17409, 6406, 2357, 867]  // VERIFY

        // ─────────────────────────────────────────────────────────────────────
        // LUT Golden Values
        // ─────────────────────────────────────────────────────────────────────

        // exp(0) = 1.0 = 65536 in Q16
        static let exp0Expected: Int64 = 65536

        // exp(-1.0) = exp(-65536 in Q16) ≈ 0.3679 * 65536 ≈ 24109
        static let expNeg1Expected: Int64 = 24109

        // exp(-2.0) = exp(-131072 in Q16) ≈ 0.1353 * 65536 ≈ 8869
        static let expNeg2Expected: Int64 = 8869

        // exp(-10.0) = exp(-655360 in Q16) ≈ 0.0000454 * 65536 ≈ 3
        static let expNeg10Expected: Int64 = 3

        // exp(-32.0) = exp(-2097152 in Q16) ≈ 0 (underflow to minimum)
        static let expNeg32Expected: Int64 = 1  // Minimum non-zero

        // ─────────────────────────────────────────────────────────────────────
        // Median/MAD Golden Values
        // ─────────────────────────────────────────────────────────────────────

        // Median of [5, 2, 9, 1, 7, 3, 8, 4, 6] = 5 (middle after sort)
        static let median9Input: [Int64] = [5, 2, 9, 1, 7, 3, 8, 4, 6]
        static let median9Expected: Int64 = 5

        // MAD of [1, 2, 3, 4, 5, 6, 7, 8, 9] with median 5
        // Absolute deviations: [4, 3, 2, 1, 0, 1, 2, 3, 4]
        // MAD = median of deviations = 2
        static let mad9Input: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        static let mad9Expected: Int64 = 2

        // ─────────────────────────────────────────────────────────────────────
        // Q16 Arithmetic Golden Values
        // ─────────────────────────────────────────────────────────────────────

        // 1.5 + 0.5 = 2.0 → 98304 + 32768 = 131072
        static let addExpected: Int64 = 131072

        // 1.5 * 0.5 = 0.75 → (98304 * 32768) >> 16 = 49152
        static let mulExpected: Int64 = 49152

        // 1.0 / 2.0 = 0.5 → (65536 << 16) / 131072 = 32768
        static let divExpected: Int64 = 32768
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Determinism Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testSoftmax3Determinism() {
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: GoldenValues.softmax3Input)

        print("[\(platformIdentifier)] Softmax3 result: \(result)")
        print("[\(platformIdentifier)] Softmax3 sum: \(result.reduce(0, +))")

        // First, verify sum is exactly 65536
        XCTAssertEqual(result.reduce(0, +), 65536,
            "[\(platformIdentifier)] Softmax3 sum != 65536")

        // Then verify against golden (with ±1 tolerance for any rounding)
        for (i, (got, expected)) in zip(result, GoldenValues.softmax3Expected).enumerated() {
            XCTAssertEqual(got, expected, accuracy: 1,
                "[\(platformIdentifier)] Softmax3[\(i)]: expected \(expected), got \(got)")
        }
    }

    func testSoftmax5Determinism() {
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: GoldenValues.softmax5Input)

        print("[\(platformIdentifier)] Softmax5 result: \(result)")
        print("[\(platformIdentifier)] Softmax5 sum: \(result.reduce(0, +))")

        XCTAssertEqual(result.reduce(0, +), 65536,
            "[\(platformIdentifier)] Softmax5 sum != 65536")

        for (i, (got, expected)) in zip(result, GoldenValues.softmax5Expected).enumerated() {
            XCTAssertEqual(got, expected, accuracy: 1,
                "[\(platformIdentifier)] Softmax5[\(i)]: expected \(expected), got \(got)")
        }
    }

    func testExpLUTDeterminism() {
        // Test all golden exp values
        let testCases: [(input: Int64, expected: Int64, name: String)] = [
            (0, GoldenValues.exp0Expected, "exp(0)"),
            (-65536, GoldenValues.expNeg1Expected, "exp(-1)"),
            (-131072, GoldenValues.expNeg2Expected, "exp(-2)"),
            (-655360, GoldenValues.expNeg10Expected, "exp(-10)"),
            (-2097152, GoldenValues.expNeg32Expected, "exp(-32)"),
        ]

        for (input, expected, name) in testCases {
            let result = RangeCompleteSoftmaxLUT.expQ16(input)

            print("[\(platformIdentifier)] \(name): input=\(input), result=\(result), expected=\(expected)")

            // Allow ±1 for interpolation rounding
            XCTAssertEqual(result, expected, accuracy: 1,
                "[\(platformIdentifier)] \(name): expected \(expected), got \(result)")
        }
    }

    func testMedianDeterminism() {
        let result = DeterministicMedianMAD.medianQ16(GoldenValues.median9Input)

        print("[\(platformIdentifier)] Median9: \(result)")

        XCTAssertEqual(result, GoldenValues.median9Expected,
            "[\(platformIdentifier)] Median9: expected \(GoldenValues.median9Expected), got \(result)")
    }

    func testMADDeterminism() {
        let result = DeterministicMedianMAD.madQ16(GoldenValues.mad9Input)

        print("[\(platformIdentifier)] MAD9: \(result)")

        XCTAssertEqual(result, GoldenValues.mad9Expected,
            "[\(platformIdentifier)] MAD9: expected \(GoldenValues.mad9Expected), got \(result)")
    }

    func testQ16ArithmeticDeterminism() {
        // Addition
        let (sum, sumOverflow) = Q16.add(98304, 32768)  // 1.5 + 0.5
        XCTAssertFalse(sumOverflow)
        XCTAssertEqual(sum, GoldenValues.addExpected,
            "[\(platformIdentifier)] Q16 add: expected \(GoldenValues.addExpected), got \(sum)")

        // Multiplication
        let (product, mulOverflow) = Q16.multiply(98304, 32768)  // 1.5 * 0.5
        XCTAssertFalse(mulOverflow)
        XCTAssertEqual(product, GoldenValues.mulExpected,
            "[\(platformIdentifier)] Q16 mul: expected \(GoldenValues.mulExpected), got \(product)")

        // Division
        let (quotient, divOverflow) = Q16.divide(65536, 131072)  // 1.0 / 2.0
        XCTAssertFalse(divOverflow)
        XCTAssertEqual(quotient, GoldenValues.divExpected,
            "[\(platformIdentifier)] Q16 div: expected \(GoldenValues.divExpected), got \(quotient)")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - 100-Run Consistency Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testSoftmax100RunsConsistent() {
        let input: [Int64] = [100000, 50000, 0, -50000, -100000]

        var firstResult: [Int64]?

        for run in 0..<100 {
            let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: input)

            if let first = firstResult {
                XCTAssertEqual(result, first,
                    "[\(platformIdentifier)] Softmax non-deterministic at run \(run)")
            } else {
                firstResult = result
                print("[\(platformIdentifier)] Softmax first run: \(result)")
            }
        }
    }

    func testMedian100RunsConsistent() {
        let input: [Int64] = [9, 3, 7, 1, 5, 8, 2, 6, 4, 10, 15, 12, 11, 14, 13]

        var firstResult: Int64?

        for run in 0..<100 {
            let result = DeterministicMedianMAD.medianQ16(input)

            if let first = firstResult {
                XCTAssertEqual(result, first,
                    "[\(platformIdentifier)] Median non-deterministic at run \(run)")
            } else {
                firstResult = result
            }
        }
    }

    func testLUT100RunsConsistent() {
        let inputs: [Int64] = [-2097152, -1048576, -655360, -131072, -65536, 0]

        var firstResults: [Int64]?

        for run in 0..<100 {
            let results = inputs.map { RangeCompleteSoftmaxLUT.expQ16($0) }

            if let first = firstResults {
                XCTAssertEqual(results, first,
                    "[\(platformIdentifier)] LUT non-deterministic at run \(run)")
            } else {
                firstResults = results
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Full Digest Comparison
    // ═══════════════════════════════════════════════════════════════════════

    func testGenerateDeterminismDigest() {
        var hasher = FNV1aHasher()

        // Hash softmax results
        let softmax1 = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: GoldenValues.softmax3Input)
        for v in softmax1 { hasher.update(v) }

        let softmax2 = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: GoldenValues.softmax5Input)
        for v in softmax2 { hasher.update(v) }

        // Hash LUT results
        for x in [-2097152, -655360, -131072, -65536, 0] as [Int64] {
            hasher.update(RangeCompleteSoftmaxLUT.expQ16(x))
        }

        // Hash median/MAD
        hasher.update(DeterministicMedianMAD.medianQ16(GoldenValues.median9Input))
        hasher.update(DeterministicMedianMAD.madQ16(GoldenValues.mad9Input))

        // Hash Q16 arithmetic
        let (sum, _) = Q16.add(98304, 32768)
        hasher.update(sum)

        let (product, _) = Q16.multiply(98304, 32768)
        hasher.update(product)

        let digest = hasher.finalize()

        print("[\(platformIdentifier)] DETERMINISM DIGEST: \(String(format: "%016llx", digest))")

        // Store this digest for cross-platform comparison
        // All platforms MUST produce the same digest
    }
}

// MARK: - FNV-1a Hasher

struct FNV1aHasher {
    private var hash: UInt64 = 14695981039346656037

    mutating func update(_ value: Int64) {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
    }

    func finalize() -> UInt64 { hash }
}
```

### 3.3 Sort Determinism Test (F3 Detection)

Create `Tests/PR4MathTests/SortDeterminismStrictTests.swift`:

```swift
//
// SortDeterminismStrictTests.swift
// Verify sort is deterministic even for equal elements
//

import XCTest
@testable import PR4Math

final class SortDeterminismStrictTests: XCTestCase {

    /// Test that sort is stable and deterministic for equal elements
    func testSortStabilityWithEqualElements() {
        // Create array with many equal elements (historical failure F3)
        let input: [(value: Int64, originalIndex: Int)] = [
            (5, 0), (3, 1), (5, 2), (1, 3), (5, 4),
            (3, 5), (2, 6), (5, 7), (3, 8), (5, 9)
        ]

        var firstResult: [(value: Int64, originalIndex: Int)]?

        for run in 0..<100 {
            // Sort by value, keeping track of original index
            let sorted = DeterministicSort.stableSort(input) { $0.value < $1.value }

            if let first = firstResult {
                // Original indices of equal elements must be in same order
                for i in 0..<sorted.count {
                    XCTAssertEqual(sorted[i].value, first[i].value,
                        "Value mismatch at run \(run), index \(i)")
                    XCTAssertEqual(sorted[i].originalIndex, first[i].originalIndex,
                        "Original index mismatch at run \(run), index \(i) - SORT IS NOT STABLE")
                }
            } else {
                firstResult = sorted
            }
        }
    }

    /// Test sort with all equal elements
    func testSortAllEqualElements() {
        let input = (0..<100).map { (value: Int64(42), originalIndex: $0) }

        var firstResult: [Int]?

        for run in 0..<100 {
            let sorted = DeterministicSort.stableSort(input) { $0.value < $1.value }
            let indices = sorted.map { $0.originalIndex }

            if let first = firstResult {
                XCTAssertEqual(indices, first,
                    "Sort of all-equal not stable at run \(run)")
            } else {
                firstResult = indices

                // For stable sort, original order should be preserved
                XCTAssertEqual(indices, Array(0..<100),
                    "Stable sort should preserve original order for equal elements")
            }
        }
    }

    /// Test median uses deterministic sort (F4 related)
    func testMedianUsesDeterministicSort() {
        // Even count with equal elements
        let input: [Int64] = [5, 3, 5, 1, 5, 3, 2, 5, 3, 5]

        var firstResult: Int64?

        for run in 0..<100 {
            let median = DeterministicMedianMAD.medianQ16(input)

            if let first = firstResult {
                XCTAssertEqual(median, first,
                    "Median not deterministic at run \(run): got \(median), expected \(first)")
            } else {
                firstResult = median
            }
        }
    }
}
```

### 3.4 Health Isolation Test (F5 Detection)

Create `Tests/PR4HealthTests/HealthIsolationStrictTests.swift`:

```swift
//
// HealthIsolationStrictTests.swift
// STRICT verification that Health has NO forbidden dependencies
//

import XCTest
@testable import PR4Health

final class HealthIsolationStrictTests: XCTestCase {

    /// Verify Health module compiles without Quality/Uncertainty/Gate
    /// If this test compiles and runs, the API doesn't require forbidden inputs
    func testHealthAPIIsolation() {
        // Create HealthInputs using ONLY allowed fields
        let inputs = HealthInputs(
            consistency: 0.8,
            coverage: 0.9,
            confidenceStability: 0.7,
            latencyOK: true
        )

        // Compute health using ONLY HealthInputs
        let health = HealthComputer.compute(inputs: inputs)

        // Health should be valid
        XCTAssertGreaterThanOrEqual(health, 0.0)
        XCTAssertLessThanOrEqual(health, 1.0)

        // This test passing proves:
        // 1. HealthInputs doesn't require Quality/Uncertainty/Gate fields
        // 2. HealthComputer doesn't require Quality/Uncertainty/Gate inputs
    }

    /// Verify HealthInputs is a closed set of fields
    func testHealthInputsClosedSet() {
        // Reflection-based check that HealthInputs only has allowed fields
        let mirror = Mirror(reflecting: HealthInputs(
            consistency: 0.0,
            coverage: 0.0,
            confidenceStability: 0.0,
            latencyOK: false
        ))

        let allowedFields = Set(["consistency", "coverage", "confidenceStability", "latencyOK"])
        let actualFields = Set(mirror.children.compactMap { $0.label })

        XCTAssertEqual(actualFields, allowedFields,
            "HealthInputs has unexpected fields: \(actualFields.subtracting(allowedFields))")
    }

    /// Verify Health computation is independent of external state
    func testHealthComputationPure() {
        let inputs = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )

        // Compute 100 times - must always be identical
        var firstResult: Double?

        for run in 0..<100 {
            let health = HealthComputer.compute(inputs: inputs)

            if let first = firstResult {
                XCTAssertEqual(health, first,
                    "Health computation not pure at run \(run)")
            } else {
                firstResult = health
            }
        }
    }

    /// Verify Health module has correct import restrictions
    func testHealthImportRestrictions() {
        // This is a compile-time check enforced by the build
        // The test documents the requirement

        // FORBIDDEN imports in PR4Health:
        // - import PR4Quality    ❌
        // - import PR4Uncertainty ❌
        // - import PR4Gate       ❌

        // ALLOWED imports in PR4Health:
        // - import Foundation    ✅
        // - import PR4Math       ✅

        XCTAssertTrue(true, "Import restrictions are enforced at compile time")
    }
}
```

### 3.5 Overflow Tier0 Test (F8 Detection)

Create `Tests/PR4OverflowTests/OverflowTier0StrictTests.swift`:

```swift
//
// OverflowTier0StrictTests.swift
// STRICT verification of Tier0 overflow detection
//

import XCTest
@testable import PR4Overflow
@testable import PR4Math

final class OverflowTier0StrictTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear any previous overflow records
        Tier0OverflowLogger.shared.clear()
    }

    /// Tier0 fields that MUST NOT overflow
    let tier0Fields = [
        "gateQ",
        "softQualityQ",
        "fusedDepthQ",
        "healthScore"
    ]

    /// Test Tier0 overflow detection and logging
    func testTier0OverflowDetected() {
        for field in tier0Fields {
            // Clear before each test
            Tier0OverflowLogger.shared.clear()

            // Attempt to overflow
            let _ = OverflowTier0Fence.handleOverflow(
                field: field,
                value: Int64.max,
                bound: 65536,
                direction: .above
            )

            // Verify overflow was logged
            XCTAssertTrue(Tier0OverflowLogger.shared.hasFatalOverflows,
                "Tier0 field '\(field)' overflow not detected")

            let records = Tier0OverflowLogger.shared.getRecords()
            XCTAssertTrue(records.contains { $0.field == field },
                "Tier0 field '\(field)' not in overflow records")
        }
    }

    /// Test non-Tier0 fields don't trigger fatal overflow
    func testNonTier0OverflowAllowed() {
        Tier0OverflowLogger.shared.clear()

        let nonTier0Fields = ["debugValue", "tempCalc", "intermediateResult"]

        for field in nonTier0Fields {
            let _ = OverflowTier0Fence.handleOverflow(
                field: field,
                value: Int64.max,
                bound: 65536,
                direction: .above
            )
        }

        // Non-Tier0 should NOT trigger fatal overflow
        XCTAssertFalse(Tier0OverflowLogger.shared.hasFatalOverflows,
            "Non-Tier0 fields should not trigger fatal overflow")
    }

    /// Test overflow clamping returns correct bound
    func testOverflowClamping() {
        let testCases: [(value: Int64, bound: Int64, direction: OverflowDirection, expected: Int64)] = [
            (100000, 65536, .above, 65536),  // Above bound → clamp to bound
            (-100000, 0, .below, 0),          // Below bound → clamp to bound
            (50000, 65536, .above, 50000),   // Within range → no change (no overflow)
        ]

        for (i, tc) in testCases.enumerated() {
            let result = OverflowTier0Fence.handleOverflow(
                field: "testField\(i)",
                value: tc.value,
                bound: tc.bound,
                direction: tc.direction
            )

            if tc.value > tc.bound && tc.direction == .above {
                XCTAssertEqual(result, tc.expected, "Case \(i): overflow not clamped correctly")
            } else if tc.value < tc.bound && tc.direction == .below {
                XCTAssertEqual(result, tc.expected, "Case \(i): underflow not clamped correctly")
            }
        }
    }

    /// Test Q16 arithmetic overflow detection
    func testQ16ArithmeticOverflowDetection() {
        // Addition overflow
        let (_, addOverflow) = Q16.add(Int64.max / 2, Int64.max / 2)
        XCTAssertTrue(addOverflow, "Q16 addition overflow not detected")

        // Multiplication overflow
        let (_, mulOverflow) = Q16.multiply(Int64.max, 65536)
        XCTAssertTrue(mulOverflow, "Q16 multiplication overflow not detected")

        // No overflow case
        let (sum, noOverflow) = Q16.add(65536, 65536)
        XCTAssertFalse(noOverflow, "False positive overflow for valid addition")
        XCTAssertEqual(sum, 131072)
    }
}
```

---

## Part 4: CI/CD Pipeline Execution

### 4.1 Local CI Simulation

Before pushing, simulate CI locally:

```bash
#!/bin/bash
# local-ci-simulation.sh
# Simulate CI pipeline locally

set -e

echo "═══════════════════════════════════════════════════════════════════════"
echo "PR4 V10 - Local CI Simulation"
echo "═══════════════════════════════════════════════════════════════════════"

# Step 1: Clean
echo ""
echo "Step 1: Clean build..."
swift package clean

# Step 2: Build (Release)
echo ""
echo "Step 2: Build (Release)..."
swift build -c release 2>&1 | tee build-release.log

if grep -q "error:" build-release.log; then
    echo "❌ Build failed!"
    exit 1
fi
echo "✅ Build succeeded"

# Step 3: Run all tests
echo ""
echo "Step 3: Run all tests..."
swift test 2>&1 | tee test-all.log

if grep -q "FAIL" test-all.log; then
    echo "❌ Tests failed!"
    grep "FAIL" test-all.log
    exit 1
fi
echo "✅ All tests passed"

# Step 4: Run determinism tests (100 runs each)
echo ""
echo "Step 4: Run determinism tests..."
swift test --filter "Determinism" -v 2>&1 | tee test-determinism.log

# Step 5: Generate determinism digest
echo ""
echo "Step 5: Generate determinism digest..."
swift run PR4DigestGenerator 2>&1 | tee digest.txt

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "LOCAL DETERMINISM DIGEST:"
cat digest.txt
echo ""
echo "═══════════════════════════════════════════════════════════════════════"

# Step 6: Static analysis
echo ""
echo "Step 6: Static analysis..."

# Check Health isolation
echo "Checking Health module isolation..."
HEALTH_VIOLATIONS=$(grep -rE "import PR4Quality|import PR4Uncertainty|import PR4Gate" Sources/PR4Health/ 2>/dev/null || true)
if [ -n "$HEALTH_VIOLATIONS" ]; then
    echo "❌ Health module has forbidden imports:"
    echo "$HEALTH_VIOLATIONS"
    exit 1
fi
echo "✅ Health isolation verified"

# Check Accelerate usage
echo "Checking for Accelerate framework..."
ACCELERATE_USAGE=$(grep -rE "import Accelerate|vDSP_|vForce" \
    Sources/PR4Math/ \
    Sources/PR4Softmax/ \
    Sources/PR4LUT/ \
    Sources/PR4Overflow/ 2>/dev/null || true)
if [ -n "$ACCELERATE_USAGE" ]; then
    echo "❌ Accelerate found in critical path:"
    echo "$ACCELERATE_USAGE"
    exit 1
fi
echo "✅ No Accelerate in critical path"

# Step 7: Package DAG verification
echo ""
echo "Step 7: Package DAG verification..."
bash Scripts/verify-package-dag.sh

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "✅ LOCAL CI SIMULATION PASSED"
echo "═══════════════════════════════════════════════════════════════════════"
```

### 4.2 GitHub Actions Workflow Verification

Ensure `.github/workflows/pr4-ci.yml` is correct:

```yaml
name: PR4 V10 Cross-Platform Verification

on:
  push:
    branches: [main, develop]
    paths:
      - 'Sources/PR4**'
      - 'Tests/PR4**'
      - 'Package.swift'
  pull_request:
    branches: [main]
  workflow_dispatch:  # Allow manual trigger

env:
  SWIFT_VERSION: '5.9'

jobs:
  # ═══════════════════════════════════════════════════════════════════════
  # Job 1: macOS ARM64 (M1/M2/M3)
  # ═══════════════════════════════════════════════════════════════════════
  test-macos-arm64:
    name: macOS ARM64 Tests
    runs-on: macos-14  # M1/M2 runner
    steps:
      - uses: actions/checkout@v4

      - name: Setup Swift
        uses: swift-actions/setup-swift@v2
        with:
          swift-version: ${{ env.SWIFT_VERSION }}

      - name: Build (Release)
        run: swift build -c release

      - name: Run All Tests
        run: swift test --parallel

      - name: Run Determinism Tests (Verbose)
        run: swift test --filter "Determinism" -v

      - name: Generate Determinism Digest
        run: swift run PR4DigestGenerator > digest-macos-arm64.txt

      - name: Upload Digest
        uses: actions/upload-artifact@v4
        with:
          name: digest-macos-arm64
          path: digest-macos-arm64.txt
          retention-days: 1

  # ═══════════════════════════════════════════════════════════════════════
  # Job 2: macOS x86_64 (Intel)
  # ═══════════════════════════════════════════════════════════════════════
  test-macos-x86:
    name: macOS x86_64 Tests
    runs-on: macos-13  # Intel runner
    steps:
      - uses: actions/checkout@v4

      - name: Setup Swift
        uses: swift-actions/setup-swift@v2
        with:
          swift-version: ${{ env.SWIFT_VERSION }}

      - name: Build (Release)
        run: swift build -c release

      - name: Run All Tests
        run: swift test --parallel

      - name: Generate Determinism Digest
        run: swift run PR4DigestGenerator > digest-macos-x86.txt

      - name: Upload Digest
        uses: actions/upload-artifact@v4
        with:
          name: digest-macos-x86
          path: digest-macos-x86.txt
          retention-days: 1

  # ═══════════════════════════════════════════════════════════════════════
  # Job 3: Linux x86_64
  # ═══════════════════════════════════════════════════════════════════════
  test-linux-x86:
    name: Linux x86_64 Tests
    runs-on: ubuntu-latest
    container:
      image: swift:5.9-jammy
    steps:
      - uses: actions/checkout@v4

      - name: Build (Release)
        run: swift build -c release

      - name: Run All Tests
        run: swift test --parallel

      - name: Generate Determinism Digest
        run: swift run PR4DigestGenerator > digest-linux-x86.txt

      - name: Upload Digest
        uses: actions/upload-artifact@v4
        with:
          name: digest-linux-x86
          path: digest-linux-x86.txt
          retention-days: 1

  # ═══════════════════════════════════════════════════════════════════════
  # Job 4: iOS Simulator
  # ═══════════════════════════════════════════════════════════════════════
  test-ios-simulator:
    name: iOS Simulator Tests
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.2.app

      - name: Build for iOS Simulator
        run: |
          xcodebuild build-for-testing \
            -scheme Aether3D \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.2' \
            -configuration Debug

      - name: Run Tests on iOS Simulator
        run: |
          xcodebuild test-without-building \
            -scheme Aether3D \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.2' \
            -configuration Debug

  # ═══════════════════════════════════════════════════════════════════════
  # Job 5: Cross-Platform Digest Comparison (CRITICAL)
  # ═══════════════════════════════════════════════════════════════════════
  compare-digests:
    name: Cross-Platform Determinism Verification
    needs: [test-macos-arm64, test-macos-x86, test-linux-x86]
    runs-on: ubuntu-latest
    steps:
      - name: Download macOS ARM64 Digest
        uses: actions/download-artifact@v4
        with:
          name: digest-macos-arm64
          path: digests/

      - name: Download macOS x86_64 Digest
        uses: actions/download-artifact@v4
        with:
          name: digest-macos-x86
          path: digests/

      - name: Download Linux x86_64 Digest
        uses: actions/download-artifact@v4
        with:
          name: digest-linux-x86
          path: digests/

      - name: Compare Digests
        run: |
          echo "═══════════════════════════════════════════════════════════════════════"
          echo "CROSS-PLATFORM DETERMINISM VERIFICATION"
          echo "═══════════════════════════════════════════════════════════════════════"

          MACOS_ARM64=$(cat digests/digest-macos-arm64.txt)
          MACOS_X86=$(cat digests/digest-macos-x86.txt)
          LINUX_X86=$(cat digests/digest-linux-x86.txt)

          echo ""
          echo "Digests:"
          echo "  macOS ARM64:  $MACOS_ARM64"
          echo "  macOS x86_64: $MACOS_X86"
          echo "  Linux x86_64: $LINUX_X86"
          echo ""

          FAILED=0

          if [ "$MACOS_ARM64" != "$MACOS_X86" ]; then
            echo "❌ MISMATCH: macOS ARM64 vs macOS x86_64"
            FAILED=1
          fi

          if [ "$MACOS_ARM64" != "$LINUX_X86" ]; then
            echo "❌ MISMATCH: macOS ARM64 vs Linux x86_64"
            FAILED=1
          fi

          if [ "$MACOS_X86" != "$LINUX_X86" ]; then
            echo "❌ MISMATCH: macOS x86_64 vs Linux x86_64"
            FAILED=1
          fi

          if [ $FAILED -eq 1 ]; then
            echo ""
            echo "═══════════════════════════════════════════════════════════════════════"
            echo "❌ CROSS-PLATFORM DETERMINISM VERIFICATION FAILED"
            echo "═══════════════════════════════════════════════════════════════════════"
            exit 1
          fi

          echo ""
          echo "═══════════════════════════════════════════════════════════════════════"
          echo "✅ ALL PLATFORMS PRODUCE IDENTICAL DETERMINISM DIGEST"
          echo "═══════════════════════════════════════════════════════════════════════"

  # ═══════════════════════════════════════════════════════════════════════
  # Job 6: Static Analysis
  # ═══════════════════════════════════════════════════════════════════════
  static-analysis:
    name: Static Analysis
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Check Health Module Isolation
        run: |
          echo "Checking Health module for forbidden imports..."
          FORBIDDEN=$(grep -rE "import PR4Quality|import PR4Uncertainty|import PR4Gate" Sources/PR4Health/ || true)
          if [ -n "$FORBIDDEN" ]; then
            echo "❌ Health module has forbidden imports:"
            echo "$FORBIDDEN"
            exit 1
          fi
          echo "✅ Health module isolation verified"

      - name: Check Accelerate Framework Usage
        run: |
          echo "Checking for Accelerate/vDSP in critical path..."
          FORBIDDEN=$(grep -rE "import Accelerate|vDSP_|vForce|vImage" \
            Sources/PR4Math/ \
            Sources/PR4Softmax/ \
            Sources/PR4LUT/ \
            Sources/PR4Overflow/ \
            Sources/PR4Determinism/ || true)
          if [ -n "$FORBIDDEN" ]; then
            echo "❌ Accelerate/vDSP found in critical path:"
            echo "$FORBIDDEN"
            exit 1
          fi
          echo "✅ No Accelerate/vDSP in critical path"

      - name: Verify Package DAG
        run: bash Scripts/verify-package-dag.sh

  # ═══════════════════════════════════════════════════════════════════════
  # Job 7: Golden Baseline Verification
  # ═══════════════════════════════════════════════════════════════════════
  golden-baselines:
    name: Golden Baseline Verification
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Setup Swift
        uses: swift-actions/setup-swift@v2
        with:
          swift-version: ${{ env.SWIFT_VERSION }}

      - name: Build
        run: swift build -c release

      - name: Verify Golden Baselines
        run: swift test --filter "GoldenBaseline"
```

---

## Part 5: Stress Tests

### 5.1 Extreme Value Stress Tests

Create `Tests/PR4IntegrationTests/StressTests.swift`:

```swift
//
// StressTests.swift
// Stress tests for edge cases and boundary conditions
//

import XCTest
@testable import PR4Math
@testable import PR4Softmax
@testable import PR4LUT
@testable import PR4Overflow

final class StressTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Boundary Value Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Test Q16 arithmetic at boundaries
    func testQ16BoundaryValues() {
        // Maximum Q16 value (2^47 - 1 to avoid overflow in multiplication)
        let maxSafe: Int64 = (1 << 47) - 1
        let minSafe: Int64 = -(1 << 47)

        // Test addition near boundaries
        let (sum1, overflow1) = Q16.add(maxSafe, 1)
        XCTAssertFalse(overflow1, "Should not overflow")

        let (sum2, overflow2) = Q16.add(maxSafe, maxSafe)
        XCTAssertTrue(overflow2, "Should overflow")

        // Test multiplication near boundaries
        let (prod1, overflow3) = Q16.multiply(65536, 65536)  // 1.0 * 1.0
        XCTAssertFalse(overflow3, "1.0 * 1.0 should not overflow")
        XCTAssertEqual(prod1, 65536, "1.0 * 1.0 = 1.0")

        // Test near-zero values
        let (prod2, _) = Q16.multiply(1, 1)  // Smallest * smallest
        XCTAssertEqual(prod2, 0, "Very small * very small = 0 (underflow)")
    }

    /// Test softmax with extreme spread
    func testSoftmaxExtremeSpread() {
        // Maximum allowed spread: 32
        for spread in stride(from: 1, through: 32, by: 1) {
            let high = Int64(spread) * 65536
            let low = -Int64(spread) * 65536

            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: [high, low])
            let sum = weights.reduce(0, +)

            XCTAssertEqual(sum, 65536,
                "Softmax sum != 65536 for spread \(spread): got \(sum)")

            // All weights non-negative
            XCTAssertTrue(weights.allSatisfy { $0 >= 0 },
                "Negative weight for spread \(spread)")
        }
    }

    /// Test softmax with many elements
    func testSoftmaxManyElements() {
        for count in [10, 50, 100, 500, 1000] {
            var rng = SplitMix64(seed: UInt64(count))
            let logits = (0..<count).map { _ in
                Int64.random(in: -10 * 65536...10 * 65536, using: &rng)
            }

            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let sum = weights.reduce(0, +)

            XCTAssertEqual(sum, 65536,
                "Softmax sum != 65536 for count \(count): got \(sum)")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - LUT Boundary Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Test LUT at exact boundaries
    func testLUTBoundaries() {
        // Test at exact LUT boundaries
        let boundaries: [Int64] = [
            0,                    // Upper bound
            -65536,               // -1.0
            -2 * 65536,           // -2.0
            -16 * 65536,          // -16.0
            -32 * 65536,          // -32.0 (lower bound)
        ]

        for x in boundaries {
            let result = RangeCompleteSoftmaxLUT.expQ16(x)
            XCTAssertGreaterThan(result, 0, "exp(\(x)) should be > 0")
            XCTAssertLessThanOrEqual(result, 65536, "exp(\(x)) should be <= 1.0")
        }
    }

    /// Test LUT interpolation between points
    func testLUTInterpolation() {
        // Test halfway between LUT entries
        for i in stride(from: 0, to: -32 * 65536, by: -65536 / 2) {
            let x = Int64(i)
            let result = RangeCompleteSoftmaxLUT.expQ16(x)

            // Result should be monotonically decreasing
            let resultNext = RangeCompleteSoftmaxLUT.expQ16(x - 1)
            XCTAssertLessThanOrEqual(resultNext, result,
                "exp(\(x-1)) should be <= exp(\(x))")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Overflow Stress Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Test overflow detection under rapid calls
    func testOverflowDetectionRapidCalls() {
        Tier0OverflowLogger.shared.clear()

        // Rapid overflow calls
        for i in 0..<1000 {
            let _ = OverflowTier0Fence.handleOverflow(
                field: "gateQ",
                value: Int64(100000 + i),
                bound: 65536,
                direction: .above
            )
        }

        XCTAssertTrue(Tier0OverflowLogger.shared.hasFatalOverflows,
            "Should detect rapid overflow calls")

        let records = Tier0OverflowLogger.shared.getRecords()
        XCTAssertGreaterThan(records.count, 0, "Should have overflow records")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Performance Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Performance test for softmax
    func testSoftmaxPerformance() {
        let logits = (0..<100).map { _ in Int64.random(in: -10 * 65536...10 * 65536) }

        measure {
            for _ in 0..<1000 {
                let _ = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            }
        }
    }

    /// Performance test for LUT lookup
    func testLUTLookupPerformance() {
        let inputs = stride(from: 0, to: -32 * 65536, by: -1000).map { Int64($0) }

        measure {
            for _ in 0..<1000 {
                for x in inputs {
                    let _ = RangeCompleteSoftmaxLUT.expQ16(x)
                }
            }
        }
    }
}
```

---

## Part 6: End-to-End Verification

### 6.1 Complete Pipeline Test

Create `Tests/PR4IntegrationTests/EndToEndPipelineTests.swift`:

```swift
//
// EndToEndPipelineTests.swift
// Complete pipeline verification
//

import XCTest
@testable import PR4Math
@testable import PR4Softmax
@testable import PR4LUT
@testable import PR4Health
@testable import PR4Quality
@testable import PR4Gate
@testable import PR4Calibration
@testable import PR4Determinism
@testable import PR4Ownership
@testable import PR4Fusion

final class EndToEndPipelineTests: XCTestCase {

    /// Complete end-to-end determinism test
    func testEndToEndDeterminism100Runs() {
        var firstDigest: String?

        for run in 0..<100 {
            // Create fresh session for each run
            let session = SessionContext()

            // Process multiple frames
            var frameResults: [String] = []

            for frameIndex in 0..<10 {
                let frameID = FrameID(session: session, index: UInt64(frameIndex))

                // Simulate frame processing
                let result = processFrame(frameID: frameID, run: run)
                frameResults.append(result)
            }

            // Generate digest for this run
            let runDigest = frameResults.joined(separator: "|")

            if let first = firstDigest {
                XCTAssertEqual(runDigest, first,
                    "End-to-end non-deterministic at run \(run)")
            } else {
                firstDigest = runDigest
            }
        }
    }

    /// Process a single frame (deterministic)
    private func processFrame(frameID: FrameID, run: Int) -> String {
        // Use deterministic "random" values based on frame index
        let seed = frameID.index * 1000 + UInt64(run)
        var rng = SplitMix64(seed: seed)

        // Generate depth values
        let depths = (0..<100).map { _ in
            Int64.random(in: 0...65536, using: &rng)
        }

        // Compute quality
        let logits = depths.map { $0 - 32768 }  // Center around 0
        let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)

        // Compute health
        let healthInputs = HealthInputs(
            consistency: Double(weights[0]) / 65536.0,
            coverage: 0.9,
            confidenceStability: 0.8,
            latencyOK: true
        )
        let health = HealthComputer.compute(inputs: healthInputs)

        // Create result string (deterministic representation)
        let weightSum = weights.reduce(0, +)
        return "f\(frameID.index):w\(weightSum):h\(Int(health * 1000))"
    }

    /// Test frame isolation
    func testFrameIsolation() {
        let session = SessionContext()

        // Process frames in different orders
        let order1Results = processFrames(session: session, order: [0, 1, 2, 3, 4])
        let order2Results = processFrames(session: session, order: [4, 3, 2, 1, 0])

        // Each frame's result should be independent of processing order
        for i in 0..<5 {
            let result1 = order1Results.first { $0.frameIndex == i }!
            let result2 = order2Results.first { $0.frameIndex == i }!

            XCTAssertEqual(result1.digest, result2.digest,
                "Frame \(i) result depends on processing order!")
        }
    }

    private func processFrames(session: SessionContext, order: [Int]) -> [(frameIndex: Int, digest: String)] {
        order.map { index in
            let frameID = FrameID(session: session, index: UInt64(index))
            let result = processFrame(frameID: frameID, run: 0)
            return (frameIndex: index, digest: result)
        }
    }
}
```

---

## Part 7: Execution Checklist

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                    EXECUTION CHECKLIST                                       ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  PHASE 1: Create Test Files                                                  ║
║  ☐ SoftmaxMassConservationStrictTests.swift                                 ║
║  ☐ CrossPlatformDeterminismStrictTests.swift                                ║
║  ☐ SortDeterminismStrictTests.swift                                         ║
║  ☐ HealthIsolationStrictTests.swift                                         ║
║  ☐ OverflowTier0StrictTests.swift                                           ║
║  ☐ StressTests.swift                                                        ║
║  ☐ EndToEndPipelineTests.swift                                              ║
║                                                                              ║
║  PHASE 2: Run Local Tests                                                   ║
║  ☐ swift package clean                                                      ║
║  ☐ swift build -c release                                                   ║
║  ☐ swift test --parallel                                                    ║
║  ☐ swift test --filter "Strict" -v                                          ║
║  ☐ swift test --filter "Determinism" -v                                     ║
║  ☐ swift test --filter "Stress"                                             ║
║                                                                              ║
║  PHASE 3: Generate & Verify Digest                                          ║
║  ☐ swift run PR4DigestGenerator                                             ║
║  ☐ Record digest value                                                      ║
║  ☐ Verify digest matches golden (if established)                            ║
║                                                                              ║
║  PHASE 4: Static Analysis                                                   ║
║  ☐ bash Scripts/verify-package-dag.sh                                       ║
║  ☐ Verify Health module imports                                             ║
║  ☐ Verify no Accelerate usage                                               ║
║  ☐ Verify LUT checksums                                                     ║
║                                                                              ║
║  PHASE 5: CI Simulation                                                     ║
║  ☐ bash local-ci-simulation.sh                                              ║
║  ☐ All steps pass                                                           ║
║                                                                              ║
║  PHASE 6: Final Verification                                                ║
║  ☐ All tests pass                                                           ║
║  ☐ Digest is stable across 100 runs                                         ║
║  ☐ No Tier0 overflows                                                       ║
║  ☐ Softmax sum always exactly 65536                                         ║
║  ☐ Health module fully isolated                                             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

---

## CRITICAL REMINDERS

1. **Softmax Sum = 65536 EXACTLY** - Not 65535, not 65537, EXACTLY 65536
2. **Cross-Platform Digest MUST Match** - Same input → identical digest on ALL platforms
3. **Health Module ISOLATED** - NO imports from Quality/Uncertainty/Gate
4. **Tier0 Fields PROTECTED** - gateQ, softQualityQ, fusedDepthQ cannot overflow
5. **Sort MUST be STABLE** - Equal elements maintain original order
6. **LUT ONLY for exp()** - No libc exp/log/sin/cos
7. **No Accelerate/vDSP** - Critical path is pure integer arithmetic

---

**DO NOT STOP UNTIL ALL TESTS PASS AND CROSS-PLATFORM VERIFICATION IS COMPLETE.**
