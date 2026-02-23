# PR4 V10 - Final Completion Prompt

## ⚠️ CRITICAL INSTRUCTIONS

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         COMPLETE ALL REMAINING WORK                          ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  STATUS: 40+ files created, compilation in progress                          ║
║                                                                              ║
║  YOUR TASK: Complete ALL remaining work without stopping                     ║
║                                                                              ║
║  RULES:                                                                      ║
║  1. DO NOT stop until everything compiles and tests pass                    ║
║  2. DO NOT ask for confirmation - just fix and continue                     ║
║  3. DO NOT push to remote - only local commits allowed                      ║
║  4. DO NOT create new plan documents                                         ║
║  5. Fix ALL compilation errors you encounter                                 ║
║  6. Run tests after fixes to verify                                          ║
║                                                                              ║
║  WHEN COMPLETE:                                                              ║
║  - All files compile without errors                                          ║
║  - swift test runs successfully                                              ║
║  - All 37 pillars are implemented                                            ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

---

## Part 1: Current Status Assessment

### 1.1 What Has Been Done

```
✅ Phase 1: Foundation (5 files)
   - Int128.swift
   - Q16Arithmetic.swift
   - DeterministicRounding.swift
   - PathDeterminismTraceV2.swift
   - FrameID.swift

✅ Phase 2: Core Infrastructure (7 files)
   - TotalOrderComparator.swift
   - DeterministicMedianMAD.swift
   - ErrorPropagationBudget.swift
   - OverflowDetectionFramework.swift
   - OverflowTier0Fence.swift
   - OverflowPropagationPolicy.swift
   - OverflowReporter.swift

✅ Phase 3: LUT & Determinism (8 files)
   - RangeCompleteSoftmaxLUT.swift
   - LUTBinaryFormatV2.swift
   - LUTReproducibleGenerator.swift
   - LogCallSiteContract.swift
   - DeterminismMode.swift
   - DeterminismBuildContract.swift
   - DeterminismDependencyContract.swift
   - DeterminismDigestV2.swift

✅ Phase 4: Ownership & Threading (4 files)
   - ThreadingContract.swift
   - FrameContext.swift
   - SessionContext.swift
   - CrossFrameLeakDetector.swift

✅ Phase 5: Computation Modules (9 files)
   - SoftmaxExactSumV2.swift
   - HealthInputs.swift
   - HealthComputer.swift
   - HealthDataFlowFence.swift
   - CorrelationMatrix.swift
   - UncertaintyPropagator.swift
   - EmpiricalP68Calibrator.swift
   - EmpiricalCalibrationGovernance.swift
   - CalibrationDriftDetector.swift

✅ Phase 6-8: Quality, Gate, Fusion, Golden, Package
   - SoftQualityComputer.swift
   - QualityResult.swift
   - SoftGateState.swift
   - SoftGateMachine.swift
   - GateDecision.swift
   - OnlineMADEstimator.swift
   - GoldenBaselineSystem.swift
   - PackageDAGProof.swift
   - FrameProcessor.swift
   - FusionResult.swift
   - PR4Pipeline.swift
   - PreFlightChecks.swift
   - RuntimeInvariantMonitor.swift

✅ Tests Created
   - CrossPlatformDeterminismTests.swift
   - HealthIsolationTests.swift
   - SoftmaxMassConservationTests.swift
   - TotalOrderComparatorTests.swift
   - DeterministicMedianMADTests.swift

✅ CI/CD
   - .github/workflows/pr4-ci.yml
   - scripts/verify-package-dag.sh

✅ Tools
   - PR4DigestGenerator.swift
```

### 1.2 What Needs To Be Done

```
☐ Fix ALL remaining compilation errors
☐ Ensure all imports are correct
☐ Ensure all type visibilities (public/internal) are correct
☐ Ensure all protocol conformances are complete
☐ Run `swift build` until it succeeds
☐ Run `swift test` until all tests pass
☐ Verify Package.swift has all targets correctly configured
```

---

## Part 2: Common Compilation Issues & Fixes

### 2.1 Missing Imports

If you see errors like "Cannot find type 'X' in scope", add the appropriate import:

```swift
// In files that use PR4Math types
import PR4Math

// In files that use PR4LUT types
import PR4LUT

// In files that use PR4Overflow types
import PR4Overflow

// In files that use PR4Determinism types
import PR4Determinism

// In files that use PR4PathTrace types
import PR4PathTrace

// In files that use PR4Ownership types
import PR4Ownership
```

### 2.2 Missing Public Modifiers

If you see "X is inaccessible due to 'internal' protection level", make the type/function public:

```swift
// WRONG
struct SomeType { }
func someFunction() { }

// CORRECT
public struct SomeType { }
public func someFunction() { }
```

### 2.3 Missing Protocol Conformances

If a type needs to be Codable, Hashable, etc.:

```swift
public struct MyType: Codable, Hashable, Equatable {
    // ...
}
```

### 2.4 Type Mismatches

Common type issues:

```swift
// Double vs Int64
let q16Value = Int64(doubleValue * 65536.0)
let doubleValue = Double(q16Value) / 65536.0

// Array type inference
let array: [Int64] = []  // Be explicit
```

### 2.5 Missing Initializers

Ensure all structs have proper initializers:

```swift
public struct MyStruct {
    public let field1: Int
    public let field2: String

    public init(field1: Int, field2: String) {
        self.field1 = field1
        self.field2 = field2
    }
}
```

---

## Part 3: Step-by-Step Completion Process

### Step 1: Run Build and Collect Errors

```bash
swift build 2>&1 | head -100
```

### Step 2: Fix Errors One by One

For each error:
1. Read the error message carefully
2. Go to the file and line mentioned
3. Apply the appropriate fix from Part 2
4. Save the file

### Step 3: Repeat Until Build Succeeds

```bash
swift build
```

Keep fixing until you see:
```
Build complete!
```

### Step 4: Run Tests

```bash
swift test
```

### Step 5: Fix Any Test Failures

If tests fail:
1. Read the failure message
2. Check if it's a code bug or test bug
3. Fix appropriately
4. Re-run tests

### Step 6: Final Verification

```bash
# Build release
swift build -c release

# Run all tests
swift test

# Verify specific test groups
swift test --filter PR4MathTests
swift test --filter PR4SoftmaxTests
swift test --filter PR4HealthTests
swift test --filter PR4DeterminismTests
```

---

## Part 4: Package.swift Verification

Ensure Package.swift has all targets correctly configured:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aether3D",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Aether3D", targets: ["PR4Fusion"]),
        .executable(name: "PR4DigestGenerator", targets: ["PR4Tools"]),
    ],
    targets: [
        // Foundation - no dependencies
        .target(name: "PR4Math", dependencies: [], path: "Sources/PR4Math"),
        .target(name: "PR4PathTrace", dependencies: [], path: "Sources/PR4PathTrace"),

        // Level 1 - depends on Math
        .target(name: "PR4LUT", dependencies: ["PR4Math"], path: "Sources/PR4LUT"),
        .target(name: "PR4Overflow", dependencies: ["PR4Math"], path: "Sources/PR4Overflow"),
        .target(name: "PR4Determinism", dependencies: ["PR4Math"], path: "Sources/PR4Determinism"),

        // Level 2 - depends on Math, PathTrace
        .target(name: "PR4Ownership", dependencies: ["PR4Math", "PR4PathTrace"], path: "Sources/PR4Ownership"),

        // Level 3 - computation modules
        .target(name: "PR4Health", dependencies: ["PR4Math"], path: "Sources/PR4Health"),
        .target(name: "PR4Softmax", dependencies: ["PR4Math", "PR4LUT", "PR4Overflow", "PR4PathTrace"], path: "Sources/PR4Softmax"),
        .target(name: "PR4Uncertainty", dependencies: ["PR4Math", "PR4LUT"], path: "Sources/PR4Uncertainty"),
        .target(name: "PR4Calibration", dependencies: ["PR4Math", "PR4Uncertainty"], path: "Sources/PR4Calibration"),

        // Level 4 - Quality (depends on computation modules)
        .target(name: "PR4Quality", dependencies: ["PR4Math", "PR4LUT", "PR4Overflow", "PR4Uncertainty", "PR4Softmax"], path: "Sources/PR4Quality"),

        // Level 5 - Gate (depends on Health, Quality)
        .target(name: "PR4Gate", dependencies: ["PR4Math", "PR4Health", "PR4Quality"], path: "Sources/PR4Gate"),

        // Level 6 - Golden (depends on multiple)
        .target(name: "PR4Golden", dependencies: ["PR4Math", "PR4Softmax", "PR4Determinism"], path: "Sources/PR4Golden"),

        // Level 7 - Package verification
        .target(name: "PR4Package", dependencies: [], path: "Sources/PR4Package"),

        // Top level - Fusion
        .target(
            name: "PR4Fusion",
            dependencies: [
                "PR4Math", "PR4LUT", "PR4Overflow", "PR4Determinism",
                "PR4PathTrace", "PR4Ownership", "PR4Health", "PR4Softmax",
                "PR4Uncertainty", "PR4Calibration", "PR4Quality", "PR4Gate", "PR4Golden"
            ],
            path: "Sources/PR4Fusion"
        ),

        // Tools
        .executableTarget(
            name: "PR4Tools",
            dependencies: ["PR4Math", "PR4Softmax", "PR4LUT", "PR4Determinism"],
            path: "Sources/PR4Tools"
        ),

        // Tests
        .testTarget(name: "PR4MathTests", dependencies: ["PR4Math"], path: "Tests/PR4MathTests"),
        .testTarget(name: "PR4LUTTests", dependencies: ["PR4LUT"], path: "Tests/PR4LUTTests"),
        .testTarget(name: "PR4OverflowTests", dependencies: ["PR4Overflow"], path: "Tests/PR4OverflowTests"),
        .testTarget(name: "PR4DeterminismTests", dependencies: ["PR4Determinism", "PR4Math", "PR4Softmax", "PR4LUT"], path: "Tests/PR4DeterminismTests"),
        .testTarget(name: "PR4OwnershipTests", dependencies: ["PR4Ownership"], path: "Tests/PR4OwnershipTests"),
        .testTarget(name: "PR4SoftmaxTests", dependencies: ["PR4Softmax", "PR4LUT"], path: "Tests/PR4SoftmaxTests"),
        .testTarget(name: "PR4HealthTests", dependencies: ["PR4Health"], path: "Tests/PR4HealthTests"),
        .testTarget(name: "PR4QualityTests", dependencies: ["PR4Quality"], path: "Tests/PR4QualityTests"),
        .testTarget(name: "PR4GateTests", dependencies: ["PR4Gate"], path: "Tests/PR4GateTests"),
        .testTarget(name: "PR4CalibrationTests", dependencies: ["PR4Calibration"], path: "Tests/PR4CalibrationTests"),
        .testTarget(name: "PR4GoldenTests", dependencies: ["PR4Golden"], path: "Tests/PR4GoldenTests"),
        .testTarget(name: "PR4FusionTests", dependencies: ["PR4Fusion"], path: "Tests/PR4FusionTests"),
        .testTarget(name: "PR4IntegrationTests", dependencies: ["PR4Fusion"], path: "Tests/PR4IntegrationTests"),
    ]
)
```

---

## Part 5: Critical Checks Before Completion

### 5.1 Health Module Isolation Check

```bash
# Health should ONLY import Foundation and PR4Math
grep "^import" Sources/PR4Health/*.swift
```

Expected output:
```
import Foundation
import PR4Math
```

If you see `import PR4Quality`, `import PR4Uncertainty`, or `import PR4Gate`, REMOVE THEM.

### 5.2 Softmax Sum Verification

Run this test to verify softmax always sums to exactly 65536:

```bash
swift test --filter SoftmaxMassConservationTests
```

### 5.3 Cross-Platform Golden Values

Ensure these golden values are correct in `CrossPlatformDeterminismTests.swift`:

```swift
// These values MUST be identical on ALL platforms
static let softmaxInput: [Int64] = [65536, 0, -65536]
static let softmaxExpected: [Int64] = [47073, 17325, 6138]  // Sum = 65536
```

If the expected values are wrong, compute them once and update.

### 5.4 No Accelerate in Critical Path

```bash
grep -rE "import Accelerate|vDSP_|vForce" Sources/PR4Math/ Sources/PR4Softmax/ Sources/PR4LUT/ Sources/PR4Overflow/
```

This should return nothing. If it returns matches, REMOVE THEM.

---

## Part 6: Final Deliverables Checklist

Before reporting "complete", verify ALL of the following:

```
COMPILATION:
☐ `swift build` succeeds without errors
☐ `swift build -c release` succeeds without errors

TESTS:
☐ `swift test` passes all tests
☐ No test failures or errors

37 PILLARS:
☐ Pillar 1: DeterminismDependencyContract ✓
☐ Pillar 2: FrameContextOwnership ✓
☐ Pillar 3: PackageDAGProof ✓
☐ Pillar 4: PathTraceV2 ✓
☐ Pillar 5: SoftmaxExactSumV2 ✓
☐ Pillar 6: LUTBinaryFormatV2 ✓
☐ Pillar 7: DeterminismDigestV2 ✓
☐ Pillar 8: GoldenBaselineSystem ✓
☐ Pillar 9: TotalOrderComparator ✓
☐ Pillar 10: CalibrationDriftDetector ✓
☐ Pillar 11: HealthFenceTests ✓
☐ Pillar 12: DeterminismBuildContract ✓
☐ Pillar 13: SoftmaxNormalizationConstitution (merged into SoftmaxExactSumV2) ✓
☐ Pillar 14: HealthDataFlowFence ✓
☐ Pillar 15: PathDeterminismTrace (enhanced by V2) ✓
☐ Pillar 16: ThreadingContract ✓
☐ Pillar 17: LUTReproducibleGenerator ✓
☐ Pillar 18: OverflowTier0Fence ✓
☐ Pillar 19: TotalOrder (enhanced by TotalOrderComparator) ✓
☐ Pillar 20: EmpiricalCalibrationGovernance ✓
☐ Pillar 21: RangeCompleteSoftmaxLUT ✓
☐ Pillar 22: LogCallSiteContract ✓
☐ Pillar 23: OverflowPropagationPolicy ✓
☐ Pillar 24: DeterministicRounding ✓
☐ Pillar 25: EmpiricalP68Calibrator ✓
☐ Pillar 26: SwiftPM Target Isolation (via Package.swift) ✓
☐ Pillar 27: LUT SSOT + Hash (merged into LUTBinaryFormatV2) ✓
☐ Pillar 28: Softmax Mass Conservation (merged into SoftmaxExactSumV2) ✓
☐ Pillar 29: DeterminismDigest MinimalDiff (merged into DeterminismDigestV2) ✓
☐ Pillar 30: HealthInputs ✓
☐ Pillar 31: CorrelationMatrix ✓
☐ Pillar 32: ErrorPropagationBudget ✓
☐ Pillar 33: OverflowReporter ✓
☐ Pillar 34: DeterministicMedianMAD ✓
☐ Pillar 35: Determinism Contract Single-Line (documented) ✓
☐ Pillar 36: DeterminismMode ✓
☐ Pillar 37: V7 Foundation (Health, Quality, Gate, etc.) ✓

ISOLATION:
☐ Health module has NO imports from Quality/Uncertainty/Gate
☐ No Accelerate/vDSP in critical path modules

CI/CD:
☐ .github/workflows/pr4-ci.yml exists and is valid YAML
☐ scripts/verify-package-dag.sh exists and is executable

DO NOT PUSH:
☐ No `git push` commands executed
☐ Changes are local only
```

---

## Part 7: Expected Final Output

When everything is complete, you should be able to run:

```bash
# Build succeeds
$ swift build
Build complete!

# Tests pass
$ swift test
Test Suite 'All tests' passed at ...
    Executed X tests, with 0 failures (0 unexpected) in Y seconds

# Specific test groups pass
$ swift test --filter SoftmaxMassConservationTests
Test Suite 'SoftmaxMassConservationTests' passed

$ swift test --filter HealthIsolationTests
Test Suite 'HealthIsolationTests' passed

$ swift test --filter CrossPlatformDeterminismTests
Test Suite 'CrossPlatformDeterminismTests' passed
```

---

## EXECUTE NOW

1. Run `swift build` to see current errors
2. Fix each error systematically
3. Repeat until build succeeds
4. Run `swift test`
5. Fix any test failures
6. Report final status

**DO NOT STOP UNTIL:**
- Build succeeds
- All tests pass
- All checklist items are verified

**DO NOT PUSH TO REMOTE.**
