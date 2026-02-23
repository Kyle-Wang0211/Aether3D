# PR2 Evidence System - Patch V4 (Critical Hardening + Cross-Platform Consistency)

**Document Version:** Patch V4
**Status:** MANDATORY SUPPLEMENT TO PR2_PATCH_V3.md
**Created:** 2026-01-29
**Purpose:** Address 4 hard issues, numerical concerns, cross-platform consistency, and governance improvements

---

## Overview

This patch addresses comprehensive feedback from V3 review:

1. **4 Hard Issues (A1-A4)** - Critical architectural problems requiring immediate fix
2. **4 Numerical Concerns (B1-B4)** - Threshold and parameter refinements
3. **6 Cross-Platform Issues (C1-C6)** - Consistency guarantees across devices
4. **3 Governance Improvements (D1-D3)** - Testing, linting, and monitoring
5. **Additional Hardening** - Extra improvements for production readiness

**IMPORTANT:** This patch must be applied AFTER PR2_PATCH_V3.md. It does NOT replace V3, it supplements it.

---

## Part 1: Hard Issues (MUST FIX)

### A1. Remove ALL Residual max(gate, soft) Patterns

**Problem:** V3 Rule 1.2 claims to remove max(gate, soft) but V2's Rule A example still contains it. This semantic pollution MUST be completely eliminated.

**Solution:** Comprehensive search-and-destroy with lint enforcement

```swift
/// CURSOR INSTRUCTION: Execute this search pattern across ENTIRE codebase
///
/// FORBIDDEN PATTERNS (DELETE ALL):
/// 1. max(gateQuality, softQuality)
/// 2. max(gate, soft)
/// 3. ledgerQuality = max(
/// 4. quality = max(gateQuality
/// 5. Any variant using max() with gate and soft together
///
/// GREP COMMANDS TO RUN:
/// grep -rn "max.*gate.*soft" --include="*.swift"
/// grep -rn "max.*soft.*gate" --include="*.swift"
/// grep -rn "ledgerQuality.*=.*max" --include="*.swift"
///
/// REPLACEMENT: Separate updates to gateLedger and softLedger

// ❌ FORBIDDEN - DELETE ON SIGHT
let ledgerQuality = max(gateQuality, softQuality)
ledger.update(ledgerQuality: ledgerQuality)

// ✅ CORRECT - ONLY THIS PATTERN IS ALLOWED
splitLedger.gateLedger.update(
    patchId: patchId,
    ledgerQuality: gateQuality,
    verdict: verdict,
    frameId: frameId,
    timestamp: timestamp
)

if gateQuality > EvidenceConstants.softWriteRequiresGateMin {
    splitLedger.softLedger.update(
        patchId: patchId,
        ledgerQuality: softQuality,
        verdict: verdict,
        frameId: frameId,
        timestamp: timestamp
    )
}
```

**Lint Rule (MANDATORY):**

```swift
/// ForbiddenPatternLint.swift - Add to build phase
public enum ForbiddenPatternLint {

    /// Patterns that MUST NOT exist in codebase
    public static let forbiddenPatterns: [String] = [
        "max\\s*\\(\\s*gate.*soft",
        "max\\s*\\(\\s*soft.*gate",
        "ledgerQuality\\s*=\\s*max\\s*\\(",
        "observation\\.quality",  // Old API
        "isErroneous:\\s*Bool",   // Old API
    ]

    /// Run lint check (integrate with CI)
    public static func checkFile(_ content: String, filename: String) -> [LintViolation] {
        var violations: [LintViolation] = []

        for pattern in forbiddenPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, options: [], range: range)

                for match in matches {
                    violations.append(LintViolation(
                        file: filename,
                        pattern: pattern,
                        location: match.range
                    ))
                }
            }
        }

        return violations
    }
}
```

**File:** `Scripts/ForbiddenPatternLint.swift`

---

### A2. True Deterministic JSON Encoding

**Problem:** V3's DeterministicJSONEncoder re-parses and re-encodes, but Swift Dictionary iteration order is STILL undefined even after JSONSerialization with sortedKeys. The stabilizeContainer() function creates a NEW dictionary which has undefined iteration order.

**Solution:** Use Array of tuples for intermediate representation, never Dictionary

```swift
/// True deterministic JSON encoder
/// CRITICAL: Never use [String: Any] for intermediate storage
public final class TrueDeterministicJSONEncoder {

    public static let floatPrecision: Int = 4

    /// Encode with TRUE deterministic output
    /// Uses OrderedKeyValuePairs internally, never Dictionary
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        // Step 1: Encode to JSON data (order undefined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let rawData = try encoder.encode(value)

        // Step 2: Parse to ordered structure (NOT Dictionary)
        guard let jsonObject = try JSONSerialization.jsonObject(with: rawData, options: [.fragmentsAllowed]) as? [String: Any] else {
            return rawData
        }

        // Step 3: Convert to stable JSON string directly
        let stableString = toStableJSONString(jsonObject)

        guard let result = stableString.data(using: .utf8) else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Failed to convert to UTF8"))
        }

        return result
    }

    /// Convert to stable JSON string by sorting keys at each level
    /// CRITICAL: This function outputs a STRING, not a Dictionary
    private static func toStableJSONString(_ value: Any, indent: Int = 0) -> String {
        switch value {
        case let dict as [String: Any]:
            // CRITICAL: Sort keys and process in order
            let sortedKeys = dict.keys.sorted()
            if sortedKeys.isEmpty {
                return "{}"
            }

            var parts: [String] = []
            for key in sortedKeys {
                let keyJSON = "\"\(escapeString(key))\""
                let valueJSON = toStableJSONString(dict[key]!, indent: indent + 1)
                parts.append("\(keyJSON):\(valueJSON)")
            }

            return "{\(parts.joined(separator: ","))}"

        case let array as [Any]:
            if array.isEmpty {
                return "[]"
            }
            let parts = array.map { toStableJSONString($0, indent: indent + 1) }
            return "[\(parts.joined(separator: ","))]"

        case let double as Double:
            return formatQuantizedDouble(double)

        case let float as Float:
            return formatQuantizedDouble(Double(float))

        case let int as Int:
            return "\(int)"

        case let int64 as Int64:
            return "\(int64)"

        case let bool as Bool:
            return bool ? "true" : "false"

        case let string as String:
            return "\"\(escapeString(string))\""

        case is NSNull:
            return "null"

        default:
            // Fallback: use JSONSerialization for unknown types
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "null"
        }
    }

    /// Format double with deterministic precision
    private static func formatQuantizedDouble(_ value: Double) -> String {
        // Handle special values
        if value.isNaN { return "null" }
        if value.isInfinite { return value > 0 ? "1e308" : "-1e308" }

        // Quantize
        let multiplier = pow(10.0, Double(floatPrecision))
        let quantized = (value * multiplier).rounded() / multiplier

        // Format without trailing zeros
        let formatted = String(format: "%.\(floatPrecision)f", quantized)

        // Remove trailing zeros after decimal point
        var result = formatted
        while result.contains(".") && (result.hasSuffix("0") || result.hasSuffix(".")) {
            result.removeLast()
        }

        return result.isEmpty ? "0" : result
    }

    /// Escape string for JSON
    private static func escapeString(_ string: String) -> String {
        var result = ""
        for char in string {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if char.asciiValue ?? 0 < 32 {
                    result += String(format: "\\u%04x", char.asciiValue ?? 0)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }
}

/// Test for TRUE determinism
func testTrueDeterministicEncoding() {
    // Run 1000 times, all outputs MUST be byte-identical
    let testState = createTestState()
    var outputs: Set<Data> = []

    for _ in 0..<1000 {
        let data = try! TrueDeterministicJSONEncoder.encode(testState)
        outputs.insert(data)
    }

    XCTAssertEqual(outputs.count, 1, "Encoding MUST produce identical output every time")

    // Cross-check: decode and re-encode
    let decoded = try! JSONDecoder().decode(EvidenceState.self, from: outputs.first!)
    let reEncoded = try! TrueDeterministicJSONEncoder.encode(decoded)

    XCTAssertEqual(outputs.first!, reEncoded, "Round-trip MUST be identical")
}
```

**File:** Replace `Core/Evidence/DeterministicJSONEncoder.swift`

---

### A3. AmortizedAggregator + ConfidenceDecay Compatibility

**Problem:** AmortizedAggregator maintains running sums for O(1) per-frame, but ConfidenceDecay uses continuous time-based weighting. This creates a mathematical impossibility:
- O(1) requires pre-computed contributions
- Continuous decay means ALL patch weights change every frame
- You cannot have both without O(n) recalculation

**Solution:** Discrete decay buckets with amortized O(k) complexity

```swift
/// Amortized aggregator with bucket-based decay
///
/// DESIGN DECISION: Trade some decay granularity for O(k) performance
/// where k = number of active buckets (typically 4-8), not n = number of patches
public final class BucketedAmortizedAggregator {

    // MARK: - Decay Bucket Configuration

    /// Bucket duration in seconds (15s per bucket)
    public static let bucketDurationSec: Double = 15.0

    /// Maximum buckets to track (60s total at 15s buckets = 4 buckets)
    public static let maxBuckets: Int = 8

    /// Decay weights per bucket (index 0 = newest)
    /// Computed from: exp(-0.693 * (bucketIndex * bucketDuration) / halfLife)
    /// With halfLife = 60s: [1.0, 0.84, 0.71, 0.59, 0.50, 0.42, 0.35, 0.30]
    public static let bucketWeights: [Double] = [
        1.0,    // 0-15s
        0.84,   // 15-30s
        0.71,   // 30-45s
        0.59,   // 45-60s
        0.50,   // 60-75s
        0.42,   // 75-90s
        0.35,   // 90-105s
        0.30    // 105-120s
    ]

    // MARK: - Bucket Storage

    /// Bucket containing aggregated contributions
    public struct Bucket {
        var weightedSum: Double = 0.0
        var totalWeight: Double = 0.0
        var patchCount: Int = 0
        let createdAt: TimeInterval
    }

    /// Buckets ordered by time (index 0 = current)
    private var buckets: [Bucket] = []

    /// Patch -> (bucketIndex, evidence, weight) for incremental updates
    private var patchLocations: [String: (bucketIndex: Int, evidence: Double, weight: Double)] = [:]

    /// Current bucket start time
    private var currentBucketStart: TimeInterval = 0

    // MARK: - Public API

    public init() {
        // Initialize with first bucket
        buckets = [Bucket(createdAt: 0)]
    }

    /// Update patch contribution
    /// O(1) for updates within same bucket
    public func updatePatch(
        patchId: String,
        evidence: Double,
        baseWeight: Double,  // From frequency cap, NOT including decay
        timestamp: TimeInterval
    ) {
        // Rotate buckets if needed
        rotateBucketsIfNeeded(timestamp: timestamp)

        // Remove old contribution
        if let old = patchLocations[patchId] {
            if old.bucketIndex < buckets.count {
                buckets[old.bucketIndex].weightedSum -= old.evidence * old.weight
                buckets[old.bucketIndex].totalWeight -= old.weight
                buckets[old.bucketIndex].patchCount -= 1
            }
        }

        // Add new contribution to current bucket (index 0)
        let currentBucket = 0
        buckets[currentBucket].weightedSum += evidence * baseWeight
        buckets[currentBucket].totalWeight += baseWeight
        buckets[currentBucket].patchCount += 1

        // Track location
        patchLocations[patchId] = (currentBucket, evidence, baseWeight)
    }

    /// Get total evidence with decay applied
    /// O(k) where k = number of buckets (constant, typically 4-8)
    public var totalEvidence: Double {
        var weightedSum: Double = 0.0
        var totalWeight: Double = 0.0

        for (index, bucket) in buckets.enumerated() {
            let decayWeight = index < Self.bucketWeights.count
                ? Self.bucketWeights[index]
                : Self.bucketWeights.last!

            weightedSum += bucket.weightedSum * decayWeight
            totalWeight += bucket.totalWeight * decayWeight
        }

        return totalWeight > 0 ? weightedSum / totalWeight : 0.0
    }

    /// Periodic full recalculation (every 60 frames) to correct drift
    public func recalibrate(patches: [(patchId: String, evidence: Double, weight: Double, lastUpdate: TimeInterval)], currentTime: TimeInterval) {
        // Reset
        buckets.removeAll()
        patchLocations.removeAll()
        currentBucketStart = currentTime

        // Re-add all patches
        for patch in patches {
            let age = currentTime - patch.lastUpdate
            let bucketIndex = min(Self.maxBuckets - 1, Int(age / Self.bucketDurationSec))

            // Ensure bucket exists
            while buckets.count <= bucketIndex {
                buckets.append(Bucket(createdAt: currentTime - Double(buckets.count) * Self.bucketDurationSec))
            }

            buckets[bucketIndex].weightedSum += patch.evidence * patch.weight
            buckets[bucketIndex].totalWeight += patch.weight
            buckets[bucketIndex].patchCount += 1
            patchLocations[patch.patchId] = (bucketIndex, patch.evidence, patch.weight)
        }
    }

    // MARK: - Private

    /// Rotate buckets when time advances
    private func rotateBucketsIfNeeded(timestamp: TimeInterval) {
        let elapsed = timestamp - currentBucketStart
        let bucketsToRotate = Int(elapsed / Self.bucketDurationSec)

        if bucketsToRotate > 0 {
            // Insert new buckets at front
            for i in 0..<bucketsToRotate {
                buckets.insert(Bucket(createdAt: currentBucketStart + Double(bucketsToRotate - i) * Self.bucketDurationSec), at: 0)

                // Update patch locations
                for (patchId, var location) in patchLocations {
                    location.bucketIndex += 1
                    patchLocations[patchId] = location
                }
            }

            // Trim old buckets
            while buckets.count > Self.maxBuckets {
                let removed = buckets.removeLast()
                // Remove patches in deleted bucket
                patchLocations = patchLocations.filter { $0.value.bucketIndex < Self.maxBuckets }
            }

            currentBucketStart = timestamp
        }
    }
}
```

**Complexity Analysis:**
- `updatePatch()`: O(1) amortized
- `totalEvidence`: O(k) where k = 8 (constant)
- `recalibrate()`: O(n) - called every 60 frames
- **Overall per-frame**: O(1) + O(k)/60 = O(1) amortized

**File:** Replace `Core/Evidence/AmortizedAggregator.swift`

---

### A4. AdmissionController + TokenBucket Overlap Resolution

**Problem:** TokenBucket (soft penalty) and AdmissionController can compound to permanent rejection in weak-texture scenes. A patch getting consistent 50% quality scale (no token) + 50% novelty scale = 25% effective quality, which may never accumulate.

**Solution:** Explicit hard-block vs soft-penalty separation with guaranteed minimum throughput

```swift
/// Admission result with explicit hard/soft separation
public struct AdmissionResult: Sendable {

    /// Hard block: observation is completely rejected
    /// Reasons: time density, confirmed spam
    public let hardBlocked: Bool

    /// Soft penalty: observation is accepted but with reduced weight
    /// Value: [0.0, 1.0] where 1.0 = no penalty
    public let softPenaltyScale: Double

    /// Final decision
    public var isAllowed: Bool { !hardBlocked && softPenaltyScale > 0 }

    /// Reason for decision (debug only)
    public let reason: AdmissionReason

    public enum AdmissionReason: String, Sendable {
        case allowed = "allowed"
        case hardBlockTimeDensity = "hard_block_time_density"
        case hardBlockConfirmedSpam = "hard_block_confirmed_spam"
        case softPenaltyNoToken = "soft_penalty_no_token"
        case softPenaltyLowNovelty = "soft_penalty_low_novelty"
        case softPenaltyCompound = "soft_penalty_compound"
    }
}

/// Unified admission controller with guaranteed minimum throughput
public final class UnifiedAdmissionController {

    // MARK: - Dependencies

    private let spamProtection: SpamProtection
    private let tokenBucket: TokenBucketLimiter
    private let viewDiversity: ViewDiversityTracker

    // MARK: - Configuration

    /// Minimum soft penalty scale (GUARANTEED MINIMUM THROUGHPUT)
    /// Even worst-case compound penalties cannot go below this
    /// RATIONALE: Weak-texture scenes should still make progress
    public static let minimumSoftScale: Double = 0.25

    /// Soft penalty when token unavailable
    public static let noTokenPenalty: Double = 0.6  // Changed from 0.5

    /// Low novelty threshold
    public static let lowNoveltyThreshold: Double = 0.2

    /// Soft penalty for low novelty
    public static let lowNoveltyPenalty: Double = 0.7

    // MARK: - Public API

    public init(
        spamProtection: SpamProtection,
        tokenBucket: TokenBucketLimiter,
        viewDiversity: ViewDiversityTracker
    ) {
        self.spamProtection = spamProtection
        self.tokenBucket = tokenBucket
        self.viewDiversity = viewDiversity
    }

    /// Compute admission decision
    public func checkAdmission(
        patchId: String,
        viewAngle: Float,
        timestamp: TimeInterval
    ) -> AdmissionResult {

        // LAYER 1: Time density (HARD BLOCK)
        // This is the ONLY hard block in normal operation
        if !spamProtection.shouldAllowUpdate(patchId: patchId, timestamp: timestamp) {
            return AdmissionResult(
                hardBlocked: true,
                softPenaltyScale: 0.0,
                reason: .hardBlockTimeDensity
            )
        }

        // LAYER 2: Token bucket (SOFT PENALTY)
        let hasToken = tokenBucket.tryConsume(patchId: patchId, timestamp: timestamp)
        let tokenScale: Double = hasToken ? 1.0 : Self.noTokenPenalty

        // LAYER 3: View novelty (SOFT PENALTY)
        let novelty = viewDiversity.addObservation(patchId: patchId, viewAngle: viewAngle)
        let noveltyScale: Double = novelty < Self.lowNoveltyThreshold
            ? Self.lowNoveltyPenalty
            : 1.0

        // COMPOUND PENALTY with GUARANTEED MINIMUM
        var combinedScale = tokenScale * noveltyScale

        // CRITICAL: Enforce minimum throughput
        combinedScale = max(Self.minimumSoftScale, combinedScale)

        // Determine reason
        let reason: AdmissionResult.AdmissionReason
        if !hasToken && novelty < Self.lowNoveltyThreshold {
            reason = .softPenaltyCompound
        } else if !hasToken {
            reason = .softPenaltyNoToken
        } else if novelty < Self.lowNoveltyThreshold {
            reason = .softPenaltyLowNovelty
        } else {
            reason = .allowed
        }

        return AdmissionResult(
            hardBlocked: false,
            softPenaltyScale: combinedScale,
            reason: reason
        )
    }

    /// Check for confirmed spam (HARD BLOCK)
    /// Called separately when spam detection confirms malicious behavior
    public func checkConfirmedSpam(
        patchId: String,
        spamScore: Double,
        threshold: Double = 0.95
    ) -> AdmissionResult {
        if spamScore >= threshold {
            return AdmissionResult(
                hardBlocked: true,
                softPenaltyScale: 0.0,
                reason: .hardBlockConfirmedSpam
            )
        }
        return AdmissionResult(
            hardBlocked: false,
            softPenaltyScale: 1.0,
            reason: .allowed
        )
    }
}
```

**Key Design Decisions:**
1. **ONLY ONE HARD BLOCK** in normal operation: time density (< 120ms)
2. **Token bucket is SOFT** - no token = 60% scale, not rejection
3. **Novelty is SOFT** - low novelty = 70% scale, not rejection
4. **GUARANTEED MINIMUM** - compound cannot go below 25%
5. **Confirmed spam is SEPARATE** - requires explicit detection, not auto-triggered

**File:** Replace `Core/Evidence/AdmissionController.swift`

---

## Part 2: Numerical Concerns (B1-B4)

### B1. softWriteRequiresGateMin Range Definition

**Problem:** `softWriteRequiresGateMin = 0.30` is stated without acceptable range or tuning guidance.

**Solution:** Document acceptable range with tuning scenarios

```swift
/// EvidenceConstants - softWriteRequiresGateMin definition
public enum EvidenceConstants {

    // MARK: - Soft Ledger Write Policy

    /// Minimum gate quality required to write to soft ledger
    ///
    /// SEMANTIC MEANING:
    /// Soft evidence (depth/topology/occlusion) is only meaningful when there's
    /// a stable geometric foundation (gate). This threshold defines "stable enough".
    ///
    /// VALUE ANALYSIS:
    /// - 0.20 = Too low: Writes soft evidence on unstable geometry, leads to false positives
    /// - 0.25 = Conservative: Safe for most scenes, may miss some valid soft data
    /// - 0.30 = DEFAULT: Good balance for typical indoor/outdoor scenes
    /// - 0.35 = Strict: For high-precision applications, may slow soft evidence growth
    /// - 0.40 = Too strict: Most soft evidence never written
    ///
    /// ACCEPTABLE RANGE: [0.25, 0.35]
    ///
    /// TUNING SCENARIOS:
    /// - Weak texture (blank walls): Consider 0.25 (allow more soft writes)
    /// - High precision (industrial): Consider 0.35 (stricter gate requirement)
    /// - Moving objects: Keep at 0.30 (balance between coverage and accuracy)
    ///
    /// MATHEMATICAL INTERPRETATION:
    /// 0.30 ≈ 3-4 L2+ quality observations from diverse angles
    /// This means the patch has been seen well enough to establish basic geometry.
    public static let softWriteRequiresGateMin: Double = 0.30

    /// Acceptable range for softWriteRequiresGateMin
    public static let softWriteRequiresGateMinRange: ClosedRange<Double> = 0.25...0.35
}
```

---

### B2. Frame-Rate Independent Penalty Parameters

**Problem:** Penalty multipliers assume 30fps. At 60fps, penalties apply 2x as fast.

**Solution:** Normalize all timing-dependent parameters to per-second rates

```swift
/// Frame-rate independent penalty configuration
public struct FrameRateIndependentPenalty {

    // MARK: - Reference Configuration

    /// Reference frame rate for parameter definition
    public static let referenceFrameRate: Double = 30.0

    /// Current device frame rate (set at initialization)
    public static var currentFrameRate: Double = 30.0

    /// Frame rate multiplier (reference / current)
    public static var frameRateMultiplier: Double {
        return referenceFrameRate / currentFrameRate
    }

    // MARK: - Per-Second Penalty Rates

    /// Maximum penalty per SECOND (not per frame)
    /// At 30fps: 0.01 per frame = 0.30 per second
    /// At 60fps: 0.005 per frame = 0.30 per second (same rate)
    public static let maxPenaltyPerSecond: Double = 0.30

    /// Penalty per observation (base, before frame rate adjustment)
    /// This is applied per OBSERVATION, not per frame
    public static let basePenaltyPerObservation: Double = 0.01

    /// Compute adjusted penalty for current frame rate
    /// - Parameter observations: Number of observations this frame
    /// - Returns: Total penalty for this frame
    public static func computeFramePenalty(observations: Int) -> Double {
        // Each observation contributes basePenalty
        // But total per-second penalty is capped
        let rawPenalty = Double(observations) * basePenaltyPerObservation
        let maxPerFrame = maxPenaltyPerSecond / currentFrameRate
        return min(rawPenalty, maxPerFrame)
    }

    // MARK: - Cooldown (Time-Based)

    /// Cooldown period in SECONDS (frame-rate independent)
    public static let cooldownSeconds: Double = 0.5

    /// Check if cooldown has elapsed
    public static func isCooldownElapsed(lastPenaltyTime: TimeInterval, currentTime: TimeInterval) -> Bool {
        return (currentTime - lastPenaltyTime) >= cooldownSeconds
    }

    // MARK: - Error Streak Decay

    /// Error streak decay rate per SECOND
    /// At 30fps: streak -= 0.033 per frame (1 per second)
    /// At 60fps: streak -= 0.0165 per frame (still 1 per second)
    public static let errorStreakDecayPerSecond: Double = 1.0

    /// Compute error streak decay for this frame
    public static func computeStreakDecay() -> Double {
        return errorStreakDecayPerSecond / currentFrameRate
    }
}

/// Updated PenaltyConfig using frame-rate independent calculations
public enum PenaltyConfig {

    /// Compute penalty using frame-rate independent rates
    public static func computePenalty(
        errorStreak: Int,
        lastGoodUpdate: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        // Check cooldown (time-based, frame-rate independent)
        if !FrameRateIndependentPenalty.isCooldownElapsed(
            lastPenaltyTime: lastGoodUpdate,
            currentTime: currentTime
        ) {
            return 0.0  // Still in cooldown
        }

        // Scale penalty by streak (but cap per-second rate)
        let streakMultiplier = min(3.0, 1.0 + Double(errorStreak) * 0.2)
        let basePenalty = FrameRateIndependentPenalty.basePenaltyPerObservation
        let maxPerFrame = FrameRateIndependentPenalty.maxPenaltyPerSecond / FrameRateIndependentPenalty.currentFrameRate

        return min(basePenalty * streakMultiplier, maxPerFrame)
    }
}
```

**File:** `Core/Evidence/FrameRateIndependentPenalty.swift`

---

### B3. DeltaTracker Dual Alpha for Rise/Fall

**Problem:** Single EMA alpha means both fast rises and slow falls use same smoothing. We want: fast response to increases, slow decay for decreases.

**Solution:** Asymmetric EMA with separate alphas

```swift
/// Delta tracker with asymmetric smoothing
public struct AsymmetricDeltaTracker {

    /// Raw delta (accurate, for diagnostics)
    public private(set) var raw: Double = 0.0

    /// EMA-smoothed delta (for UI animation speed)
    public private(set) var smoothed: Double = 0.0

    /// Alpha for increasing delta (fast response to gains)
    public let alphaRise: Double

    /// Alpha for decreasing delta (slow decay for losses)
    public let alphaFall: Double

    /// Initialize with default asymmetric alphas
    /// - Parameters:
    ///   - alphaRise: Response to increases (default 0.3 = fast)
    ///   - alphaFall: Response to decreases (default 0.1 = slow)
    public init(alphaRise: Double = 0.3, alphaFall: Double = 0.1) {
        self.alphaRise = alphaRise
        self.alphaFall = alphaFall
    }

    /// Update with new delta
    public mutating func update(newDelta: Double) {
        raw = newDelta

        // Choose alpha based on direction
        let alpha: Double
        if newDelta > smoothed {
            // Rising: use fast alpha
            alpha = alphaRise
        } else {
            // Falling: use slow alpha
            alpha = alphaFall
        }

        smoothed = alpha * newDelta + (1 - alpha) * smoothed
    }

    /// Reset
    public mutating func reset() {
        raw = 0.0
        smoothed = 0.0
    }
}
```

**File:** Update `Core/Evidence/DeltaTracker.swift`

---

### B4. patchWeight with View Diversity Integration

**Problem:** `patchWeight` only considers frequency cap and decay, not view diversity which is critical for evidence quality.

**Solution:** Three-factor weight computation

```swift
/// Comprehensive patch weight computation
public struct PatchWeightComputer {

    /// Compute comprehensive patch weight
    /// - Parameters:
    ///   - observationCount: Number of observations
    ///   - lastUpdate: Last update timestamp
    ///   - currentTime: Current timestamp
    ///   - viewDiversityScore: Diversity score from ViewDiversityTracker [0, 1]
    /// - Returns: Combined weight [0, 1]
    public static func computeWeight(
        observationCount: Int,
        lastUpdate: TimeInterval,
        currentTime: TimeInterval,
        viewDiversityScore: Double
    ) -> Double {
        // Factor 1: Frequency cap (anti-spam)
        let frequencyWeight = SpamProtection.frequencyWeight(observationCount: observationCount)

        // Factor 2: Confidence decay (recency)
        let decayWeight = ConfidenceDecay.aggregationWeight(
            lastUpdate: lastUpdate,
            currentTime: currentTime
        )

        // Factor 3: View diversity (coverage)
        // Low diversity = less reliable evidence
        let diversityWeight = 0.5 + 0.5 * viewDiversityScore  // Range: [0.5, 1.0]

        // Combine: multiplicative for factors that should compound
        return frequencyWeight * decayWeight * diversityWeight
    }
}

/// Update AmortizedAggregator to use comprehensive weight
extension BucketedAmortizedAggregator {

    /// Update patch with comprehensive weight
    public func updatePatchComprehensive(
        patchId: String,
        evidence: Double,
        observationCount: Int,
        lastUpdate: TimeInterval,
        viewDiversityScore: Double,
        currentTime: TimeInterval
    ) {
        let weight = PatchWeightComputer.computeWeight(
            observationCount: observationCount,
            lastUpdate: lastUpdate,
            currentTime: currentTime,
            viewDiversityScore: viewDiversityScore
        )

        updatePatch(
            patchId: patchId,
            evidence: evidence,
            baseWeight: weight,
            timestamp: currentTime
        )
    }
}
```

**File:** `Core/Evidence/PatchWeightComputer.swift`

---

## Part 3: Cross-Platform Consistency (C1-C6)

### C1. PatchId Coordinate Source Specification

**Problem:** Unclear whether screen coordinates are raw camera output or after undistortion/orientation correction.

**Solution:** Explicit coordinate pipeline definition

```swift
/// Coordinate pipeline specification for PatchId generation
///
/// PIPELINE STAGES:
/// 1. RAW: Direct from camera sensor (may have distortion, arbitrary orientation)
/// 2. UNDISTORTED: Lens distortion removed (still in sensor orientation)
/// 3. ORIENTED: Rotated to device orientation (portrait/landscape)
/// 4. NORMALIZED: Scaled to [0,1] x [0,1] with (0,0) = top-left
///
/// PR2 uses NORMALIZED coordinates for PatchId generation.
/// This ensures orientation-independence across capture sessions.
public enum PatchIdCoordinateSpec {

    /// Coordinate space used for PatchId
    public static let coordinateSpace: CoordinateSpace = .normalized

    public enum CoordinateSpace: String {
        case raw = "raw"
        case undistorted = "undistorted"
        case oriented = "oriented"
        case normalized = "normalized"  // PR2 default
    }

    /// Reference for normalization
    public static let normalizationReference: NormalizationReference = .longerEdge1920

    public enum NormalizationReference: String {
        case longerEdge1920 = "longer_edge_1920"  // PR2 default
        case fixedResolution = "fixed_1920x1080"
        case aspectRatioPreserving = "aspect_ratio"
    }
}

/// Updated CoordinateNormalizer with explicit pipeline
public struct CoordinateNormalizer {

    /// Transform raw camera point to normalized coordinate
    ///
    /// PIPELINE:
    /// 1. Apply lens undistortion (if intrinsics available)
    /// 2. Rotate to device orientation
    /// 3. Scale to [0,1] x [0,1]
    public static func normalize(
        rawPoint: CGPoint,
        frameSize: CGSize,
        orientation: UIDeviceOrientation,
        intrinsics: CameraIntrinsics? = nil
    ) -> CGPoint {
        var point = rawPoint

        // Stage 1: Undistortion (optional, if intrinsics available)
        if let intrinsics = intrinsics {
            point = undistort(point: point, intrinsics: intrinsics)
        }

        // Stage 2: Orientation correction
        point = orientationCorrect(
            point: point,
            frameSize: frameSize,
            orientation: orientation
        )

        // Stage 3: Normalization to [0,1] x [0,1]
        let normalizedX = point.x / frameSize.width
        let normalizedY = point.y / frameSize.height

        return CGPoint(
            x: normalizedX.clamped(to: 0...1),
            y: normalizedY.clamped(to: 0...1)
        )
    }

    /// Undistort point using camera intrinsics
    private static func undistort(point: CGPoint, intrinsics: CameraIntrinsics) -> CGPoint {
        // Brown-Conrady distortion model
        // For PR2, we assume Apple's ARKit already provides undistorted coordinates
        // This is a placeholder for custom camera support
        return point
    }

    /// Correct for device orientation
    /// Output: point in canonical orientation (portrait, home button at bottom)
    private static func orientationCorrect(
        point: CGPoint,
        frameSize: CGSize,
        orientation: UIDeviceOrientation
    ) -> CGPoint {
        switch orientation {
        case .portrait:
            return point  // Canonical
        case .portraitUpsideDown:
            return CGPoint(x: frameSize.width - point.x, y: frameSize.height - point.y)
        case .landscapeLeft:
            return CGPoint(x: point.y, y: frameSize.width - point.x)
        case .landscapeRight:
            return CGPoint(x: frameSize.height - point.y, y: point.x)
        default:
            return point  // Unknown, assume portrait
        }
    }
}

/// Camera intrinsics (for future custom camera support)
public struct CameraIntrinsics: Codable {
    public let fx: Double  // Focal length X
    public let fy: Double  // Focal length Y
    public let cx: Double  // Principal point X
    public let cy: Double  // Principal point Y
    public let k1: Double  // Radial distortion 1
    public let k2: Double  // Radial distortion 2
    public let p1: Double  // Tangential distortion 1
    public let p2: Double  // Tangential distortion 2
}
```

**File:** `Core/Evidence/CoordinateNormalizer.swift`

---

### C2. Timestamps as Int64 Milliseconds

**Problem:** TimeInterval (Double) has floating-point precision issues across platforms. 0.033333... may serialize differently.

**Solution:** Use Int64 milliseconds for all serialized timestamps

```swift
/// Cross-platform timestamp representation
///
/// DESIGN DECISION:
/// - Internal: Use TimeInterval (Double) for computation convenience
/// - Serialization: Use Int64 milliseconds for cross-platform consistency
///
/// RATIONALE:
/// - Double has ~15 significant digits, but serialization may round differently
/// - Int64 milliseconds has exact representation across all platforms
/// - 1ms precision is sufficient for evidence timing (120ms minimum interval)
public struct CrossPlatformTimestamp: Codable, Equatable, Hashable {

    /// Milliseconds since reference epoch
    public let milliseconds: Int64

    /// Initialize from TimeInterval
    public init(timeInterval: TimeInterval) {
        self.milliseconds = Int64((timeInterval * 1000.0).rounded())
    }

    /// Initialize from milliseconds
    public init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    /// Convert to TimeInterval
    public var timeInterval: TimeInterval {
        return TimeInterval(milliseconds) / 1000.0
    }

    /// Current time
    public static var now: CrossPlatformTimestamp {
        return CrossPlatformTimestamp(timeInterval: CACurrentMediaTime())
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.milliseconds = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(milliseconds)
    }
}

/// Update all Codable types to use CrossPlatformTimestamp
///
/// MIGRATION:
/// - Replace `timestamp: TimeInterval` with `timestamp: CrossPlatformTimestamp`
/// - Add computed property for TimeInterval access
public struct PatchEntry: Codable {

    // OLD:
    // public var lastUpdate: TimeInterval

    // NEW:
    public var lastUpdateMs: CrossPlatformTimestamp

    /// Convenience accessor
    public var lastUpdate: TimeInterval {
        get { lastUpdateMs.timeInterval }
        set { lastUpdateMs = CrossPlatformTimestamp(timeInterval: newValue) }
    }
}
```

**File:** `Core/Evidence/CrossPlatformTimestamp.swift`

---

### C3. Float Quantization Scope Definition

**Problem:** Which floats to quantize? Timestamps, evidence values, counts?

**Solution:** Explicit quantization policy

```swift
/// Float quantization policy
///
/// QUANTIZED (4 decimal places):
/// - Evidence values (0.0 to 1.0)
/// - Quality scores
/// - Weights
/// - Delta values
///
/// NOT QUANTIZED:
/// - Timestamps (use Int64 milliseconds instead)
/// - Integer counts (observationCount, errorStreak)
/// - Version strings
/// - PatchId strings
public enum QuantizationPolicy {

    /// Fields that should be quantized
    public static let quantizedFields: Set<String> = [
        "evidence",
        "gateEvidence",
        "softEvidence",
        "quality",
        "gateQuality",
        "softQuality",
        "weight",
        "delta",
        "smoothedDelta",
        "rawDelta",
        "totalEvidence",
        "gateDisplay",
        "softDisplay",
        "totalDisplay",
    ]

    /// Check if field should be quantized
    public static func shouldQuantize(fieldName: String) -> Bool {
        return quantizedFields.contains(fieldName)
    }

    /// Quantize value to fixed precision
    public static func quantize(_ value: Double, precision: Int = 4) -> Double {
        let multiplier = pow(10.0, Double(precision))
        return (value * multiplier).rounded() / multiplier
    }
}

/// Updated encoder with explicit quantization scope
extension TrueDeterministicJSONEncoder {

    /// Convert to stable JSON string with selective quantization
    private static func toStableJSONString(
        _ value: Any,
        fieldName: String? = nil
    ) -> String {
        switch value {
        case let double as Double:
            if let name = fieldName, QuantizationPolicy.shouldQuantize(fieldName: name) {
                return formatQuantizedDouble(double)
            } else {
                // Non-quantized double: use full precision
                return "\(double)"
            }
        // ... rest unchanged
        }
    }
}
```

**File:** Update `Core/Evidence/QuantizationPolicy.swift`

---

### C4. Codable Enum Unknown Value Handling

**Problem:** If new ObservationVerdict case added in future version, old decoder will crash.

**Solution:** Unknown value handling strategy

```swift
/// Forward-compatible enum decoding
///
/// STRATEGY: Unknown values decode to safe default, log warning
public enum ObservationVerdict: String, Codable, Sendable {
    case good
    case suspect
    case bad

    /// Unknown value placeholder (not serializable)
    case unknown

    // MARK: - Codable with Forward Compatibility

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        if let verdict = ObservationVerdict(rawValue: rawValue) {
            self = verdict
        } else {
            // Unknown value: default to suspect (safe choice)
            // Log warning for debugging
            EvidenceLogger.warn("Unknown ObservationVerdict: '\(rawValue)', defaulting to .suspect")
            self = .suspect
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Never encode .unknown
        guard self != .unknown else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Cannot encode .unknown verdict"))
        }

        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// Apply same pattern to all enums
public enum ColorState: String, Codable, Sendable {
    case black
    case gray
    case white
    case originalColor

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        if let state = ColorState(rawValue: rawValue) {
            self = state
        } else {
            EvidenceLogger.warn("Unknown ColorState: '\(rawValue)', defaulting to .black")
            self = .black  // Safe default
        }
    }
}
```

**File:** Update enum definitions

---

### C5. Dictionary Iteration Order in Tests

**Problem:** Tests may pass on one platform and fail on another due to dictionary iteration order.

**Solution:** Sort-based test assertions

```swift
/// Test utilities for cross-platform consistency
public enum CrossPlatformTestUtils {

    /// Compare dictionaries with deterministic ordering
    public static func assertDictionariesEqual<K: Comparable, V: Equatable>(
        _ dict1: [K: V],
        _ dict2: [K: V],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let keys1 = dict1.keys.sorted()
        let keys2 = dict2.keys.sorted()

        XCTAssertEqual(keys1, keys2, "Keys mismatch", file: file, line: line)

        for key in keys1 {
            XCTAssertEqual(dict1[key], dict2[key], "Value mismatch for key \(key)", file: file, line: line)
        }
    }

    /// Assert JSON encoding is deterministic
    public static func assertDeterministicJSON<T: Encodable>(
        _ value: T,
        iterations: Int = 100,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        var outputs: Set<Data> = []

        for _ in 0..<iterations {
            let data = try! TrueDeterministicJSONEncoder.encode(value)
            outputs.insert(data)
        }

        XCTAssertEqual(
            outputs.count, 1,
            "JSON encoding produced \(outputs.count) different outputs",
            file: file, line: line
        )
    }

    /// Assert patch order in array (for tests that iterate)
    public static func sortedPatches(_ patches: [String: PatchEntry]) -> [(String, PatchEntry)] {
        return patches.sorted { $0.key < $1.key }
    }
}
```

**File:** `Tests/Evidence/CrossPlatformTestUtils.swift`

---

### C6. Thread Model Specification

**Problem:** No explicit thread model defined. Race conditions may cause non-determinism.

**Solution:** Explicit actor-based concurrency model

```swift
/// Evidence system thread model
///
/// ACTORS:
/// 1. EvidenceActor - owns all mutable state, single writer
/// 2. ReaderSnapshot - immutable snapshots for reading
///
/// INVARIANTS:
/// - All mutations go through EvidenceActor
/// - Readers receive immutable snapshots
/// - No shared mutable state
@globalActor
public actor EvidenceActor {
    public static let shared = EvidenceActor()

    private init() {}
}

/// Evidence engine with actor isolation
@EvidenceActor
public final class IsolatedEvidenceEngine {

    private var splitLedger: SplitLedger
    private var gateDisplay: Double = 0.0
    private var softDisplay: Double = 0.0
    private var aggregator: BucketedAmortizedAggregator

    public init() {
        self.splitLedger = SplitLedger()
        self.aggregator = BucketedAmortizedAggregator()
    }

    /// Process observation (isolated to actor)
    public func processObservation(
        _ observation: Observation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict
    ) {
        // All mutations happen here, on actor
        splitLedger.update(
            observation: observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict
        )

        // Update displays...
    }

    /// Get immutable snapshot for reading
    public func snapshot() -> EvidenceSnapshot {
        return EvidenceSnapshot(
            gateDisplay: gateDisplay,
            softDisplay: softDisplay,
            totalEvidence: aggregator.totalEvidence
        )
    }
}

/// Immutable snapshot for cross-thread reading
public struct EvidenceSnapshot: Sendable {
    public let gateDisplay: Double
    public let softDisplay: Double
    public let totalEvidence: Double

    // Add other read-only properties as needed
}

/// Usage pattern
func exampleUsage() async {
    let engine = await IsolatedEvidenceEngine()

    // Write (on actor)
    await engine.processObservation(observation, gateQuality: 0.8, softQuality: 0.6, verdict: .good)

    // Read (get snapshot)
    let snapshot = await engine.snapshot()
    print("Total: \(snapshot.totalEvidence)")
}
```

**File:** `Core/Evidence/IsolatedEvidenceEngine.swift`

---

## Part 4: Governance Improvements (D1-D3)

### D1. BehaviorLockTests with CI Gate and Golden Fixtures

**Problem:** Behavior lock tests exist but lack CI integration and golden file comparison.

**Solution:** Golden fixture-based regression testing

```swift
/// Golden fixture testing for behavior lock
///
/// CONCEPT:
/// - Store "golden" (known-good) outputs in test fixtures
/// - Compare current output against golden
/// - Fail CI if mismatch detected
/// - Update golden only after explicit human review
public final class GoldenFixtureTests: XCTestCase {

    /// Path to golden fixtures
    static let goldenFixturePath = "Tests/Evidence/Fixtures/Golden/"

    // MARK: - Deterministic JSON Test

    func testDeterministicJSON_GoldenFixture() throws {
        // Create standardized test state
        let state = GoldenFixtureTests.createStandardTestState()

        // Encode with deterministic encoder
        let encoded = try TrueDeterministicJSONEncoder.encode(state)

        // Load golden fixture
        let goldenPath = Self.goldenFixturePath + "evidence_state_v2.1.json"
        let goldenData = try Data(contentsOf: URL(fileURLWithPath: goldenPath))

        // Compare byte-for-byte
        XCTAssertEqual(
            encoded, goldenData,
            "Deterministic JSON output differs from golden fixture. " +
            "If this is intentional, update the golden fixture after review."
        )
    }

    // MARK: - Evidence Progression Test

    func testEvidenceProgression_GoldenFixture() throws {
        // Create engine and process standard sequence
        let engine = IsolatedEvidenceEngine()
        let observations = GoldenFixtureTests.createStandardObservationSequence()

        var snapshots: [EvidenceSnapshot] = []

        for (obs, gateQ, softQ, verdict) in observations {
            engine.processObservation(obs, gateQuality: gateQ, softQuality: softQ, verdict: verdict)
            snapshots.append(engine.snapshot())
        }

        // Load golden progression
        let goldenPath = Self.goldenFixturePath + "progression_standard.json"
        let goldenData = try Data(contentsOf: URL(fileURLWithPath: goldenPath))
        let goldenSnapshots = try JSONDecoder().decode([EvidenceSnapshot].self, from: goldenData)

        // Compare with tolerance
        XCTAssertEqual(snapshots.count, goldenSnapshots.count)

        for (i, (actual, expected)) in zip(snapshots, goldenSnapshots).enumerated() {
            XCTAssertEqual(
                actual.gateDisplay, expected.gateDisplay,
                accuracy: 0.0001,
                "Frame \(i): gateDisplay mismatch"
            )
            XCTAssertEqual(
                actual.softDisplay, expected.softDisplay,
                accuracy: 0.0001,
                "Frame \(i): softDisplay mismatch"
            )
        }
    }

    // MARK: - Test Data Generators

    static func createStandardTestState() -> EvidenceState {
        // Returns identical state every time
        // Used for deterministic JSON testing
        var state = EvidenceState()
        state.schemaVersion = "2.1"
        state.gateDisplay = 0.5
        state.softDisplay = 0.4
        state.totalDisplay = 0.45
        // ... fill with standard test data
        return state
    }

    static func createStandardObservationSequence() -> [(Observation, Double, Double, ObservationVerdict)] {
        // Returns identical sequence every time
        // Used for progression testing
        var sequence: [(Observation, Double, Double, ObservationVerdict)] = []

        for i in 0..<100 {
            let obs = Observation(
                patchId: "patch_\(i % 10)",
                timestamp: Double(i) * 0.033,
                frameId: "frame_\(i)"
            )
            let gateQ = 0.3 + Double(i) / 200.0
            let softQ = gateQ * 0.9
            let verdict: ObservationVerdict = i % 20 == 19 ? .suspect : .good

            sequence.append((obs, gateQ, softQ, verdict))
        }

        return sequence
    }
}
```

**CI Integration (GitHub Actions):**

```yaml
# .github/workflows/evidence-tests.yml
name: Evidence System Tests

on:
  push:
    paths:
      - 'Core/Evidence/**'
      - 'Tests/Evidence/**'
  pull_request:
    paths:
      - 'Core/Evidence/**'
      - 'Tests/Evidence/**'

jobs:
  behavior-lock-tests:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: swift build

      - name: Run Behavior Lock Tests
        run: swift test --filter "GoldenFixtureTests"

      - name: Run Deterministic Encoding Tests
        run: swift test --filter "DeterministicEncodingTests"

      - name: Fail on Golden Mismatch
        if: failure()
        run: |
          echo "::error::Behavior lock test failed. Golden fixture mismatch detected."
          echo "::error::If this change is intentional, update golden fixtures with:"
          echo "::error::  swift test --filter UpdateGoldenFixtures"
          exit 1
```

**File:** `Tests/Evidence/GoldenFixtureTests.swift`, `.github/workflows/evidence-tests.yml`

---

### D2. Lint Tests for Forbidden Patterns

**Problem:** Forbidden patterns may slip through code review.

**Solution:** Automated lint as CI gate

```swift
/// Forbidden pattern lint tests
public final class ForbiddenPatternLintTests: XCTestCase {

    /// All Swift files in Core/Evidence
    static let sourceFiles: [URL] = {
        let evidencePath = URL(fileURLWithPath: "Core/Evidence")
        let enumerator = FileManager.default.enumerator(
            at: evidencePath,
            includingPropertiesForKeys: nil
        )

        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }()

    /// Forbidden patterns (regex)
    static let forbiddenPatterns: [(pattern: String, message: String)] = [
        ("max\\s*\\(\\s*gate.*soft", "Use SplitLedger with separate updates"),
        ("max\\s*\\(\\s*soft.*gate", "Use SplitLedger with separate updates"),
        ("ledgerQuality\\s*=\\s*max", "Use separate gateQuality/softQuality"),
        ("observation\\.quality", "Use explicit gateQuality/softQuality parameters"),
        ("isErroneous:\\s*Bool", "Use verdict: ObservationVerdict"),
        ("\\[String:\\s*Any\\]", "Use Codable types for serialization"),
        ("for.*in.*patches.*\\{.*evidence.*\\*.*weight", "Use AmortizedAggregator"),
        ("minDelta|min.*Delta", "Delta should be exact, no padding"),
    ]

    func testNoForbiddenPatterns() throws {
        var violations: [(file: String, pattern: String, message: String, line: Int)] = []

        for fileURL in Self.sourceFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (pattern, message) in Self.forbiddenPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }

                for (lineNum, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        violations.append((
                            file: fileURL.lastPathComponent,
                            pattern: pattern,
                            message: message,
                            line: lineNum + 1
                        ))
                    }
                }
            }
        }

        if !violations.isEmpty {
            var errorMessage = "Forbidden patterns detected:\n\n"
            for v in violations {
                errorMessage += "\(v.file):\(v.line) - Pattern '\(v.pattern)'\n"
                errorMessage += "  Fix: \(v.message)\n\n"
            }
            XCTFail(errorMessage)
        }
    }
}
```

**File:** `Tests/Evidence/ForbiddenPatternLintTests.swift`

---

### D3. HealthMonitor Red-Line Strategies

**Problem:** EvidenceHealthMonitor computes metrics but has no defined response to unhealthy states.

**Solution:** Red-line thresholds with automatic recovery strategies

```swift
/// Health monitor with red-line strategies
public final class HealthMonitorWithStrategies {

    // MARK: - Red Line Thresholds

    public struct RedLineThresholds {
        /// Maximum stalled ratio before intervention
        public static let maxStalledRatio: Double = 0.3

        /// Maximum average age before intervention
        public static let maxAverageAgeSec: Double = 120.0

        /// Minimum delta before intervention
        public static let minAverageDelta: Double = 0.0001

        /// Minimum health score
        public static let minHealthScore: Double = 0.5
    }

    // MARK: - Recovery Strategies

    public enum RecoveryStrategy: String {
        /// No action needed
        case none

        /// Suggest user move to different angle
        case suggestViewChange

        /// Boost weights for stalled patches
        case boostStalledPatches

        /// Reset decay timers
        case resetDecayTimers

        /// Full recalibration
        case recalibrate

        /// Alert for investigation
        case alert
    }

    // MARK: - Health Check

    public struct HealthCheckResult {
        public let metrics: EvidenceHealthMetrics
        public let isHealthy: Bool
        public let strategies: [RecoveryStrategy]
        public let alerts: [String]
    }

    private let engine: IsolatedEvidenceEngine

    public init(engine: IsolatedEvidenceEngine) {
        self.engine = engine
    }

    /// Compute health and recommend strategies
    public func checkHealth(currentTime: TimeInterval) async -> HealthCheckResult {
        let metrics = await computeMetrics(currentTime: currentTime)
        var strategies: [RecoveryStrategy] = []
        var alerts: [String] = []

        // Check stalled ratio
        if metrics.stalledRatio > RedLineThresholds.maxStalledRatio {
            strategies.append(.suggestViewChange)
            if metrics.stalledRatio > 0.5 {
                strategies.append(.boostStalledPatches)
            }
            alerts.append("High stalled ratio: \(String(format: "%.1f%%", metrics.stalledRatio * 100))")
        }

        // Check average age
        if metrics.averageAge > RedLineThresholds.maxAverageAgeSec {
            strategies.append(.resetDecayTimers)
            alerts.append("High average age: \(String(format: "%.0fs", metrics.averageAge))")
        }

        // Check delta
        if metrics.averageDelta < RedLineThresholds.minAverageDelta && metrics.lockedRatio < 0.8 {
            strategies.append(.recalibrate)
            alerts.append("Progress stalled: delta = \(String(format: "%.6f", metrics.averageDelta))")
        }

        // Check overall health
        let isHealthy = metrics.healthScore >= RedLineThresholds.minHealthScore

        if !isHealthy && strategies.isEmpty {
            strategies.append(.alert)
            alerts.append("Low health score: \(String(format: "%.2f", metrics.healthScore))")
        }

        return HealthCheckResult(
            metrics: metrics,
            isHealthy: isHealthy,
            strategies: strategies.isEmpty ? [.none] : strategies,
            alerts: alerts
        )
    }

    /// Execute recovery strategy
    public func executeStrategy(_ strategy: RecoveryStrategy) async {
        switch strategy {
        case .none:
            break

        case .suggestViewChange:
            // Emit UI notification
            NotificationCenter.default.post(
                name: .evidenceSuggestViewChange,
                object: nil
            )

        case .boostStalledPatches:
            // Temporarily increase weights for stalled patches
            await engine.boostStalledPatches(multiplier: 1.5, duration: 10.0)

        case .resetDecayTimers:
            // Reset decay timers to give stale patches another chance
            await engine.resetDecayTimers()

        case .recalibrate:
            // Full recalibration
            await engine.recalibrate()

        case .alert:
            // Log for investigation
            EvidenceLogger.error("Evidence system unhealthy, manual investigation required")
        }
    }

    private func computeMetrics(currentTime: TimeInterval) async -> EvidenceHealthMetrics {
        // Implementation...
        return EvidenceHealthMetrics(
            colorDistribution: [:],
            averageAge: 0,
            lockedRatio: 0,
            averageDelta: 0,
            stalledRatio: 0
        )
    }
}

// Notification name
extension Notification.Name {
    static let evidenceSuggestViewChange = Notification.Name("EvidenceSuggestViewChange")
}
```

**File:** `Core/Evidence/HealthMonitorWithStrategies.swift`

---

## Part 5: Additional Hardening

### 5.1 Evidence Value Range Enforcement

**Problem:** Evidence values should always be in [0, 1] but no runtime enforcement exists.

**Solution:** Clamped evidence type

```swift
/// Clamped evidence value (always in [0, 1])
@propertyWrapper
public struct ClampedEvidence: Codable, Equatable, Hashable {
    private var _value: Double

    public var wrappedValue: Double {
        get { _value }
        set { _value = newValue.clamped(to: 0...1) }
    }

    public init(wrappedValue: Double) {
        self._value = wrappedValue.clamped(to: 0...1)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Double.self)
        self._value = raw.clamped(to: 0...1)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(_value)
    }
}

/// Usage in PatchEntry
public struct PatchEntry: Codable {
    @ClampedEvidence public var evidence: Double = 0.0
    // ...
}
```

---

### 5.2 Observation Sequence Number

**Problem:** Observations may arrive out of order; no mechanism to detect or handle.

**Solution:** Monotonic sequence numbers

```swift
/// Observation with sequence number for ordering
public struct SequencedObservation {
    public let observation: Observation
    public let sequenceNumber: UInt64

    /// Global sequence counter (atomic)
    private static var _counter: UInt64 = 0
    private static let _lock = NSLock()

    /// Generate next sequence number
    public static func nextSequenceNumber() -> UInt64 {
        _lock.lock()
        defer { _lock.unlock() }
        _counter += 1
        return _counter
    }
}

/// Observation reordering buffer
public final class ObservationReorderBuffer {

    /// Buffer size
    public static let bufferSize: Int = 16

    /// Expected next sequence number
    private var expectedNext: UInt64 = 1

    /// Buffered observations
    private var buffer: [UInt64: SequencedObservation] = [:]

    /// Add observation, return in-order observations
    public func add(_ observation: SequencedObservation) -> [SequencedObservation] {
        buffer[observation.sequenceNumber] = observation

        var result: [SequencedObservation] = []

        // Emit in-order observations
        while let next = buffer.removeValue(forKey: expectedNext) {
            result.append(next)
            expectedNext += 1
        }

        // If buffer too full, skip missing observations
        if buffer.count > Self.bufferSize {
            if let minKey = buffer.keys.min() {
                expectedNext = minKey
                while let next = buffer.removeValue(forKey: expectedNext) {
                    result.append(next)
                    expectedNext += 1
                }
            }
        }

        return result
    }
}
```

---

### 5.3 Graceful Degradation Under Memory Pressure

**Problem:** No handling for memory pressure situations.

**Solution:** Memory-aware patch management

```swift
/// Memory pressure handler for evidence system
public final class MemoryPressureHandler {

    /// Maximum patch count before pruning
    public static let maxPatchCount: Int = 10000

    /// Patches to keep on prune
    public static let keepPatchCount: Int = 5000

    /// Handle memory pressure
    public static func handleMemoryPressure(ledger: inout SplitLedger, aggregator: inout BucketedAmortizedAggregator) {
        let patchCount = ledger.gateLedger.patchCount

        if patchCount > maxPatchCount {
            // Prune oldest, lowest-evidence patches
            ledger.prunePatches(keepCount: keepPatchCount, strategy: .lowestEvidence)

            // Recalibrate aggregator
            let patches = ledger.allPatches()
            aggregator.recalibrate(patches: patches, currentTime: CACurrentMediaTime())

            EvidenceLogger.warn("Pruned patches due to memory pressure: \(patchCount) -> \(keepPatchCount)")
        }
    }
}
```

---

## Part 6: Updated File Structure (Final V4)

```
Core/Evidence/
├── Observation.swift
├── ObservationVerdict.swift                # UPDATED (C4)
├── VerdictPipeline.swift
├── PenaltyConfig.swift
├── FrameRateIndependentPenalty.swift       # NEW (B2)
├── PatchEvidenceMap.swift
├── SplitLedger.swift
├── PatchDisplayMap.swift
├── DeltaTracker.swift                      # UPDATED (B3) - Asymmetric
├── AsymmetricDeltaTracker.swift            # NEW (B3)
├── UnifiedAdmissionController.swift        # NEW (A4) - Replaces AdmissionController
├── SpamProtection.swift
├── TokenBucketLimiter.swift
├── AnomalyQuarantine.swift
├── RobustStatistics.swift
├── EvidenceLocking.swift
├── ViewDiversityTracker.swift
├── ConfidenceDecay.swift
├── PatchIdStrategy.swift
├── CoordinateNormalizer.swift              # NEW (C1)
├── TrueDeterministicJSONEncoder.swift      # NEW (A2) - Replaces DeterministicJSONEncoder
├── CrossPlatformTimestamp.swift            # NEW (C2)
├── QuantizationPolicy.swift                # NEW (C3)
├── BucketedAmortizedAggregator.swift       # NEW (A3) - Replaces AmortizedAggregator
├── PatchWeightComputer.swift               # NEW (B4)
├── EvidenceHealthMonitor.swift
├── HealthMonitorWithStrategies.swift       # NEW (D3)
├── EvidenceSnapshotDiff.swift
├── EvidenceBudget.swift
├── SpatialConsistency.swift
├── SafePointManager.swift
├── EvidenceProvenance.swift
├── DynamicThresholds.swift
├── ObservationBatch.swift
├── PerformanceBudget.swift
├── EvidenceProfiler.swift
├── IsolatedEvidenceEngine.swift            # NEW (C6)
├── EvidenceLayers.swift
├── EvidenceEngine.swift
├── ColorMapping.swift
├── DynamicWeights.swift
├── MetricSmoother.swift
├── EvidenceState.swift
├── EvidenceError.swift
├── EvidenceLogger.swift                    # NEW
├── ClampedEvidence.swift                   # NEW (5.1)
├── ObservationReorderBuffer.swift          # NEW (5.2)
└── MemoryPressureHandler.swift             # NEW (5.3)

Core/Constants/
└── EvidenceConstants.swift                 # UPDATED

Scripts/
└── ForbiddenPatternLint.swift              # NEW (A1)

Tests/Evidence/
├── ... existing tests ...
├── GoldenFixtureTests.swift                # NEW (D1)
├── ForbiddenPatternLintTests.swift         # NEW (D2)
├── CrossPlatformTestUtils.swift            # NEW (C5)
├── TrueDeterministicEncodingTests.swift    # NEW (A2)
├── BucketedAggregatorTests.swift           # NEW (A3)
├── UnifiedAdmissionTests.swift             # NEW (A4)
└── Fixtures/Golden/                        # NEW (D1)
    ├── evidence_state_v2.1.json
    └── progression_standard.json

.github/workflows/
└── evidence-tests.yml                      # NEW (D1)
```

---

## Part 7: Implementation Order (V4)

```
Phase 1: Hard Issues (MUST DO FIRST)
1. A1 - ForbiddenPatternLint + search-and-destroy
2. A2 - TrueDeterministicJSONEncoder
3. A3 - BucketedAmortizedAggregator
4. A4 - UnifiedAdmissionController

Phase 2: Cross-Platform Consistency
5. C1 - CoordinateNormalizer
6. C2 - CrossPlatformTimestamp
7. C3 - QuantizationPolicy
8. C4 - Enum unknown value handling
9. C5 - CrossPlatformTestUtils
10. C6 - IsolatedEvidenceEngine

Phase 3: Numerical Refinements
11. B1 - softWriteRequiresGateMin documentation
12. B2 - FrameRateIndependentPenalty
13. B3 - AsymmetricDeltaTracker
14. B4 - PatchWeightComputer

Phase 4: Governance
15. D1 - GoldenFixtureTests + CI integration
16. D2 - ForbiddenPatternLintTests
17. D3 - HealthMonitorWithStrategies

Phase 5: Additional Hardening
18. 5.1 - ClampedEvidence
19. 5.2 - ObservationReorderBuffer
20. 5.3 - MemoryPressureHandler

Phase 6: Final Verification
21. Run all golden fixture tests
22. Run forbidden pattern lint
23. Run deterministic encoding tests (1000 iterations)
24. Run cross-platform consistency tests
25. Verify CI pipeline passes
```

---

## Part 8: Migration Checklist

```
[ ] All max(gate, soft) patterns removed (grep returns 0 results)
[ ] DeterministicJSONEncoder replaced with TrueDeterministicJSONEncoder
[ ] AmortizedAggregator replaced with BucketedAmortizedAggregator
[ ] AdmissionController replaced with UnifiedAdmissionController
[ ] All TimeInterval fields in Codable types use CrossPlatformTimestamp
[ ] All enums have unknown value handling
[ ] Golden fixtures created and committed
[ ] CI pipeline configured and passing
[ ] Lint tests passing
[ ] Memory pressure handling tested
[ ] Actor isolation verified (no shared mutable state)
```

---

**Document Version:** Patch V4
**Author:** Claude Code
**Last Updated:** 2026-01-29
**Changelog:**
- A1-A4: Hard issue fixes
- B1-B4: Numerical refinements
- C1-C6: Cross-platform consistency
- D1-D3: Governance improvements
- 5.1-5.3: Additional hardening
