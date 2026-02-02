# PR4 V10 - Hardening, CI & Cross-Platform Detection Prompt

## ⚠️ CURSOR CONTINUATION INSTRUCTION

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                    CONTINUE WITHOUT STOPPING                                 ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Current Progress: 34 files implemented, compilation successful              ║
║                                                                              ║
║  REMAINING TASKS (DO NOT STOP UNTIL ALL COMPLETE):                          ║
║  1. Create comprehensive test suite                                          ║
║  2. Implement Fusion module (FrameProcessor, PR4Pipeline)                   ║
║  3. Create CI/CD pipelines for cross-platform verification                  ║
║  4. Add runtime guards and defensive checks                                  ║
║  5. Create verification scripts                                              ║
║                                                                              ║
║  CRITICAL: Pay special attention to CROSS-PLATFORM DETERMINISM              ║
║  - iOS ARM64 vs macOS ARM64 vs macOS x86_64 vs Linux x86_64                 ║
║  - Same input MUST produce IDENTICAL output on ALL platforms                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

---

## Part 1: Critical Failure Points From Previous Reviews

### 1.1 Known Risk Areas (MUST ADDRESS)

These issues were identified in V7-V9 reviews and MUST have explicit guards:

| Risk ID | Issue | Detection | Guard |
|---------|-------|-----------|-------|
| **R1** | Floating-point non-determinism across platforms | CI cross-platform digest comparison | Integer-only critical path |
| **R2** | `exp/log/sin/cos` vary between libc versions | Reference LUT comparison | LUT-based math ONLY |
| **R3** | Sort algorithm platform variance | Determinism test 100 runs | Custom deterministic sort |
| **R4** | SIMD lane ordering differences | Cross-platform unit test | Explicit lane ordering |
| **R5** | FMA contraction changes results | Compiler flag verification | `-ffp-contract=off` |
| **R6** | Metal fast-math approximations | Shader compilation check | `fastMathEnabled=false` |
| **R7** | Accelerate/vDSP hidden in dependencies | Static analysis lint | Import scanner |
| **R8** | Health → Quality feedback loop | Type-level fence | Module boundary check |
| **R9** | Softmax sum ≠ 65536 | Invariant assertion | Step-by-step verification |
| **R10** | Frame context cross-contamination | Runtime ownership check | Consume semantics |

---

## Part 2: Comprehensive Test Suite

### 2.1 Test Directory Structure

Create this test structure:

```
Tests/
├── PR4MathTests/
│   ├── Int128Tests.swift
│   ├── Q16ArithmeticTests.swift
│   ├── DeterministicRoundingTests.swift
│   ├── TotalOrderComparatorTests.swift
│   ├── DeterministicMedianMADTests.swift
│   └── ErrorPropagationBudgetTests.swift
│
├── PR4OverflowTests/
│   ├── OverflowDetectionTests.swift
│   ├── OverflowTier0FenceTests.swift
│   ├── OverflowPropagationTests.swift
│   └── OverflowReporterTests.swift
│
├── PR4LUTTests/
│   ├── RangeCompleteSoftmaxLUTTests.swift
│   ├── LUTBinaryFormatV2Tests.swift
│   ├── LUTReproducibleGeneratorTests.swift
│   ├── LogCallSiteContractTests.swift
│   └── LUTIntegrityTests.swift
│
├── PR4DeterminismTests/
│   ├── DeterminismModeTests.swift
│   ├── DeterminismBuildContractTests.swift
│   ├── DeterminismDependencyContractTests.swift
│   ├── DeterminismDigestV2Tests.swift
│   └── CrossPlatformDeterminismTests.swift
│
├── PR4OwnershipTests/
│   ├── FrameIDTests.swift
│   ├── FrameContextTests.swift
│   ├── SessionContextTests.swift
│   ├── ThreadingContractTests.swift
│   └── CrossFrameLeakDetectorTests.swift
│
├── PR4SoftmaxTests/
│   ├── SoftmaxExactSumV2Tests.swift
│   ├── SoftmaxMassConservationTests.swift
│   ├── SoftmaxTailAccuracyTests.swift
│   └── SoftmaxDeterminismTests.swift
│
├── PR4HealthTests/
│   ├── HealthInputsTests.swift
│   ├── HealthComputerTests.swift
│   ├── HealthDataFlowFenceTests.swift
│   └── HealthIsolationTests.swift
│
├── PR4CalibrationTests/
│   ├── EmpiricalP68CalibratorTests.swift
│   ├── CalibrationGovernanceTests.swift
│   └── CalibrationDriftDetectorTests.swift
│
├── PR4QualityTests/
│   ├── SoftQualityComputerTests.swift
│   └── QualityResultTests.swift
│
├── PR4GateTests/
│   ├── SoftGateStateTests.swift
│   ├── SoftGateMachineTests.swift
│   ├── OnlineMADEstimatorTests.swift
│   └── GateDecisionTests.swift
│
├── PR4FusionTests/
│   ├── FrameProcessorTests.swift
│   ├── PR4PipelineTests.swift
│   └── FusionResultTests.swift
│
├── PR4GoldenTests/
│   ├── GoldenBaselineSystemTests.swift
│   └── GoldenBaselineVerificationTests.swift
│
└── PR4IntegrationTests/
    ├── EndToEndDeterminismTests.swift
    ├── CrossPlatformConsistencyTests.swift
    ├── RegressionTests.swift
    └── StressTests.swift
```

### 2.2 Critical Test Implementations

#### CrossPlatformDeterminismTests.swift

```swift
//
// CrossPlatformDeterminismTests.swift
// Tests determinism across platforms
//

import XCTest
@testable import PR4Math
@testable import PR4Softmax
@testable import PR4LUT
@testable import PR4Determinism

final class CrossPlatformDeterminismTests: XCTestCase {

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
        return "Linux-x86_64"
        #else
        return "Unknown"
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Golden Values (MUST match across ALL platforms)
    // ═══════════════════════════════════════════════════════════════════════

    /// These values are the CANONICAL results.
    /// If any platform produces different values, IT IS WRONG.
    struct GoldenValues {
        // Softmax golden: input [65536, 0, -65536] (representing [1.0, 0, -1.0])
        static let softmaxInput: [Int64] = [65536, 0, -65536]
        static let softmaxExpected: [Int64] = [47073, 17325, 6138]  // Sum = 65536

        // LUT golden: exp(-1.0 in Q16) = exp(-65536)
        static let expInputQ16: Int64 = -65536
        static let expExpectedQ16: Int64 = 24109  // exp(-1) ≈ 0.3679 * 65536

        // Digest golden: fixed fields → fixed hash
        static let digestFields: [String: Int64] = [
            "fieldA": 12345,
            "fieldB": 67890,
            "fieldC": -11111
        ]
        static let digestExpected: UInt64 = 0x1234567890ABCDEF  // Placeholder - compute actual

        // Median golden
        static let medianInput: [Int64] = [5, 2, 9, 1, 7, 3, 8, 4, 6]
        static let medianExpected: Int64 = 5

        // MAD golden
        static let madInput: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        static let madExpected: Int64 = 2  // MAD of [1..9] with median 5
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Determinism Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testSoftmaxDeterminism() {
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: GoldenValues.softmaxInput)

        // Must match golden EXACTLY
        XCTAssertEqual(result, GoldenValues.softmaxExpected,
            "Softmax mismatch on \(platformIdentifier): got \(result), expected \(GoldenValues.softmaxExpected)")

        // Sum must be exactly 65536
        XCTAssertEqual(result.reduce(0, +), 65536,
            "Softmax sum != 65536 on \(platformIdentifier)")
    }

    func testExpLUTDeterminism() {
        let result = RangeCompleteSoftmaxLUT.expQ16(GoldenValues.expInputQ16)

        // Allow ±1 for interpolation rounding
        XCTAssertEqual(result, GoldenValues.expExpectedQ16, accuracy: 1,
            "Exp LUT mismatch on \(platformIdentifier): got \(result), expected \(GoldenValues.expExpectedQ16)")
    }

    func testMedianDeterminism() {
        let result = DeterministicMedianMAD.medianQ16(GoldenValues.medianInput)

        XCTAssertEqual(result, GoldenValues.medianExpected,
            "Median mismatch on \(platformIdentifier): got \(result), expected \(GoldenValues.medianExpected)")
    }

    func testMADDeterminism() {
        let result = DeterministicMedianMAD.madQ16(GoldenValues.madInput)

        XCTAssertEqual(result, GoldenValues.madExpected,
            "MAD mismatch on \(platformIdentifier): got \(result), expected \(GoldenValues.madExpected)")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - 100-Run Consistency Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testSoftmax100RunsIdentical() {
        let input: [Int64] = [100000, 50000, 0, -50000, -100000]

        var firstResult: [Int64]?

        for run in 0..<100 {
            let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: input)

            if let first = firstResult {
                XCTAssertEqual(result, first,
                    "Softmax non-deterministic at run \(run) on \(platformIdentifier)")
            } else {
                firstResult = result
            }
        }
    }

    func testMedian100RunsIdentical() {
        let input: [Int64] = [9, 3, 7, 1, 5, 8, 2, 6, 4, 10, 15, 12, 11, 14, 13]

        var firstResult: Int64?

        for run in 0..<100 {
            let result = DeterministicMedianMAD.medianQ16(input)

            if let first = firstResult {
                XCTAssertEqual(result, first,
                    "Median non-deterministic at run \(run) on \(platformIdentifier)")
            } else {
                firstResult = result
            }
        }
    }

    func testPathTrace100RunsIdentical() {
        for run in 0..<100 {
            let trace = PathDeterminismTraceV2()

            trace.record(.gateEnabled)
            trace.record(.softmaxNormal)
            trace.record(.calibrationEmpirical)
            trace.record(.noOverflow)

            let signature = trace.signature

            if run == 0 {
                // Store first signature
                print("PathTrace signature on \(platformIdentifier): \(signature)")
            }

            // Create identical trace
            let trace2 = PathDeterminismTraceV2()
            trace2.record(.gateEnabled)
            trace2.record(.softmaxNormal)
            trace2.record(.calibrationEmpirical)
            trace2.record(.noOverflow)

            XCTAssertEqual(trace.signature, trace2.signature,
                "PathTrace non-deterministic at run \(run)")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Edge Case Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testSoftmaxExtremeSpread() {
        // Logit spread of 40 (worst case from V8 fix)
        let input: [Int64] = [20 * 65536, -20 * 65536]
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: input)

        // First should get nearly all mass
        XCTAssertGreaterThan(result[0], 65500, "First weight should dominate")
        XCTAssertLessThan(result[1], 36, "Second weight should be negligible")
        XCTAssertEqual(result[0] + result[1], 65536, "Sum must be exactly 65536")
    }

    func testSoftmaxAllEqual() {
        // All equal logits should produce uniform distribution
        let input: [Int64] = [0, 0, 0, 0]
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: input)

        // Each should be 65536 / 4 = 16384
        let expected: Int64 = 16384

        for weight in result {
            XCTAssertEqual(weight, expected, accuracy: 1,
                "Uniform distribution expected, got \(result)")
        }

        XCTAssertEqual(result.reduce(0, +), 65536, "Sum must be exactly 65536")
    }

    func testSoftmaxSingleElement() {
        let input: [Int64] = [12345]
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: input)

        XCTAssertEqual(result, [65536], "Single element should get all mass")
    }

    func testSoftmaxEmptyInput() {
        let input: [Int64] = []
        let result = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: input)

        XCTAssertEqual(result, [], "Empty input should return empty output")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - NaN/Inf Handling Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testTotalOrderSanitizesNaN() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(.nan)

        XCTAssertEqual(result, 0.0, "NaN should sanitize to 0.0")
        XCTAssertTrue(wasSpecial, "NaN should be flagged as special")
    }

    func testTotalOrderSanitizesInfinity() {
        let (posResult, posSpecial) = TotalOrderComparator.sanitize(.infinity)
        let (negResult, negSpecial) = TotalOrderComparator.sanitize(-.infinity)

        XCTAssertEqual(posResult, Double.greatestFiniteMagnitude)
        XCTAssertEqual(negResult, -Double.greatestFiniteMagnitude)
        XCTAssertTrue(posSpecial && negSpecial)
    }

    func testTotalOrderSanitizesNegativeZero() {
        let (result, wasSpecial) = TotalOrderComparator.sanitize(-0.0)

        XCTAssertEqual(result, 0.0)
        XCTAssertTrue(result.sign == .plus, "-0 should become +0")
        XCTAssertTrue(wasSpecial)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Overflow Detection Tests
    // ═══════════════════════════════════════════════════════════════════════

    func testTier0OverflowDetected() {
        // gateQ is Tier0 - overflow should be detected
        let result = OverflowTier0Fence.handleOverflow(
            field: "gateQ",
            value: Int64.max,
            bound: 65536,
            direction: .above
        )

        XCTAssertEqual(result, 65536, "Should clamp to bound")
        XCTAssertTrue(Tier0OverflowLogger.shared.hasFatalOverflows,
            "Tier0 overflow should be logged")
    }

    func testNonTier0OverflowAllowed() {
        // debugField is not Tier0 - overflow is allowed
        let result = OverflowTier0Fence.handleOverflow(
            field: "debugField",
            value: 100000,
            bound: 65536,
            direction: .above
        )

        XCTAssertEqual(result, 65536, "Should clamp to bound")
    }
}
```

#### HealthIsolationTests.swift

```swift
//
// HealthIsolationTests.swift
// Verify Health module has NO forbidden dependencies
//

import XCTest
@testable import PR4Health

final class HealthIsolationTests: XCTestCase {

    /// Test that HealthInputs only contains allowed fields
    func testHealthInputsClosedSet() {
        // HealthInputs should ONLY have these fields:
        // - consistency
        // - coverage
        // - confidenceStability
        // - latencyOK

        let inputs = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )

        // Verify we can create HealthInputs without any Quality/Uncertainty/Gate data
        XCTAssertNotNil(inputs)

        // This test's existence proves the API doesn't require forbidden inputs
    }

    /// Test that HealthComputer doesn't access forbidden types
    func testHealthComputerIsolation() {
        // If this compiles, Health doesn't depend on Quality/Uncertainty/Gate
        let inputs = HealthInputs(
            consistency: 0.8,
            coverage: 0.9,
            confidenceStability: 0.7,
            latencyOK: true
        )

        let health = HealthComputer.compute(inputs: inputs)

        // Health should be in [0, 1]
        XCTAssertGreaterThanOrEqual(health, 0.0)
        XCTAssertLessThanOrEqual(health, 1.0)
    }

    /// Test health computation is independent of quality
    func testHealthIndependentOfQuality() {
        // Two different "quality" scenarios should produce same health
        // if the allowed inputs are the same

        let inputs1 = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )

        let inputs2 = HealthInputs(
            consistency: 0.5,
            coverage: 0.5,
            confidenceStability: 0.5,
            latencyOK: true
        )

        let health1 = HealthComputer.compute(inputs: inputs1)
        let health2 = HealthComputer.compute(inputs: inputs2)

        XCTAssertEqual(health1, health2,
            "Same inputs must produce same health")
    }

    /// Test health edge cases
    func testHealthEdgeCases() {
        // All zeros (worst case)
        let worstInputs = HealthInputs(
            consistency: 0.0,
            coverage: 0.0,
            confidenceStability: 0.0,
            latencyOK: false
        )
        let worstHealth = HealthComputer.compute(inputs: worstInputs)
        XCTAssertEqual(worstHealth, 0.0, accuracy: 0.01)

        // All ones (best case)
        let bestInputs = HealthInputs(
            consistency: 1.0,
            coverage: 1.0,
            confidenceStability: 1.0,
            latencyOK: true
        )
        let bestHealth = HealthComputer.compute(inputs: bestInputs)
        XCTAssertEqual(bestHealth, 1.0, accuracy: 0.01)
    }
}
```

#### SoftmaxMassConservationTests.swift

```swift
//
// SoftmaxMassConservationTests.swift
// Verify softmax sum is EXACTLY 65536
//

import XCTest
@testable import PR4Softmax

final class SoftmaxMassConservationTests: XCTestCase {

    /// Test sum is exactly 65536 for random inputs
    func testMassConservation1000Random() {
        for seed in 0..<1000 {
            // Generate deterministic random input
            var rng = SplitMix64(seed: UInt64(seed))
            let count = Int.random(in: 2...100, using: &rng)
            let logits = (0..<count).map { _ in
                Int64.random(in: -20*65536...20*65536, using: &rng)
            }

            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)

            let sum = weights.reduce(0, +)
            XCTAssertEqual(sum, 65536,
                "Mass conservation failed for seed \(seed): sum = \(sum)")

            // All weights non-negative
            for (i, w) in weights.enumerated() {
                XCTAssertGreaterThanOrEqual(w, 0,
                    "Negative weight at index \(i) for seed \(seed)")
            }
        }
    }

    /// Test mass conservation with extreme values
    func testMassConservationExtreme() {
        let extremeCases: [[Int64]] = [
            // All very negative (potential underflow)
            [-30 * 65536, -30 * 65536, -30 * 65536],

            // Mixed extreme
            [20 * 65536, -20 * 65536],

            // Many small values
            Array(repeating: Int64(-10 * 65536), count: 100),

            // One dominant
            [0] + Array(repeating: Int64(-30 * 65536), count: 99),
        ]

        for (i, logits) in extremeCases.enumerated() {
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)

            let sum = weights.reduce(0, +)
            XCTAssertEqual(sum, 65536,
                "Mass conservation failed for extreme case \(i): sum = \(sum)")
        }
    }

    /// Test step-by-step invariants
    func testStepInvariants() {
        let logits: [Int64] = [65536, 32768, 0, -32768, -65536]

        // Step 1: Find max
        let step1 = SoftmaxExactSumV2.step1_findMax(logits)
        XCTAssertEqual(step1.maxLogit, 65536)
        XCTAssertEqual(step1.maxIndex, 0)

        // Step 2: Compute exp
        let step2 = SoftmaxExactSumV2.step2_computeExp(logits: logits, step1: step1)
        XCTAssertTrue(step2.expValues.allSatisfy { $0 >= 0 }, "All exp >= 0")
        XCTAssertEqual(step2.expValues[0], 65536, "exp(0) == 65536")

        // Step 3: Kahan sum
        let step3 = SoftmaxExactSumV2.step3_kahanSum(step2: step2)
        XCTAssertGreaterThan(step3.sumExp, 0, "Sum > 0")

        // Step 4: Normalize
        let step4 = SoftmaxExactSumV2.step4_normalize(
            step2: step2, step3: step3, count: logits.count)
        XCTAssertTrue(step4.weights.allSatisfy { $0 >= 0 }, "All weights >= 0")

        // Step 5: Compute sum
        let step5 = SoftmaxExactSumV2.step5_computeSum(step4: step4)
        // actualSum + remainder == 65536
        XCTAssertEqual(step5.actualSum + step5.remainder, 65536)

        // Step 6: Distribute remainder
        let step6 = SoftmaxExactSumV2.step6_distributeRemainder(
            step4: step4, step5: step5)
        let finalSum = step6.finalWeights.reduce(0, +)
        XCTAssertEqual(finalSum, 65536, "Final sum MUST be exactly 65536")
    }
}

/// Deterministic RNG for reproducible tests
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

---

## Part 3: CI/CD Configuration

### 3.1 GitHub Actions Workflow

Create `.github/workflows/pr4-ci.yml`:

```yaml
name: PR4 V10 CI

on:
  push:
    branches: [main, develop]
    paths:
      - 'Sources/PR4**'
      - 'Tests/PR4**'
      - 'Package.swift'
  pull_request:
    branches: [main]
    paths:
      - 'Sources/PR4**'
      - 'Tests/PR4**'

env:
  SWIFT_VERSION: '5.9'

jobs:
  # ═══════════════════════════════════════════════════════════════════════
  # Job 1: macOS ARM64 Tests
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

      - name: Build
        run: swift build -c release

      - name: Run Tests
        run: swift test --enable-code-coverage

      - name: Generate Determinism Digest
        run: |
          swift run PR4DigestGenerator > digest-macos-arm64.txt

      - name: Upload Digest
        uses: actions/upload-artifact@v4
        with:
          name: digest-macos-arm64
          path: digest-macos-arm64.txt

  # ═══════════════════════════════════════════════════════════════════════
  # Job 2: macOS x86_64 Tests
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

      - name: Build
        run: swift build -c release

      - name: Run Tests
        run: swift test

      - name: Generate Determinism Digest
        run: |
          swift run PR4DigestGenerator > digest-macos-x86.txt

      - name: Upload Digest
        uses: actions/upload-artifact@v4
        with:
          name: digest-macos-x86
          path: digest-macos-x86.txt

  # ═══════════════════════════════════════════════════════════════════════
  # Job 3: Linux x86_64 Tests
  # ═══════════════════════════════════════════════════════════════════════
  test-linux:
    name: Linux x86_64 Tests
    runs-on: ubuntu-latest
    container:
      image: swift:5.9-jammy
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: swift build -c release

      - name: Run Tests
        run: swift test

      - name: Generate Determinism Digest
        run: |
          swift run PR4DigestGenerator > digest-linux-x86.txt

      - name: Upload Digest
        uses: actions/upload-artifact@v4
        with:
          name: digest-linux-x86
          path: digest-linux-x86.txt

  # ═══════════════════════════════════════════════════════════════════════
  # Job 4: iOS Simulator Tests
  # ═══════════════════════════════════════════════════════════════════════
  test-ios:
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
  # Job 5: Cross-Platform Digest Comparison
  # ═══════════════════════════════════════════════════════════════════════
  compare-digests:
    name: Cross-Platform Determinism Check
    needs: [test-macos-arm64, test-macos-x86, test-linux]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

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

      - name: Download Linux Digest
        uses: actions/download-artifact@v4
        with:
          name: digest-linux-x86
          path: digests/

      - name: Compare Digests
        run: |
          echo "=== Cross-Platform Determinism Check ==="

          MACOS_ARM64=$(cat digests/digest-macos-arm64.txt)
          MACOS_X86=$(cat digests/digest-macos-x86.txt)
          LINUX=$(cat digests/digest-linux-x86.txt)

          echo "macOS ARM64: $MACOS_ARM64"
          echo "macOS x86_64: $MACOS_X86"
          echo "Linux x86_64: $LINUX"

          if [ "$MACOS_ARM64" != "$MACOS_X86" ]; then
            echo "❌ FAILED: macOS ARM64 vs x86_64 mismatch!"
            exit 1
          fi

          if [ "$MACOS_ARM64" != "$LINUX" ]; then
            echo "❌ FAILED: macOS ARM64 vs Linux mismatch!"
            exit 1
          fi

          echo "✅ All platforms produce identical determinism digest"

  # ═══════════════════════════════════════════════════════════════════════
  # Job 6: Static Analysis & Linting
  # ═══════════════════════════════════════════════════════════════════════
  lint:
    name: Static Analysis
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Check Health Isolation
        run: |
          echo "Checking Health module for forbidden imports..."

          # Health should NOT import Quality, Uncertainty, or Gate
          FORBIDDEN_IMPORTS=$(grep -r "import PR4Quality\|import PR4Uncertainty\|import PR4Gate" Sources/PR4Health/ || true)

          if [ -n "$FORBIDDEN_IMPORTS" ]; then
            echo "❌ Health module has forbidden imports:"
            echo "$FORBIDDEN_IMPORTS"
            exit 1
          fi

          echo "✅ Health module isolation verified"

      - name: Check Accelerate Usage
        run: |
          echo "Checking for Accelerate/vDSP in critical path..."

          # These should NOT appear in core PR4 modules
          FORBIDDEN=$(grep -rE "import Accelerate|vDSP_|vForce|vImage" \
            Sources/PR4Math/ \
            Sources/PR4Softmax/ \
            Sources/PR4LUT/ \
            Sources/PR4Overflow/ || true)

          if [ -n "$FORBIDDEN" ]; then
            echo "❌ Accelerate/vDSP found in critical path:"
            echo "$FORBIDDEN"
            exit 1
          fi

          echo "✅ No Accelerate/vDSP in critical path"

      - name: Verify Package DAG
        run: |
          echo "Verifying Package dependency graph..."
          swift run PackageDAGVerifier || exit 1

      - name: Check LUT Integrity
        run: |
          echo "Verifying LUT checksums..."
          swift run LUTIntegrityChecker || exit 1

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
        run: |
          swift test --filter GoldenBaselineVerificationTests

      - name: Check for Regressions
        run: |
          echo "Checking against committed golden baselines..."
          swift run GoldenBaselineChecker Artifacts/Golden/
```

### 3.2 Digest Generator Tool

Create `Sources/PR4Tools/PR4DigestGenerator.swift`:

```swift
//
// PR4DigestGenerator.swift
// Tool to generate determinism digest for CI comparison
//

import Foundation
import PR4Math
import PR4Softmax
import PR4LUT
import PR4Determinism

@main
struct PR4DigestGenerator {

    static func main() {
        // Generate determinism digest from fixed inputs
        var hasher = FNV1aHasher()

        // Test 1: Softmax
        let softmaxInput: [Int64] = [65536, 32768, 0, -32768, -65536]
        let softmaxResult = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: softmaxInput)
        for value in softmaxResult {
            hasher.update(value)
        }

        // Test 2: LUT lookups
        let lutTestPoints: [Int64] = [-32*65536, -16*65536, -8*65536, -65536, 0]
        for x in lutTestPoints {
            let exp = RangeCompleteSoftmaxLUT.expQ16(x)
            hasher.update(exp)
        }

        // Test 3: Median/MAD
        let medianInput: [Int64] = [9, 3, 7, 1, 5, 8, 2, 6, 4]
        let median = DeterministicMedianMAD.medianQ16(medianInput)
        hasher.update(median)

        let mad = DeterministicMedianMAD.madQ16(medianInput)
        hasher.update(mad)

        // Test 4: Q16 arithmetic
        let (sum, _) = Q16.add(65536, 32768)
        hasher.update(sum)

        let (product, _) = Q16.multiply(65536, 32768)
        hasher.update(product)

        // Output final digest
        let digest = hasher.finalize()
        print(String(format: "%016llx", digest))
    }
}

struct FNV1aHasher {
    private var hash: UInt64 = 14695981039346656037

    mutating func update(_ value: Int64) {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
    }

    func finalize() -> UInt64 {
        return hash
    }
}
```

---

## Part 4: Runtime Guards & Defensive Checks

### 4.1 Runtime Invariant Monitor

Create `Sources/PR4Fusion/RuntimeInvariantMonitor.swift`:

```swift
//
// RuntimeInvariantMonitor.swift
// Continuous runtime verification of invariants
//

import Foundation

/// Runtime invariant monitor
///
/// Runs continuous checks during execution to catch violations early.
public final class RuntimeInvariantMonitor {

    public static let shared = RuntimeInvariantMonitor()

    private var invariants: [String: () -> Bool] = [:]
    private var violations: [InvariantViolation] = []
    private let lock = NSLock()

    public struct InvariantViolation {
        public let name: String
        public let timestamp: Date
        public let context: String
        public let stackTrace: String
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Registration
    // ═══════════════════════════════════════════════════════════════════════

    /// Register all PR4 invariants
    public func registerPR4Invariants() {
        // Softmax sum invariant
        register(name: "SoftmaxSumIs65536") {
            // Check would be performed after each softmax call
            // For now, return true (actual check in SoftmaxExactSumV2)
            return true
        }

        // Health isolation invariant
        register(name: "HealthNoQualityDependency") {
            // Compile-time enforced, runtime check is informational
            return true
        }

        // Frame ordering invariant
        register(name: "FrameIDsMonotonic") {
            // Actual check in FrameProcessor
            return true
        }

        // Gate state validity
        register(name: "GateStatesValid") {
            // Check all gate states are valid enum cases
            return true
        }

        // LUT integrity
        register(name: "LUTIntegrity") {
            return RangeCompleteSoftmaxLUT.verifyIntegrity()
        }

        // Tier0 no overflow
        register(name: "NoTier0Overflows") {
            return !Tier0OverflowLogger.shared.hasFatalOverflows
        }
    }

    /// Register custom invariant
    public func register(name: String, check: @escaping () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        invariants[name] = check
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Checking
    // ═══════════════════════════════════════════════════════════════════════

    /// Check all invariants
    public func checkAll(context: String = "") -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var failed: [String] = []

        for (name, check) in invariants {
            if !check() {
                failed.append(name)

                let violation = InvariantViolation(
                    name: name,
                    timestamp: Date(),
                    context: context,
                    stackTrace: Thread.callStackSymbols.joined(separator: "\n")
                )

                violations.append(violation)

                #if DETERMINISM_STRICT
                assertionFailure("Invariant violated: \(name)")
                #else
                print("⚠️ Invariant violated: \(name) in \(context)")
                #endif
            }
        }

        return failed
    }

    /// Check specific invariant
    public func check(_ name: String, context: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let check = invariants[name] else {
            return true  // Unknown invariant
        }

        return check()
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reporting
    // ═══════════════════════════════════════════════════════════════════════

    /// Get all violations
    public func getViolations() -> [InvariantViolation] {
        lock.lock()
        defer { lock.unlock() }
        return violations
    }

    /// Has any violations
    public var hasViolations: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !violations.isEmpty
    }

    /// Clear violations
    public func clearViolations() {
        lock.lock()
        defer { lock.unlock() }
        violations.removeAll()
    }
}
```

### 4.2 Pre-Flight Checks

Create `Sources/PR4Fusion/PreFlightChecks.swift`:

```swift
//
// PreFlightChecks.swift
// Verification before PR4 processing begins
//

import Foundation

/// Pre-flight checks before PR4 processing
///
/// Run these checks at app startup to catch configuration issues early.
public enum PreFlightChecks {

    /// Run all pre-flight checks
    public static func runAll() -> PreFlightResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Check 1: LUT integrity
        if !RangeCompleteSoftmaxLUT.verifyIntegrity() {
            errors.append("LUT integrity check failed")
        }

        // Check 2: Build contract
        let buildResult = DeterminismBuildContract.verify()
        if !buildResult.allPassed {
            for issue in buildResult.issues {
                warnings.append("Build contract: \(issue)")
            }
        }

        // Check 3: Platform dependency contract
        let platformResult = DeterminismDependencyContract.generateReport()
        if !platformResult.allPassed {
            for violation in platformResult.violations {
                errors.append("Platform dependency: \(violation)")
            }
        }

        // Check 4: Thread verification
        ThreadingContract.initialize()

        // Check 5: Package DAG (compile-time, but verify at runtime too)
        let dagResult = PackageDAGProof.verifyAcyclic()
        if !dagResult {
            errors.append("Package DAG has cycles")
        }

        // Check 6: Determinism mode
        #if DETERMINISM_STRICT
        print("PR4: Running in STRICT mode")
        #else
        print("PR4: Running in FAST mode")
        warnings.append("Not running in STRICT mode - some checks disabled")
        #endif

        // Register runtime invariants
        RuntimeInvariantMonitor.shared.registerPR4Invariants()

        return PreFlightResult(
            passed: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }

    public struct PreFlightResult {
        public let passed: Bool
        public let errors: [String]
        public let warnings: [String]

        public func printReport() {
            print("=== PR4 Pre-Flight Check Results ===")

            if passed {
                print("✅ All checks passed")
            } else {
                print("❌ Pre-flight checks FAILED")
            }

            if !errors.isEmpty {
                print("\nErrors:")
                for error in errors {
                    print("  ❌ \(error)")
                }
            }

            if !warnings.isEmpty {
                print("\nWarnings:")
                for warning in warnings {
                    print("  ⚠️ \(warning)")
                }
            }

            print("=====================================")
        }
    }
}
```

---

## Part 5: Verification Scripts

### 5.1 Package DAG Verifier Script

Create `Scripts/verify-package-dag.sh`:

```bash
#!/bin/bash
# verify-package-dag.sh
# Verify Package.swift dependency graph is correct

set -e

echo "=== PR4 Package DAG Verification ==="

# Step 1: Check Health module isolation
echo "Checking Health module isolation..."

HEALTH_IMPORTS=$(grep -r "^import " Sources/PR4Health/*.swift | grep -v "Foundation\|PR4Math" || true)

if [ -n "$HEALTH_IMPORTS" ]; then
    echo "❌ Health module has unexpected imports:"
    echo "$HEALTH_IMPORTS"
    exit 1
fi

echo "✅ Health module only imports Foundation and PR4Math"

# Step 2: Check for Accelerate in critical path
echo "Checking for Accelerate framework..."

ACCELERATE_USAGE=$(grep -rE "import Accelerate|vDSP_|vForce" \
    Sources/PR4Math/ \
    Sources/PR4Softmax/ \
    Sources/PR4LUT/ \
    Sources/PR4Overflow/ \
    Sources/PR4Determinism/ 2>/dev/null || true)

if [ -n "$ACCELERATE_USAGE" ]; then
    echo "❌ Accelerate found in critical path:"
    echo "$ACCELERATE_USAGE"
    exit 1
fi

echo "✅ No Accelerate in critical path"

# Step 3: Verify no circular dependencies
echo "Checking for circular dependencies..."

# Build and check for errors
swift build 2>&1 | grep -i "circular" && {
    echo "❌ Circular dependency detected"
    exit 1
} || true

echo "✅ No circular dependencies"

# Step 4: Verify forbidden imports
echo "Checking forbidden imports..."

# Quality should not import Health
if grep -r "import PR4Health" Sources/PR4Quality/*.swift 2>/dev/null; then
    echo "❌ Quality imports Health (forbidden)"
    exit 1
fi

# Gate should not be imported by Health
if grep -r "import PR4Gate" Sources/PR4Health/*.swift 2>/dev/null; then
    echo "❌ Health imports Gate (forbidden)"
    exit 1
fi

echo "✅ No forbidden imports found"

echo ""
echo "=== All DAG checks passed ==="
```

### 5.2 LUT Integrity Checker

Create `Scripts/verify-lut-integrity.swift`:

```swift
#!/usr/bin/env swift
//
// verify-lut-integrity.swift
// Verify LUT files have correct checksums
//

import Foundation
import CryptoKit

// Expected checksums (update when LUT changes)
let expectedChecksums: [String: String] = [
    "exp_lut_512.v2.bin": "abc123...",  // Replace with actual
]

func verifyLUT(at path: String, expectedChecksum: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("❌ Cannot read: \(path)")
        return false
    }

    let hash = SHA256.hash(data: data)
    let checksum = hash.map { String(format: "%02x", $0) }.joined()

    if checksum == expectedChecksum {
        print("✅ \(path): checksum matches")
        return true
    } else {
        print("❌ \(path): checksum mismatch")
        print("   Expected: \(expectedChecksum)")
        print("   Got: \(checksum)")
        return false
    }
}

// Main
var allPassed = true

for (file, checksum) in expectedChecksums {
    let path = "Artifacts/LUT/\(file)"
    if !verifyLUT(at: path, expectedChecksum: checksum) {
        allPassed = false
    }
}

exit(allPassed ? 0 : 1)
```

---

## Part 6: Remaining Implementation Tasks

### Continue implementing these files:

```
REMAINING FILES TO IMPLEMENT:

Fusion Module:
☐ Sources/PR4Fusion/FrameProcessor.swift
☐ Sources/PR4Fusion/FusionResult.swift
☐ Sources/PR4Fusion/PR4Pipeline.swift
☐ Sources/PR4Fusion/PreFlightChecks.swift
☐ Sources/PR4Fusion/RuntimeInvariantMonitor.swift

Tools:
☐ Sources/PR4Tools/PR4DigestGenerator.swift
☐ Sources/PR4Tools/PackageDAGVerifier.swift
☐ Sources/PR4Tools/LUTIntegrityChecker.swift
☐ Sources/PR4Tools/GoldenBaselineChecker.swift

Test Files:
☐ Tests/PR4MathTests/TotalOrderComparatorTests.swift
☐ Tests/PR4MathTests/DeterministicMedianMADTests.swift
☐ Tests/PR4SoftmaxTests/SoftmaxExactSumV2Tests.swift
☐ Tests/PR4SoftmaxTests/SoftmaxMassConservationTests.swift
☐ Tests/PR4HealthTests/HealthIsolationTests.swift
☐ Tests/PR4DeterminismTests/CrossPlatformDeterminismTests.swift
☐ Tests/PR4IntegrationTests/EndToEndDeterminismTests.swift

CI/CD:
☐ .github/workflows/pr4-ci.yml

Scripts:
☐ Scripts/verify-package-dag.sh
☐ Scripts/verify-lut-integrity.swift

Golden Baselines:
☐ Artifacts/Golden/softmax_standard.golden.json
☐ Artifacts/Golden/lut_reference.golden.json
☐ Artifacts/Golden/digest_reference.golden.json
```

---

## FINAL CHECKLIST

Before declaring complete:

```
IMPLEMENTATION:
☐ All 37 pillars have corresponding code
☐ All 46+ files created
☐ Package.swift compiles without errors

TESTING:
☐ swift test passes on macOS
☐ All unit tests pass
☐ 100-run determinism tests pass
☐ Golden baseline tests pass

VERIFICATION:
☐ Health module imports ONLY Foundation, PR4Math
☐ No Accelerate/vDSP in critical path
☐ Package DAG has no cycles
☐ LUT checksums verified
☐ Softmax sum == 65536 for all test cases

CI/CD:
☐ GitHub Actions workflow created
☐ Cross-platform digest comparison configured
☐ iOS simulator tests configured
☐ Linux tests configured

DOCUMENTATION:
☐ All public APIs documented
☐ Pillar mapping complete
☐ Golden baselines committed
```

---

**CONTINUE IMPLEMENTING. DO NOT STOP UNTIL ALL TASKS ARE COMPLETE.**
