# PR4 V10 - Final Implementation Guide for Cursor

**Document Type:** EXECUTABLE IMPLEMENTATION GUIDE
**Purpose:** Direct Cursor to write code in correct order with exact file paths
**Prerequisites:** Read PR4_PATCH_V10_ULTIMATE.md and PR4_PATCH_V10_SUPPLEMENT.md first

---

## ⚠️ CRITICAL INSTRUCTIONS FOR CURSOR

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CURSOR IMPLEMENTATION RULES                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. This is a CONTINUATION from previous chats that hit output limits      │
│  2. DO NOT create new plan documents                                        │
│  3. Use this guide as your TASK LIST - implement in order                  │
│  4. Each task has: file path, dependencies, skeleton, tests                │
│  5. Mark tasks complete in the checklist as you go                         │
│                                                                             │
│  IMPLEMENTATION ORDER IS CRITICAL - Follow exactly as specified            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [Implementation Order](#2-implementation-order)
3. [Phase 1: Foundation](#3-phase-1-foundation)
4. [Phase 2: Hard Fixes](#4-phase-2-hard-fixes)
5. [Phase 3: Enhanced Seals](#5-phase-3-enhanced-seals)
6. [Phase 4: Integration](#6-phase-4-integration)
7. [Wiring Diagram](#7-wiring-diagram)
8. [Test Execution Order](#8-test-execution-order)
9. [Common Pitfalls](#9-common-pitfalls)

---

## 1. Project Structure

Create this exact directory structure:

```
Aether3D/
├── Sources/
│   ├── PR4Math/                          # Foundation math (no dependencies)
│   │   ├── Q16Arithmetic.swift
│   │   ├── DeterministicRounding.swift
│   │   └── Int128.swift
│   │
│   ├── PR4LUT/                           # LUT module (depends: PR4Math)
│   │   ├── RangeCompleteSoftmaxLUT.swift
│   │   ├── LUTBinaryFormatV2.swift
│   │   └── LUTReproducibleGenerator.swift
│   │
│   ├── PR4Overflow/                      # Overflow handling (depends: PR4Math)
│   │   ├── OverflowDetectionFramework.swift
│   │   ├── OverflowTier0Fence.swift
│   │   └── OverflowReporter.swift
│   │
│   ├── PR4Determinism/                   # Determinism contracts (depends: PR4Math)
│   │   ├── DeterminismBuildContract.swift
│   │   ├── DeterminismDependencyContract.swift
│   │   ├── DeterminismDigestV2.swift
│   │   ├── LibcDeterminismWrapper.swift
│   │   ├── MetalDeterminism.swift
│   │   └── SIMDDeterminism.swift
│   │
│   ├── PR4PathTrace/                     # Path tracing (depends: PR4Math)
│   │   └── PathDeterminismTraceV2.swift
│   │
│   ├── PR4Ownership/                     # Frame ownership (depends: PR4Math, PR4PathTrace)
│   │   ├── FrameID.swift
│   │   ├── FrameContext.swift
│   │   ├── FrameContextLegacy.swift
│   │   ├── SessionContext.swift
│   │   └── CrossFrameLeakDetector.swift
│   │
│   ├── PR4Health/                        # Health (depends: PR4Math) ⚠️ ISOLATED
│   │   ├── HealthInputs.swift
│   │   ├── HealthComputer.swift
│   │   └── HealthDataFlowFence.swift
│   │
│   ├── PR4Uncertainty/                   # Uncertainty (depends: PR4Math, PR4LUT)
│   │   ├── UncertaintyPropagator.swift
│   │   └── EmpiricalP68Calibrator.swift
│   │
│   ├── PR4Softmax/                       # Softmax (depends: PR4Math, PR4LUT, PR4Overflow)
│   │   ├── SoftmaxExactSumV2.swift
│   │   └── SoftmaxNormalizationConstitution.swift
│   │
│   ├── PR4Quality/                       # Quality (depends: PR4Math, PR4LUT, PR4Overflow, PR4Uncertainty, PR4Softmax)
│   │   ├── SoftQualityComputer.swift
│   │   └── QualityResult.swift
│   │
│   ├── PR4Gate/                          # Gate (depends: PR4Math, PR4Health, PR4Quality)
│   │   ├── SoftGateState.swift
│   │   ├── SoftGateMachine.swift
│   │   └── GateDecision.swift
│   │
│   ├── PR4Calibration/                   # Calibration (depends: PR4Math, PR4Uncertainty)
│   │   ├── EmpiricalCalibrationGovernance.swift
│   │   └── CalibrationDriftDetector.swift
│   │
│   ├── PR4Golden/                        # Golden baselines (depends: all)
│   │   ├── GoldenBaselineSystem.swift
│   │   └── GoldenBaseline.swift
│   │
│   ├── PR4Fusion/                        # Top-level fusion (depends: all)
│   │   ├── FrameProcessor.swift
│   │   ├── FusionResult.swift
│   │   └── PR4Pipeline.swift
│   │
│   └── PR4Package/                       # Package DAG (build tool)
│       ├── PackageDAGProof.swift
│       └── PackageSwiftGenerator.swift
│
├── Tests/
│   ├── PR4MathTests/
│   ├── PR4LUTTests/
│   ├── PR4OverflowTests/
│   ├── PR4DeterminismTests/
│   ├── PR4PathTraceTests/
│   ├── PR4OwnershipTests/
│   ├── PR4HealthTests/
│   ├── PR4SoftmaxTests/
│   ├── PR4QualityTests/
│   ├── PR4GateTests/
│   ├── PR4CalibrationTests/
│   ├── PR4GoldenTests/
│   ├── PR4FusionTests/
│   └── PR4IntegrationTests/
│
├── Scripts/
│   ├── verify-package-dag.sh
│   ├── lint-accelerate-avoidance.sh
│   ├── lint-health-isolation.sh
│   ├── generate-lut.swift
│   └── generate-golden-baselines.swift
│
├── Artifacts/
│   ├── LUT/
│   │   └── exp_lut_512.v2.bin
│   ├── Reference/
│   │   ├── exp_reference.json
│   │   └── log_reference.json
│   └── Golden/
│       ├── softmax_10000.golden.json
│       └── digest_reference.golden.json
│
└── Package.swift
```

---

## 2. Implementation Order

**CRITICAL: Follow this exact order to avoid dependency issues**

```
Phase 1: Foundation (Days 1-2)
├── Task 1.1: PR4Math/Int128.swift
├── Task 1.2: PR4Math/Q16Arithmetic.swift
├── Task 1.3: PR4Math/DeterministicRounding.swift
├── Task 1.4: PR4PathTrace/PathDeterminismTraceV2.swift
└── Task 1.5: PR4Ownership/FrameID.swift

Phase 2A: Core Infrastructure (Days 3-4)
├── Task 2.1: PR4Overflow/OverflowDetectionFramework.swift
├── Task 2.2: PR4Overflow/OverflowTier0Fence.swift
├── Task 2.3: PR4LUT/LUTBinaryFormatV2.swift
├── Task 2.4: PR4LUT/RangeCompleteSoftmaxLUT.swift
└── Task 2.5: PR4Determinism/DeterminismBuildContract.swift

Phase 2B: Hard Fixes (Days 5-7)
├── Task 2.6: PR4Determinism/DeterminismDependencyContract.swift  [Hard-12]
├── Task 2.7: PR4Determinism/MetalDeterminism.swift               [Hard-12]
├── Task 2.8: PR4Determinism/LibcDeterminismWrapper.swift         [Hard-12]
├── Task 2.9: PR4Ownership/FrameContext.swift                     [Hard-13]
├── Task 2.10: PR4Ownership/SessionContext.swift                  [Hard-13]
└── Task 2.11: PR4Package/PackageDAGProof.swift                   [Seal-15]

Phase 3: Computation Modules (Days 8-12)
├── Task 3.1: PR4Health/HealthInputs.swift
├── Task 3.2: PR4Health/HealthComputer.swift
├── Task 3.3: PR4Softmax/SoftmaxExactSumV2.swift
├── Task 3.4: PR4Uncertainty/EmpiricalP68Calibrator.swift
├── Task 3.5: PR4Quality/SoftQualityComputer.swift
├── Task 3.6: PR4Gate/SoftGateMachine.swift
├── Task 3.7: PR4Calibration/EmpiricalCalibrationGovernance.swift
└── Task 3.8: PR4Determinism/DeterminismDigestV2.swift

Phase 4: Integration (Days 13-15)
├── Task 4.1: PR4Fusion/FrameProcessor.swift
├── Task 4.2: PR4Fusion/PR4Pipeline.swift
├── Task 4.3: PR4Golden/GoldenBaselineSystem.swift
├── Task 4.4: Scripts/verify-package-dag.sh
├── Task 4.5: Scripts/lint-health-isolation.sh
└── Task 4.6: Package.swift generation
```

---

## 3. Phase 1: Foundation

### Task 1.1: Int128.swift

**File:** `Sources/PR4Math/Int128.swift`
**Dependencies:** None
**Purpose:** 128-bit integer for overflow-safe Q16 multiplication

```swift
//
// Int128.swift
// PR4Math
//
// 128-bit integer arithmetic for overflow-safe computation
//

import Foundation

/// 128-bit signed integer
///
/// Used for intermediate results in Q16.16 multiplication
/// to prevent overflow before right-shift.
public struct Int128: Comparable, Equatable {

    // MARK: - Storage

    /// High 64 bits (signed)
    public let high: Int64

    /// Low 64 bits (unsigned)
    public let low: UInt64

    // MARK: - Initialization

    public init(high: Int64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init(_ value: Int64) {
        if value >= 0 {
            self.high = 0
            self.low = UInt64(value)
        } else {
            self.high = -1
            self.low = UInt64(bitPattern: value)
        }
    }

    public init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }

    // MARK: - Arithmetic

    /// Multiply two Int64 values, returning Int128
    public static func multiply(_ a: Int64, _ b: Int64) -> Int128 {
        // Split into 32-bit parts for safe multiplication
        let aSign = a < 0
        let bSign = b < 0
        let resultSign = aSign != bSign

        let aAbs = aSign ? UInt64(bitPattern: -a) : UInt64(a)
        let bAbs = bSign ? UInt64(bitPattern: -b) : UInt64(b)

        // Multiply unsigned
        let result = multiplyUnsigned(aAbs, bAbs)

        // Apply sign
        if resultSign {
            return result.negated()
        }
        return result
    }

    /// Unsigned multiplication
    private static func multiplyUnsigned(_ a: UInt64, _ b: UInt64) -> Int128 {
        let aLo = a & 0xFFFFFFFF
        let aHi = a >> 32
        let bLo = b & 0xFFFFFFFF
        let bHi = b >> 32

        let ll = aLo * bLo
        let lh = aLo * bHi
        let hl = aHi * bLo
        let hh = aHi * bHi

        let mid = lh + hl + (ll >> 32)
        let low = (ll & 0xFFFFFFFF) | ((mid & 0xFFFFFFFF) << 32)
        let high = hh + (mid >> 32) + (lh > UInt64.max - hl ? 1 << 32 : 0)

        return Int128(high: Int64(bitPattern: high), low: low)
    }

    /// Negate
    public func negated() -> Int128 {
        let invertedLow = ~low
        let (newLow, overflow) = invertedLow.addingReportingOverflow(1)
        let newHigh = ~high + (overflow ? 1 : 0)
        return Int128(high: newHigh, low: newLow)
    }

    /// Right shift
    public static func >> (lhs: Int128, rhs: Int) -> Int128 {
        guard rhs > 0 else { return lhs }
        guard rhs < 128 else {
            return lhs.high < 0 ? Int128(high: -1, low: UInt64.max) : Int128(high: 0, low: 0)
        }

        if rhs < 64 {
            let newLow = (lhs.low >> rhs) | (UInt64(bitPattern: lhs.high) << (64 - rhs))
            let newHigh = lhs.high >> rhs
            return Int128(high: newHigh, low: newLow)
        } else {
            let newLow = UInt64(bitPattern: lhs.high >> (rhs - 64))
            let newHigh: Int64 = lhs.high < 0 ? -1 : 0
            return Int128(high: newHigh, low: newLow)
        }
    }

    /// Convert to Int64 (with saturation)
    public func toInt64Saturating() -> Int64 {
        if high > 0 || (high == 0 && low > UInt64(Int64.max)) {
            return Int64.max
        }
        if high < -1 || (high == -1 && low < UInt64(bitPattern: Int64.min)) {
            return Int64.min
        }
        return Int64(bitPattern: low)
    }

    // MARK: - Comparable

    public static func < (lhs: Int128, rhs: Int128) -> Bool {
        if lhs.high != rhs.high {
            return lhs.high < rhs.high
        }
        return lhs.low < rhs.low
    }
}
```

**Test:** `Tests/PR4MathTests/Int128Tests.swift`

```swift
import XCTest
@testable import PR4Math

final class Int128Tests: XCTestCase {

    func testMultiplyPositive() {
        let result = Int128.multiply(1000000, 1000000)
        XCTAssertEqual(result.toInt64Saturating(), 1000000000000)
    }

    func testMultiplyNegative() {
        let result = Int128.multiply(-1000000, 1000000)
        XCTAssertEqual(result.toInt64Saturating(), -1000000000000)
    }

    func testMultiplyOverflow() {
        // This would overflow Int64 but not Int128
        let result = Int128.multiply(Int64.max / 2, 4)
        XCTAssertTrue(result.high > 0) // Overflow into high bits
    }

    func testRightShift() {
        let value = Int128(high: 0, low: 0x10000)
        let shifted = value >> 16
        XCTAssertEqual(shifted.low, 1)
    }

    func testSaturation() {
        let overflow = Int128(high: 1, low: 0)
        XCTAssertEqual(overflow.toInt64Saturating(), Int64.max)

        let underflow = Int128(high: -2, low: 0)
        XCTAssertEqual(underflow.toInt64Saturating(), Int64.min)
    }
}
```

---

### Task 1.2: Q16Arithmetic.swift

**File:** `Sources/PR4Math/Q16Arithmetic.swift`
**Dependencies:** Int128.swift
**Purpose:** Q16.16 fixed-point arithmetic with overflow checking

```swift
//
// Q16Arithmetic.swift
// PR4Math
//
// Q16.16 fixed-point arithmetic with deterministic overflow handling
//

import Foundation

/// Q16.16 fixed-point arithmetic
///
/// All values are stored as Int64 where:
/// - Bits 63-16: Integer part (signed)
/// - Bits 15-0: Fractional part (16 bits = 1/65536 precision)
public enum Q16 {

    // MARK: - Constants

    /// Scale factor: 2^16 = 65536
    public static let scale: Int64 = 65536

    /// Maximum representable value
    public static let max: Int64 = Int64.max

    /// Minimum representable value
    public static let min: Int64 = Int64.min + 1  // Reserve Int64.min for "invalid"

    /// Invalid/NaN sentinel
    public static let invalid: Int64 = Int64.min

    /// One in Q16.16 format
    public static let one: Int64 = 65536

    /// Zero in Q16.16 format
    public static let zero: Int64 = 0

    // MARK: - Conversion

    /// Convert Double to Q16.16
    @inline(__always)
    public static func fromDouble(_ value: Double) -> Int64 {
        guard value.isFinite else { return invalid }

        let scaled = value * Double(scale)
        guard scaled >= Double(Int64.min + 1) && scaled <= Double(Int64.max) else {
            return scaled > 0 ? max : min
        }

        return Int64(scaled.rounded(.toNearestOrEven))
    }

    /// Convert Q16.16 to Double
    @inline(__always)
    public static func toDouble(_ value: Int64) -> Double {
        guard value != invalid else { return .nan }
        return Double(value) / Double(scale)
    }

    /// Convert integer to Q16.16
    @inline(__always)
    public static func fromInt(_ value: Int) -> Int64 {
        return Int64(value) * scale
    }

    // MARK: - Arithmetic

    /// Add with overflow checking
    ///
    /// Returns: (result, didOverflow)
    @inline(__always)
    public static func add(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }

        let (result, overflow) = a.addingReportingOverflow(b)

        if overflow {
            // Saturate
            let saturated = (a > 0) == (b > 0) ? (a > 0 ? max : min) : result
            return (saturated, true)
        }

        return (result, false)
    }

    /// Subtract with overflow checking
    @inline(__always)
    public static func subtract(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }

        let (result, overflow) = a.subtractingReportingOverflow(b)

        if overflow {
            let saturated = a > b ? max : min
            return (saturated, true)
        }

        return (result, false)
    }

    /// Multiply Q16 × Q16 with overflow checking
    ///
    /// Uses Int128 intermediate to prevent overflow before shift.
    @inline(__always)
    public static func multiply(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }

        // Use 128-bit intermediate
        let wide = Int128.multiply(a, b)

        // Shift right by 16 to get Q16 result
        let shifted = wide >> 16

        // Check for overflow
        let result = shifted.toInt64Saturating()
        let overflow = shifted.high != 0 && shifted.high != -1

        return (result, overflow)
    }

    /// Divide Q16 / Q16 with overflow checking
    @inline(__always)
    public static func divide(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
        guard a != invalid && b != invalid else {
            return (invalid, true)
        }

        guard b != 0 else {
            // Division by zero
            return (a >= 0 ? max : min, true)
        }

        // Shift left by 16 before division to maintain precision
        // Use Int128 to prevent overflow
        let wideA = Int128(a)
        let shifted = Int128(high: wideA.high << 16 | Int64(wideA.low >> 48),
                            low: wideA.low << 16)

        // Simple division (could be improved)
        let result = shifted.toInt64Saturating() / b

        return (result, false)
    }

    // MARK: - Clamping

    /// Clamp to range [min, max]
    @inline(__always)
    public static func clamp(_ value: Int64, min: Int64, max: Int64) -> Int64 {
        guard value != invalid else { return invalid }

        if value < min { return min }
        if value > max { return max }
        return value
    }

    /// Clamp to [0, 1] in Q16 (0 to 65536)
    @inline(__always)
    public static func clampUnit(_ value: Int64) -> Int64 {
        return clamp(value, min: 0, max: one)
    }

    // MARK: - Validation

    /// Check if value is valid (not the invalid sentinel)
    @inline(__always)
    public static func isValid(_ value: Int64) -> Bool {
        return value != invalid
    }
}
```

---

### Task 1.3: DeterministicRounding.swift

**File:** `Sources/PR4Math/DeterministicRounding.swift`
**Dependencies:** None
**Purpose:** Deterministic rounding (banker's rounding)

```swift
//
// DeterministicRounding.swift
// PR4Math
//
// Deterministic rounding policy: round half to even (banker's rounding)
//

import Foundation

/// Deterministic rounding
///
/// V10 RULE: All rounding uses "round half to even" (banker's rounding)
/// This is deterministic and reduces bias in cumulative operations.
public enum DeterministicRounding {

    /// Round to nearest integer, ties to even
    @inline(__always)
    public static func roundToEven(_ value: Double) -> Int64 {
        return Int64(value.rounded(.toNearestOrEven))
    }

    /// Round Q16 value to integer part only
    @inline(__always)
    public static func roundQ16ToInt(_ value: Int64) -> Int64 {
        // Add half (32768) and truncate
        // For ties, we need to check if result is odd and adjust
        let half: Int64 = 32768
        let rounded = (value + half) >> 16

        // Check for tie (fractional part was exactly 0.5)
        let fractional = value & 0xFFFF
        if fractional == half {
            // Tie: round to even
            if rounded & 1 == 1 {
                return (rounded - 1) << 16
            }
        }

        return rounded << 16
    }

    /// Divide with deterministic rounding
    ///
    /// For integer division, we want to round to nearest, ties to even.
    @inline(__always)
    public static func divideRounded(_ numerator: Int64, _ denominator: Int64) -> Int64 {
        guard denominator != 0 else { return Q16.invalid }

        let quotient = numerator / denominator
        let remainder = numerator % denominator

        // Check if we should round up
        let absRemainder = remainder < 0 ? -remainder : remainder
        let absDenominator = denominator < 0 ? -denominator : denominator
        let threshold = absDenominator / 2

        if absRemainder > threshold {
            // Round away from zero
            return numerator > 0 ? quotient + 1 : quotient - 1
        } else if absRemainder == threshold {
            // Tie: round to even
            if quotient & 1 == 1 {
                return numerator > 0 ? quotient + 1 : quotient - 1
            }
        }

        return quotient
    }
}
```

---

### Task 1.4: PathDeterminismTraceV2.swift

**File:** `Sources/PR4PathTrace/PathDeterminismTraceV2.swift`
**Dependencies:** None
**Purpose:** Version 2 path trace with token whitelist

```swift
//
// PathDeterminismTraceV2.swift
// PR4PathTrace
//
// V10 Path Trace: Versioned with exhaustive token whitelist
//

import Foundation

/// Branch token whitelist
///
/// V10 RULE: Only these tokens are valid. Unknown tokens = validation error.
public enum BranchToken: UInt8, CaseIterable, Codable {

    // Gate Decisions (0x01-0x0F)
    case gateEnabled = 0x01
    case gateDisabled = 0x02
    case gateDisablingConfirming = 0x03
    case gateEnablingConfirming = 0x04
    case gateNoChange = 0x05

    // Overflow Decisions (0x10-0x1F)
    case noOverflow = 0x10
    case overflowClamped = 0x11
    case overflowIsolated = 0x12
    case overflowFailed = 0x13
    case overflowDegraded = 0x14

    // Softmax Decisions (0x20-0x2F)
    case softmaxNormal = 0x20
    case softmaxUniform = 0x21
    case softmaxRemainderDistributed = 0x22
    case softmaxTieBreak = 0x23

    // Health Decisions (0x30-0x3F)
    case healthAboveThreshold = 0x30
    case healthBelowThreshold = 0x31
    case healthInHysteresis = 0x32

    // Calibration Decisions (0x40-0x4F)
    case calibrationEmpirical = 0x40
    case calibrationFallback = 0x41
    case calibrationDrift = 0x42

    // MAD State (0x50-0x5F)
    case madFrozen = 0x50
    case madUpdating = 0x51
    case madRecovery = 0x52

    // Frame Context (0x60-0x6F)
    case frameContextCreated = 0x60
    case frameContextConsumed = 0x61
    case sessionStateUpdated = 0x62
    case platformCheckPassed = 0x63
    case platformCheckFailed = 0x64

    // Unknown/Invalid
    case unknown = 0xFF
}

/// Path trace V2
public final class PathDeterminismTraceV2 {

    // MARK: - Version

    public static let currentVersion: UInt16 = 2
    public static let minSupportedVersion: UInt16 = 1

    // MARK: - State

    private var tokens: [BranchToken] = []
    private let maxTokens: Int = 256
    public let version: UInt16 = currentVersion

    public init() {}

    // MARK: - Recording

    @inline(__always)
    public func record(_ token: BranchToken) {
        guard token != .unknown else { return }

        if tokens.count < maxTokens {
            tokens.append(token)
        }
    }

    // MARK: - Signature

    public var signature: UInt64 {
        var hash: UInt64 = 14695981039346656037  // FNV-1a offset
        let prime: UInt64 = 1099511628211

        hash ^= UInt64(version)
        hash = hash &* prime

        for token in tokens {
            hash ^= UInt64(token.rawValue)
            hash = hash &* prime
        }

        return hash
    }

    public var path: [BranchToken] { tokens }

    public func reset() {
        tokens.removeAll(keepingCapacity: true)
    }

    // MARK: - Serialization

    public struct SerializedTrace: Codable, Equatable {
        public let version: UInt16
        public let tokens: [UInt8]
        public let signature: UInt64

        public func validate() -> [String] {
            var errors: [String] = []

            for (index, rawToken) in tokens.enumerated() {
                if BranchToken(rawValue: rawToken) == nil {
                    errors.append("Unknown token 0x\(String(rawToken, radix: 16)) at index \(index)")
                }
            }

            return errors
        }
    }

    public func serialize() -> SerializedTrace {
        return SerializedTrace(
            version: version,
            tokens: tokens.map { $0.rawValue },
            signature: signature
        )
    }

    public static func deserialize(_ serialized: SerializedTrace) -> PathDeterminismTraceV2? {
        guard serialized.version >= minSupportedVersion else { return nil }

        let trace = PathDeterminismTraceV2()

        for rawToken in serialized.tokens {
            if let token = BranchToken(rawValue: rawToken) {
                trace.tokens.append(token)
            } else {
                trace.tokens.append(.unknown)
            }
        }

        return trace
    }
}
```

---

### Task 1.5: FrameID.swift

**File:** `Sources/PR4Ownership/FrameID.swift`
**Dependencies:** None
**Purpose:** Unique frame identifier

```swift
//
// FrameID.swift
// PR4Ownership
//
// Unique frame identifier for ownership tracking
//

import Foundation

/// Unique frame identifier
public struct FrameID: Hashable, Comparable, CustomStringConvertible, Codable {

    private static var counter: UInt64 = 0
    private static let lock = NSLock()

    public let value: UInt64
    public let timestamp: Date

    /// Create a new unique frame ID
    public static func next() -> FrameID {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return FrameID(value: counter, timestamp: Date())
    }

    private init(value: UInt64, timestamp: Date) {
        self.value = value
        self.timestamp = timestamp
    }

    // For Codable
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decode(UInt64.self, forKey: .value)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case value, timestamp
    }

    public static func < (lhs: FrameID, rhs: FrameID) -> Bool {
        return lhs.value < rhs.value
    }

    public var description: String {
        return "Frame(\(value))"
    }
}
```

---

## 4. Phase 2: Hard Fixes

### Task 2.6: DeterminismDependencyContract.swift [Hard-12]

**File:** `Sources/PR4Determinism/DeterminismDependencyContract.swift`
**Dependencies:** None
**Purpose:** Platform dependency whitelist/blacklist

**Key Implementation Points:**

```swift
// 1. Define allowedDependencies set
public static let allowedDependencies: Set<String> = [
    "Foundation", "Dispatch", "Darwin", "Swift", "simd"
]

// 2. Define forbiddenDependenciesCriticalPath set
public static let forbiddenDependenciesCriticalPath: Set<String> = [
    "Accelerate", "vImage", "Metal", "CoreML", "ARKit"
]

// 3. Implement PlatformDependencyReport struct
// 4. Implement generateReport() method
// 5. Implement build-time lint integration
```

---

### Task 2.9: FrameContext.swift [Hard-13]

**File:** `Sources/PR4Ownership/FrameContext.swift`
**Dependencies:** FrameID.swift, PathDeterminismTraceV2.swift
**Purpose:** Frame-scoped state with ownership semantics

**Key Implementation Points:**

```swift
// Swift 5.9+ version with ~Copyable
@available(macOS 14.0, iOS 17.0, *)
public struct FrameContext: ~Copyable {
    public let frameId: FrameID
    public let sessionId: UUID
    // ... state fields
    public var pathTrace: PathDeterminismTraceV2
}

// Legacy version for older Swift
public final class FrameContextLegacy {
    private var isConsumed: Bool = false

    public func consume() {
        precondition(!isConsumed, "Already consumed")
        isConsumed = true
    }

    public func assertValid() {
        precondition(!isConsumed, "Accessing consumed context")
    }
}
```

---

### Task 2.11: PackageDAGProof.swift [Seal-15]

**File:** `Sources/PR4Package/PackageDAGProof.swift`
**Dependencies:** None
**Purpose:** Compile-time dependency verification

**Key Implementation Points:**

```swift
// 1. Define targetDependencies dictionary
public static let targetDependencies: [String: Set<String>] = [
    "PR4Math": ["Foundation"],
    "PR4LUT": ["Foundation", "PR4Math"],
    "PR4Health": ["Foundation", "PR4Math"],  // NO PR4Quality!
    // ...
]

// 2. Define forbiddenDependencies list
public static let forbiddenDependencies: [(from: String, to: String, reason: String)] = [
    ("PR4Health", "PR4Quality", "Health must not depend on Quality"),
    ("PR4Health", "PR4Uncertainty", "Health must not depend on Uncertainty"),
    // ...
]

// 3. Implement verifyTarget() method
// 4. Implement verifyAcyclic() method
// 5. Implement maxDepth() method
```

---

## 5. Phase 3: Enhanced Seals

### Task 3.3: SoftmaxExactSumV2.swift

**File:** `Sources/PR4Softmax/SoftmaxExactSumV2.swift`
**Dependencies:** PR4Math, PR4LUT, PR4Overflow
**Purpose:** 6-step softmax with invariant verification

**Complete skeleton with step invariants:**

```swift
//
// SoftmaxExactSumV2.swift
// PR4Softmax
//

import Foundation
import PR4Math
import PR4LUT
import PR4Overflow

public enum SoftmaxExactSumV2 {

    public static let targetSum: Int64 = 65536

    // MARK: - Step Results with Invariants

    public struct Step1Result {
        public let maxLogit: Int64
        public let maxIndex: Int

        func verify(logits: [Int64]) -> Bool {
            for logit in logits {
                if logit > maxLogit { return false }
            }
            return logits.indices.contains(maxIndex) && logits[maxIndex] == maxLogit
        }
    }

    public struct Step2Result {
        public let expValues: [Int64]

        func verify() -> Bool {
            return expValues.allSatisfy { $0 >= 0 }
        }
    }

    public struct Step3Result {
        public let sumExp: Int64

        func verify() -> Bool {
            return sumExp >= 0
        }
    }

    public struct Step4Result {
        public let weights: [Int64]
        public let usedUniformFallback: Bool

        func verify() -> Bool {
            return weights.allSatisfy { $0 >= 0 }
        }
    }

    public struct Step5Result {
        public let actualSum: Int64
        public let remainder: Int64
    }

    public struct Step6Result {
        public let finalWeights: [Int64]

        func verify() -> Bool {
            let sum = finalWeights.reduce(0, +)
            return sum == targetSum && finalWeights.allSatisfy { $0 >= 0 }
        }
    }

    // MARK: - Steps

    public static func step1_findMax(_ logits: [Int64]) -> Step1Result {
        precondition(!logits.isEmpty)

        var maxLogit = logits[0]
        var maxIndex = 0

        for i in 1..<logits.count {
            if logits[i] > maxLogit {
                maxLogit = logits[i]
                maxIndex = i
            }
        }

        let result = Step1Result(maxLogit: maxLogit, maxIndex: maxIndex)
        assert(result.verify(logits: logits), "Step 1 postcondition failed")
        return result
    }

    public static func step2_computeExp(logits: [Int64], step1: Step1Result) -> Step2Result {
        var expValues = [Int64](repeating: 0, count: logits.count)

        for i in 0..<logits.count {
            let diff = logits[i] - step1.maxLogit
            expValues[i] = RangeCompleteSoftmaxLUT.expQ16(diff)
            if expValues[i] < 0 { expValues[i] = 0 }
        }

        let result = Step2Result(expValues: expValues)
        assert(result.verify(), "Step 2 postcondition failed")
        return result
    }

    public static func step3_kahanSum(step2: Step2Result) -> Step3Result {
        var sum: Int64 = 0
        var compensation: Int64 = 0

        for exp in step2.expValues {
            let y = exp - compensation
            let t = sum &+ y
            compensation = (t &- sum) &- y
            sum = t
        }

        let result = Step3Result(sumExp: sum)
        assert(result.verify(), "Step 3 postcondition failed")
        return result
    }

    public static func step4_normalize(step2: Step2Result, step3: Step3Result, count: Int) -> Step4Result {
        if step3.sumExp <= 0 {
            // Uniform fallback
            let uniform = targetSum / Int64(count)
            var weights = [Int64](repeating: uniform, count: count)
            weights[0] += targetSum - uniform * Int64(count)
            return Step4Result(weights: weights, usedUniformFallback: true)
        }

        var weights = [Int64](repeating: 0, count: count)
        for i in 0..<count {
            let raw = (step2.expValues[i] << 16) / step3.sumExp
            weights[i] = max(0, raw)
        }

        let result = Step4Result(weights: weights, usedUniformFallback: false)
        assert(result.verify(), "Step 4 postcondition failed")
        return result
    }

    public static func step5_computeSum(step4: Step4Result) -> Step5Result {
        let actualSum = step4.weights.reduce(0, +)
        return Step5Result(actualSum: actualSum, remainder: targetSum - actualSum)
    }

    public static func step6_distributeRemainder(step4: Step4Result, step5: Step5Result) -> Step6Result {
        var weights = step4.weights

        if step5.remainder != 0 {
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

        let result = Step6Result(finalWeights: weights)
        assert(result.verify(), "Step 6 postcondition failed: sum = \(weights.reduce(0, +))")
        return result
    }

    // MARK: - Complete Algorithm

    public static func softmaxExactSum(logitsQ16: [Int64], trace: PathDeterminismTraceV2? = nil) -> [Int64] {
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

## 6. Phase 4: Integration

### Task 4.1: FrameProcessor.swift

**File:** `Sources/PR4Fusion/FrameProcessor.swift`
**Dependencies:** All modules
**Purpose:** Main frame processing pipeline

```swift
//
// FrameProcessor.swift
// PR4Fusion
//

import Foundation
import PR4Math
import PR4Ownership
import PR4Health
import PR4Quality
import PR4Gate
import PR4Determinism
import PR4PathTrace

public final class FrameProcessor {

    private let session: SessionContext
    private let reentrancyGuard: ReentrancyGuard

    public init(session: SessionContext) {
        self.session = session
        self.reentrancyGuard = ReentrancyGuard(name: "FrameProcessor")
    }

    /// Process frame with ownership semantics
    public func processFrame(_ context: FrameContextLegacy) -> FrameResult {
        return reentrancyGuard.execute {
            context.assertValid()

            // Phase 1: Validation
            context.pathTrace.record(.frameContextCreated)

            // Phase 2: Get session snapshot
            let snapshot = session.createFrameSnapshot()

            // Phase 3: Compute (implementation details...)
            let result = doProcess(context, snapshot: snapshot)

            // Phase 4: Consume context
            context.consume()
            context.pathTrace.record(.frameContextConsumed)

            // Phase 5: Update session
            session.update(from: result)

            return result
        }
    }

    private func doProcess(_ context: FrameContextLegacy, snapshot: SessionSnapshot) -> FrameResult {
        // Implementation...
        fatalError("Implement")
    }
}

public class ReentrancyGuard {
    private var isExecuting = false
    private let name: String

    public init(name: String) {
        self.name = name
    }

    public func execute<T>(_ block: () throws -> T) rethrows -> T {
        precondition(!isExecuting, "Reentrant call to \(name)")
        isExecuting = true
        defer { isExecuting = false }
        return try block()
    }
}
```

---

## 7. Wiring Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PR4 V10 MODULE WIRING                              │
└─────────────────────────────────────────────────────────────────────────────┘

Level 0 (No dependencies):
┌──────────┐  ┌──────────┐  ┌──────────┐
│ PR4Math  │  │PR4PathTrc│  │PR4Package│
└────┬─────┘  └────┬─────┘  └──────────┘
     │             │
     ▼             │
Level 1:          │
┌──────────┐      │    ┌──────────┐
│  PR4LUT  │      │    │PR4Ovflw  │
└────┬─────┘      │    └────┬─────┘
     │            │         │
     ▼            ▼         │
Level 2:    ┌──────────┐    │
            │PR4Ownrshp│    │
            └────┬─────┘    │
                 │          │
     ┌───────────┼──────────┼───────────┐
     ▼           │          ▼           ▼
Level 3:   ┌──────────┐  ┌──────────┐  ┌──────────┐
           │PR4Health │  │PR4Uncert │  │PR4Softmax│
           │⚠️ISOLATED│  └────┬─────┘  └────┬─────┘
           └────┬─────┘       │             │
                │             ▼             │
Level 4:        │       ┌──────────┐        │
                │       │PR4Quality│◄───────┘
                │       └────┬─────┘
                │            │
                ▼            ▼
Level 5:   ┌──────────────────────┐
           │      PR4Gate         │
           └──────────┬───────────┘
                      │
                      ▼
Level 6:   ┌──────────────────────┐
           │     PR4Fusion        │
           │   (FrameProcessor)   │
           └──────────────────────┘

⚠️ CRITICAL: PR4Health has NO arrows to PR4Quality/PR4Uncertainty/PR4Gate
```

---

## 8. Test Execution Order

```bash
# Run tests in dependency order

# Level 0
swift test --filter PR4MathTests
swift test --filter PR4PathTraceTests

# Level 1
swift test --filter PR4LUTTests
swift test --filter PR4OverflowTests

# Level 2
swift test --filter PR4OwnershipTests
swift test --filter PR4DeterminismTests

# Level 3
swift test --filter PR4HealthTests
swift test --filter PR4SoftmaxTests

# Level 4
swift test --filter PR4QualityTests

# Level 5
swift test --filter PR4GateTests

# Level 6
swift test --filter PR4FusionTests

# Integration
swift test --filter PR4IntegrationTests

# Golden baselines
swift test --filter PR4GoldenTests
```

---

## 9. Common Pitfalls

### Pitfall 1: Health Dependency Leak

```swift
// ❌ WRONG: Health importing Quality
import PR4Quality  // FORBIDDEN in PR4Health module!

// ✅ CORRECT: Health uses only its allowed inputs
struct HealthInputs {
    let consistency: Double  // From depth agreement, NOT quality
    let coverage: Double     // From validity mask, NOT quality
}
```

### Pitfall 2: Frame Context Reuse

```swift
// ❌ WRONG: Using context after processing
let context = FrameContextLegacy(...)
let result1 = processor.processFrame(context)
let result2 = processor.processFrame(context)  // CRASH: Already consumed!

// ✅ CORRECT: New context for each frame
let context1 = FrameContextLegacy(...)
let result1 = processor.processFrame(context1)

let context2 = FrameContextLegacy(...)  // New context
let result2 = processor.processFrame(context2)
```

### Pitfall 3: Softmax Sum Not Exactly 65536

```swift
// ❌ WRONG: Not distributing remainder
let weights = expValues.map { ($0 << 16) / sumExp }
// Sum might be 65535 or 65537 due to rounding!

// ✅ CORRECT: Use SoftmaxExactSumV2 which guarantees sum == 65536
let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
assert(weights.reduce(0, +) == 65536)  // Always true
```

### Pitfall 4: Missing Path Trace Recording

```swift
// ❌ WRONG: Forgetting to record branch decisions
if gateState == .enabled {
    // Do something
} else {
    // Do something else
}

// ✅ CORRECT: Record every significant branch
if gateState == .enabled {
    trace.record(.gateEnabled)
    // Do something
} else {
    trace.record(.gateDisabled)
    // Do something else
}
```

### Pitfall 5: Using System exp/log Directly

```swift
// ❌ WRONG: Using system math in critical path
let result = Darwin.exp(x)  // Non-deterministic across platforms!

// ✅ CORRECT: Use LUT-based or wrapped version
let result = LibcDeterminismWrapper.exp(x)  // Verified against reference
// Or
let resultQ16 = RangeCompleteSoftmaxLUT.expQ16(xQ16)  // Pure LUT
```

---

## Implementation Checklist

Copy this to track progress:

```
Phase 1: Foundation
[ ] Task 1.1: PR4Math/Int128.swift
[ ] Task 1.2: PR4Math/Q16Arithmetic.swift
[ ] Task 1.3: PR4Math/DeterministicRounding.swift
[ ] Task 1.4: PR4PathTrace/PathDeterminismTraceV2.swift
[ ] Task 1.5: PR4Ownership/FrameID.swift
[ ] Tests passing for Phase 1

Phase 2A: Core Infrastructure
[ ] Task 2.1: PR4Overflow/OverflowDetectionFramework.swift
[ ] Task 2.2: PR4Overflow/OverflowTier0Fence.swift
[ ] Task 2.3: PR4LUT/LUTBinaryFormatV2.swift
[ ] Task 2.4: PR4LUT/RangeCompleteSoftmaxLUT.swift
[ ] Task 2.5: PR4Determinism/DeterminismBuildContract.swift
[ ] Tests passing for Phase 2A

Phase 2B: Hard Fixes
[ ] Task 2.6: DeterminismDependencyContract.swift [Hard-12]
[ ] Task 2.7: MetalDeterminism.swift [Hard-12]
[ ] Task 2.8: LibcDeterminismWrapper.swift [Hard-12]
[ ] Task 2.9: FrameContext.swift [Hard-13]
[ ] Task 2.10: SessionContext.swift [Hard-13]
[ ] Task 2.11: PackageDAGProof.swift [Seal-15]
[ ] Tests passing for Phase 2B

Phase 3: Computation Modules
[ ] Task 3.1: PR4Health/HealthInputs.swift
[ ] Task 3.2: PR4Health/HealthComputer.swift
[ ] Task 3.3: PR4Softmax/SoftmaxExactSumV2.swift
[ ] Task 3.4: PR4Uncertainty/EmpiricalP68Calibrator.swift
[ ] Task 3.5: PR4Quality/SoftQualityComputer.swift
[ ] Task 3.6: PR4Gate/SoftGateMachine.swift
[ ] Task 3.7: PR4Calibration/EmpiricalCalibrationGovernance.swift
[ ] Task 3.8: PR4Determinism/DeterminismDigestV2.swift
[ ] Tests passing for Phase 3

Phase 4: Integration
[ ] Task 4.1: PR4Fusion/FrameProcessor.swift
[ ] Task 4.2: PR4Fusion/PR4Pipeline.swift
[ ] Task 4.3: PR4Golden/GoldenBaselineSystem.swift
[ ] Task 4.4: Scripts/verify-package-dag.sh
[ ] Task 4.5: Scripts/lint-health-isolation.sh
[ ] Task 4.6: Package.swift generation
[ ] All integration tests passing
[ ] Golden baselines verified

Final Verification
[ ] All 37 pillars implemented
[ ] Health isolation verified (lint passes)
[ ] Package DAG verified (no forbidden dependencies)
[ ] Determinism verified (same input → same output)
[ ] Cross-platform verified (macOS + iOS)
```

---

**END OF FINAL IMPLEMENTATION GUIDE**

*Ready for Cursor to start coding!*
