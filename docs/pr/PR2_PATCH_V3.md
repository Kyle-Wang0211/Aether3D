# PR2 Evidence System - Patch V3 (Final Hardening + Legacy Cleanup)

**Document Version:** Patch V3
**Status:** MANDATORY SUPPLEMENT TO PR2_DETAILED_PROMPT_EN.md AND PR2_PATCH_V2.md
**Created:** 2026-01-29
**Purpose:** Final hardening, legacy cleanup, and additional robustness enhancements

---

## Overview

This patch addresses:
1. **10 Critical Hardening Points** identified in Patch V2 review
2. **10 Additional Enhancements** for industrial-grade robustness
3. **Legacy Code Cleanup** protocol to ensure clean migration

**IMPORTANT:** This patch must be applied AFTER PR2_PATCH_V2.md. It does NOT replace V2, it supplements it.

---

## Part 1: Critical Hardening Points (MUST IMPLEMENT)

### 1.1 Verdict Pipeline Clarification

**Problem:** Multiple components (Engine, Map, Quarantine, RobustStatistics) can influence verdict, causing conflicts.

**Solution:** Single-writer verdict pipeline

```swift
/// Verdict pipeline - ONLY AnomalyQuarantine can upgrade/downgrade verdict
///
/// Pipeline stages:
/// 1. VerdictClassifier (stub in PR2) -> initial verdict
/// 2. AnomalyQuarantine -> may upgrade suspect->bad (temporal)
/// 3. RobustStatistics -> only affects effectiveQuality (continuous), NOT verdict
/// 4. PenaltyConfig -> consumes verdict (discrete) to compute penalty
///
/// INVARIANT: Only AnomalyQuarantine.process() can change verdict
public final class VerdictPipeline {

    private let quarantine: AnomalyQuarantine

    public init(quarantine: AnomalyQuarantine) {
        self.quarantine = quarantine
    }

    /// Process raw signal through pipeline
    /// Returns final verdict and effective quality
    public func process(
        patchId: String,
        rawVerdict: ObservationVerdict,
        rawQuality: Double,
        currentEvidence: Double,
        timestamp: TimeInterval
    ) -> (verdict: ObservationVerdict, effectiveQuality: Double) {

        // Step 1: Quarantine may upgrade suspect -> bad
        let finalVerdict = quarantine.process(
            patchId: patchId,
            rawVerdict: rawVerdict,
            timestamp: timestamp
        )

        // Step 2: RobustStatistics adjusts quality (NOT verdict)
        let robustQuality = RobustStatistics.robustQuality(
            rawQuality: rawQuality,
            currentEvidence: currentEvidence
        )

        return (finalVerdict, robustQuality)
    }
}
```

**Rule:** NO component except `AnomalyQuarantine.process()` may change a verdict from one state to another.

**File:** `Core/Evidence/VerdictPipeline.swift`

---

### 1.2 Remove max(gate, soft) from Rule A Examples

**Problem:** Old Rule A example shows `ledgerQuality = max(gateQuality, softQuality)` which conflicts with SplitLedger.

**Solution:** Update ALL documentation and code to use separate ledger updates

```swift
// ❌ FORBIDDEN - DO NOT USE THIS PATTERN ANYWHERE
let ledgerQuality = max(gateQuality, softQuality)
ledger.update(ledgerQuality: ledgerQuality)

// ✅ CORRECT - Separate ledger updates
splitLedger.gateLedger.update(
    patchId: patchId,
    ledgerQuality: gateQuality,  // Only gateQuality
    verdict: verdict,
    frameId: frameId,
    timestamp: timestamp
)

// Soft ledger has additional gate threshold requirement
if gateQuality > EvidenceConstants.softWriteRequiresGateMin {
    splitLedger.softLedger.update(
        patchId: patchId,
        ledgerQuality: softQuality,  // Only softQuality
        verdict: verdict,
        frameId: frameId,
        timestamp: timestamp
    )
}
```

**Cursor Instruction:** Search for ANY occurrence of `max(gateQuality, softQuality)` or `max(gate, soft)` and DELETE IT.

---

### 1.3 SSOT Soft Write Gate Threshold

**Problem:** `gateQuality > 0.3` for soft ledger write is magic number without rationale.

**Solution:** Add to EvidenceConstants with documentation

```swift
/// EvidenceConstants additions
public enum EvidenceConstants {
    // ... existing ...

    // MARK: - Soft Ledger Write Policy

    /// Minimum gate quality required to write to soft ledger
    ///
    /// RATIONALE: Soft evidence (depth/topology/occlusion) is only meaningful
    /// when there's a stable geometric foundation (gate). Writing soft evidence
    /// without gate foundation leads to "false quality" - the system thinks
    /// quality is good but the base geometry is unstable.
    ///
    /// 0.30 = approximately 3 L2+ views with decent geometry
    public static let softWriteRequiresGateMin: Double = 0.30

    /// This is a SEMANTIC constraint, not a performance optimization.
    /// Do not change without RFC.
}
```

**File:** Update `Core/Constants/EvidenceConstants.swift`

---

### 1.4 PatchDisplay EMA and Locking Strategy

**Problem:** patchDisplay growth source unclear, may cause UI jitter.

**Solution:** Explicit EMA pipeline with locking acceleration

```swift
/// PatchDisplayMap update policy
public final class PatchDisplayMap {

    // ... existing ...

    /// EMA alpha for patch display (more responsive than global)
    public static let patchDisplayEmaAlpha: Double = 0.2

    /// Locked patch display acceleration factor
    public static let lockedPatchAcceleration: Double = 1.5

    /// Update patch display (monotonic, EMA-smoothed)
    public func update(
        patchId: String,
        ledgerEvidence: Double,  // From SplitLedger.patchEvidence (fused)
        isLocked: Bool,
        timestamp: TimeInterval
    ) {
        var entry = patches[patchId] ?? DisplayEntry()

        // EMA smoothing
        let alpha = isLocked
            ? Self.patchDisplayEmaAlpha * Self.lockedPatchAcceleration
            : Self.patchDisplayEmaAlpha

        let smoothed = alpha * ledgerEvidence + (1 - alpha) * entry.evidence

        // Monotonic: only increase
        entry.evidence = max(entry.evidence, smoothed)
        entry.lastUpdate = timestamp

        patches[patchId] = entry
    }
}
```

**Key Points:**
- patchDisplay eats EMA of `splitLedger.patchEvidence()` (already fused)
- Locked patches get 1.5x EMA alpha (faster convergence to true value)
- Still monotonic (never decreases)

---

### 1.5 UpdateAdmission Combiner

**Problem:** SpamProtection + TokenBucket + Novelty may over-reject, causing black holes.

**Solution:** Unified admission decision with tiered response

```swift
/// Unified update admission decision
public struct UpdateAdmission: Sendable {

    /// Whether update is allowed at all
    public let allowed: Bool

    /// Quality scale factor [0, 1] - applied even if allowed
    public let qualityScale: Double

    /// Reason for decision (debug only)
    public let reason: AdmissionReason

    public enum AdmissionReason: String, Sendable {
        case allowed
        case rateLimited           // TokenBucket empty
        case timeDensityBlocked    // Too fast (< 120ms)
        case lowNovelty            // Same view angle
    }
}

/// Admission controller - single decision point
public final class AdmissionController {

    private let spamProtection: SpamProtection
    private let tokenBucket: TokenBucketLimiter
    private let viewDiversity: ViewDiversityTracker

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
    ) -> UpdateAdmission {

        // Layer 1: Time density (hard block)
        if !spamProtection.shouldAllowUpdate(patchId: patchId, timestamp: timestamp) {
            return UpdateAdmission(
                allowed: false,
                qualityScale: 0.0,
                reason: .timeDensityBlocked
            )
        }

        // Layer 2: Token bucket (soft - affects quality scale, not hard block)
        let hasToken = tokenBucket.tryConsume(patchId: patchId, timestamp: timestamp)
        let tokenScale: Double = hasToken ? 1.0 : 0.5  // No token = 50% quality

        // Layer 3: Novelty (affects quality scale)
        let novelty = viewDiversity.addObservation(patchId: patchId, viewAngle: viewAngle)
        let noveltyScale = max(EvidenceConstants.minNoveltyForLedger, novelty)

        // Combined scale
        let finalScale = tokenScale * noveltyScale

        // Determine if effectively blocked
        if finalScale < EvidenceConstants.minNoveltyForLedger {
            return UpdateAdmission(
                allowed: false,
                qualityScale: 0.0,
                reason: .lowNovelty
            )
        }

        return UpdateAdmission(
            allowed: true,
            qualityScale: finalScale,
            reason: hasToken ? .allowed : .rateLimited
        )
    }
}
```

**Key Design:**
- Time density: HARD block (returns immediately)
- Token bucket: SOFT penalty (reduces quality, doesn't block)
- Novelty: SOFT penalty (reduces quality, doesn't block)
- Combined scale must exceed minimum to proceed

**File:** `Core/Evidence/AdmissionController.swift`

---

### 1.6 ConfidenceDecay Affects Weight Only

**Problem:** Decay might modify `entry.evidence` which breaks audit trail.

**Solution:** Explicit separation - decay only affects aggregation weight

```swift
/// Confidence decay - ONLY affects aggregation weight, NEVER modifies evidence
public enum ConfidenceDecay {

    public static let halfLifeSec: Double = 60.0

    /// Compute WEIGHT for aggregation (NOT evidence value)
    ///
    /// INVARIANT: This function NEVER modifies PatchEntry.evidence
    /// It only returns a weight to be used in totalEvidence() computation
    public static func aggregationWeight(
        lastUpdate: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        let age = currentTime - lastUpdate
        return exp(-0.693 * age / halfLifeSec)
    }
}

// In PatchEvidenceMap.totalEvidence():
public func totalEvidence(currentTime: TimeInterval) -> Double {
    guard !patches.isEmpty else { return 0.0 }

    var weightedSum: Double = 0.0
    var totalWeight: Double = 0.0

    for (_, entry) in patches {
        // Frequency weight (anti-spam)
        let freqWeight = SpamProtection.frequencyWeight(observationCount: entry.observationCount)

        // Decay weight (age penalty) - DOES NOT MODIFY entry.evidence
        let decayWeight = ConfidenceDecay.aggregationWeight(
            lastUpdate: entry.lastUpdate,
            currentTime: currentTime
        )

        let combinedWeight = freqWeight * decayWeight

        // entry.evidence is NEVER modified here
        weightedSum += entry.evidence * combinedWeight
        totalWeight += combinedWeight
    }

    return totalWeight > 0 ? weightedSum / totalWeight : 0.0
}
```

**File:** Update `Core/Evidence/ConfidenceDecay.swift` and `Core/Evidence/PatchEvidenceMap.swift`

---

### 1.7 EvidenceLocking Only Locks Ledger

**Problem:** If locking affects display, errors get "highlighted" instead of slowed.

**Solution:** Locking only prevents ledger penalty, display follows normal rules

```swift
/// Evidence locking policy
///
/// WHAT LOCKING DOES:
///   - Prevents ledger.evidence from decreasing (no penalty)
///   - Allows ledger.evidence to increase (if better observation)
///
/// WHAT LOCKING DOES NOT DO:
///   - Does NOT affect display update (display still monotonic, follows EMA)
///   - Does NOT affect delta calculation
///   - Does NOT affect color mapping
///
/// ERROR HANDLING FOR LOCKED PATCHES:
///   - Errors still affect deltaMultiplier (slows growth speed)
///   - But ledger value is protected
public enum EvidenceLocking {

    public static let lockThreshold: Double = 0.85
    public static let minObservationsForLock: Int = 20

    public static func isLocked(evidence: Double, observationCount: Int) -> Bool {
        return evidence >= lockThreshold && observationCount >= minObservationsForLock
    }
}

// In PatchEvidenceMap.update():
public func update(
    patchId: String,
    ledgerQuality: Double,
    verdict: ObservationVerdict,
    frameId: String,
    timestamp: TimeInterval
) {
    var entry = patches[patchId] ?? PatchEntry(lastUpdate: timestamp)

    // Check locking FIRST
    if EvidenceLocking.isLocked(evidence: entry.evidence, observationCount: entry.observationCount) {
        // LOCKED: Only allow increases, no penalties
        switch verdict {
        case .good:
            if ledgerQuality > entry.evidence {
                entry.evidence = ledgerQuality
                entry.bestFrameId = frameId
            }
            entry.lastGoodUpdate = timestamp
        case .suspect, .bad:
            // Record but don't penalize
            entry.suspectCount += 1
            // NOTE: deltaMultiplier still affected by verdict in EvidenceEngine
        }

        entry.lastUpdate = timestamp
        entry.observationCount += 1
        patches[patchId] = entry
        return  // Skip normal penalty logic
    }

    // Normal (unlocked) update logic...
}
```

**File:** Update `Core/Evidence/EvidenceLocking.swift` and `Core/Evidence/PatchEvidenceMap.swift`

---

### 1.8 DeterministicJSONEncoder Container Stability

**Problem:** Swift Dictionary is unordered even with sortedKeys if nested.

**Solution:** Recursive key sorting for all nested structures

```swift
/// Deterministic JSON encoder with full container stability
public final class DeterministicJSONEncoder {

    public static let floatPrecision: Int = 4

    /// Encode with deterministic output
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970

        let data = try encoder.encode(value)

        // Re-parse, stabilize, and re-encode
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let stabilized = stabilizeContainer(json)

        return try JSONSerialization.data(
            withJSONObject: stabilized,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    /// Recursively stabilize all containers
    private static func stabilizeContainer(_ json: Any) -> Any {
        if let dict = json as? [String: Any] {
            // Sort keys and recurse
            var result: [(String, Any)] = []
            for key in dict.keys.sorted() {
                result.append((key, stabilizeContainer(dict[key]!)))
            }
            // Convert back to dictionary (now with deterministic iteration order)
            var stabilizedDict: [String: Any] = [:]
            for (key, value) in result {
                stabilizedDict[key] = value
            }
            return stabilizedDict

        } else if let array = json as? [Any] {
            return array.map { stabilizeContainer($0) }

        } else if let double = json as? Double {
            // Quantize floats
            return quantize(double)

        } else if let float = json as? Float {
            return quantize(Double(float))

        } else {
            // String, Int, Bool, null - pass through
            return json
        }
    }

    /// Quantize to fixed precision (half-away-from-zero rounding)
    public static func quantize(_ value: Double) -> Double {
        let multiplier = pow(10.0, Double(floatPrecision))
        return (value * multiplier).rounded() / multiplier
    }
}

/// Types that should NOT be quantized (pass through as-is)
/// - TimeInterval when used as timestamp (precision matters)
/// - schemaVersion (string)
/// - Integer counts
```

**File:** Update `Core/Evidence/DeterministicJSONEncoder.swift`

---

### 1.9 PatchIdStrategy Coordinate Definition

**Problem:** Screen-space tile source undefined (raw vs undistorted, orientation handling).

**Solution:** Explicit coordinate specification

```swift
/// Patch ID strategy with explicit coordinate system
public protocol PatchIdStrategy {
    /// Generate patch ID from normalized screen point
    /// - Parameter normalizedPoint: Point in [0,1] x [0,1] coordinate space
    ///   where (0,0) is top-left, (1,1) is bottom-right
    ///   REGARDLESS of device orientation
    func patchId(for normalizedPoint: CGPoint) -> String

    /// Generate patch ID from world point (PR3+)
    func patchId(for worldPoint: SIMD3<Float>) -> String
}

/// Screen-space tile strategy with explicit coordinate system
public final class ScreenSpaceTileStrategy: PatchIdStrategy {

    public let tileSize: Int

    public init(tileSize: Int = EvidenceConstants.defaultTileSize) {
        self.tileSize = tileSize
    }

    /// Generate patch ID from NORMALIZED screen point
    ///
    /// COORDINATE SYSTEM:
    /// - Input: normalizedPoint in [0,1] x [0,1]
    /// - (0,0) = top-left corner
    /// - (1,1) = bottom-right corner
    /// - Orientation-independent (caller must normalize)
    ///
    /// GRID:
    /// - Grid size is implicit: ceil(1.0 / tileNormalizedSize)
    /// - tileNormalizedSize = tileSize / referenceResolution
    /// - referenceResolution = 1920 (longer edge)
    public func patchId(for normalizedPoint: CGPoint) -> String {
        let referenceResolution: CGFloat = 1920.0
        let tileNormalizedSize = CGFloat(tileSize) / referenceResolution

        let tileX = Int(normalizedPoint.x / tileNormalizedSize)
        let tileY = Int(normalizedPoint.y / tileNormalizedSize)

        return "tile_\(tileX)_\(tileY)"
    }

    /// Not supported in screen-space strategy
    public func patchId(for worldPoint: SIMD3<Float>) -> String {
        fatalError("World-space patch ID not supported. Use VoxelStrategy in PR3.")
    }
}

/// Coordinate normalizer (caller responsibility)
public enum CoordinateNormalizer {

    /// Normalize raw screen point to [0,1] x [0,1]
    /// - Parameters:
    ///   - rawPoint: Point in pixel coordinates
    ///   - frameSize: Frame size in pixels
    ///   - orientation: Device orientation
    /// - Returns: Normalized point in [0,1] x [0,1], orientation-independent
    public static func normalize(
        rawPoint: CGPoint,
        frameSize: CGSize,
        orientation: UIDeviceOrientation
    ) -> CGPoint {
        var x = rawPoint.x / frameSize.width
        var y = rawPoint.y / frameSize.height

        // Rotate to canonical orientation (portrait, home button at bottom)
        switch orientation {
        case .landscapeLeft:
            (x, y) = (y, 1 - x)
        case .landscapeRight:
            (x, y) = (1 - y, x)
        case .portraitUpsideDown:
            (x, y) = (1 - x, 1 - y)
        default:
            break  // Portrait is canonical
        }

        return CGPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
    }
}
```

**File:** Update `Core/Evidence/PatchIdStrategy.swift`

---

### 1.10 Performance Budget Breakdown

**Problem:** "5ms total" is too vague, need component budgets.

**Solution:** Explicit budget allocation with amortized aggregation

```swift
/// Performance budget allocation
public enum PerformanceBudget {

    /// Total budget per frame
    public static let totalBudgetMs: Double = 5.0

    /// Component budgets (must sum to < totalBudgetMs)
    public static let admissionCheckMs: Double = 0.3
    public static let verdictPipelineMs: Double = 0.3
    public static let ledgerUpdateMs: Double = 0.8
    public static let displayUpdateMs: Double = 0.3
    public static let aggregationMs: Double = 0.5  // Amortized
    public static let colorMappingMs: Double = 0.2
    public static let serializationMs: Double = 0.5  // Only when needed

    /// Verify budgets sum correctly
    public static var isValid: Bool {
        let sum = admissionCheckMs + verdictPipelineMs + ledgerUpdateMs +
                  displayUpdateMs + aggregationMs + colorMappingMs
        return sum < totalBudgetMs
    }
}

/// Amortized aggregation for O(1) per-frame cost
/// Instead of iterating all patches every frame, maintain running sums
public final class AmortizedAggregator {

    /// Running sum of weighted evidence
    private var weightedSum: Double = 0.0

    /// Running sum of weights
    private var totalWeight: Double = 0.0

    /// Patch contributions (for incremental updates)
    private var patchContributions: [String: (evidence: Double, weight: Double)] = [:]

    /// Update contribution from single patch
    public func updatePatch(
        patchId: String,
        evidence: Double,
        weight: Double
    ) {
        // Remove old contribution
        if let old = patchContributions[patchId] {
            weightedSum -= old.evidence * old.weight
            totalWeight -= old.weight
        }

        // Add new contribution
        weightedSum += evidence * weight
        totalWeight += weight
        patchContributions[patchId] = (evidence, weight)
    }

    /// Get current total evidence (O(1))
    public var totalEvidence: Double {
        return totalWeight > 0 ? weightedSum / totalWeight : 0.0
    }

    /// Periodic full recalculation (every N frames) to correct drift
    public func recalculate(from patches: [String: (evidence: Double, weight: Double)]) {
        weightedSum = 0.0
        totalWeight = 0.0
        patchContributions = patches

        for (_, contrib) in patches {
            weightedSum += contrib.evidence * contrib.weight
            totalWeight += contrib.weight
        }
    }
}
```

**File:** `Core/Evidence/PerformanceBudget.swift`, `Core/Evidence/AmortizedAggregator.swift`

---

## Part 2: Additional Enhancements

### 2.1 Evidence Health Monitor

```swift
/// Evidence system health metrics
public struct EvidenceHealthMetrics {
    /// Color state distribution
    public let colorDistribution: [ColorState: Double]

    /// Average patch evidence age (seconds)
    public let averageAge: Double

    /// Locked patch ratio
    public let lockedRatio: Double

    /// Average delta (growth rate)
    public let averageDelta: Double

    /// Stalled patches (no progress in 30s)
    public let stalledRatio: Double

    /// Health score [0, 1]
    public var healthScore: Double {
        let stalledPenalty = stalledRatio * 0.4
        let agePenalty = min(0.2, averageAge / 300.0)
        let lowDeltaPenalty = averageDelta < 0.001 ? 0.2 : 0.0
        return max(0, 1.0 - stalledPenalty - agePenalty - lowDeltaPenalty)
    }

    /// Is system healthy?
    public var isHealthy: Bool { healthScore > 0.6 }
}

/// Health monitor
public final class EvidenceHealthMonitor {
    public func computeMetrics(engine: EvidenceEngine, currentTime: TimeInterval) -> EvidenceHealthMetrics {
        // Implementation...
    }
}
```

**File:** `Core/Evidence/EvidenceHealthMonitor.swift`

---

### 2.2 Evidence Snapshot Diff

```swift
/// Diff between two evidence states
public struct EvidenceSnapshotDiff {
    public let addedPatches: Set<String>
    public let removedPatches: Set<String>
    public let changedPatches: [(patchId: String, oldEvidence: Double, newEvidence: Double, delta: Double)]
    public let gateDisplayDelta: Double
    public let softDisplayDelta: Double
    public let totalDisplayDelta: Double
    public let colorStateChanged: Bool

    /// Compute diff
    public static func compute(old: EvidenceState, new: EvidenceState) -> EvidenceSnapshotDiff {
        // Implementation...
    }
}
```

**File:** `Core/Evidence/EvidenceSnapshotDiff.swift`

---

### 2.3 Evidence Budget System

```swift
/// Evidence growth budget per time window
public final class EvidenceBudget {
    /// Maximum evidence gain per second
    public static let maxGainPerSecond: Double = 0.05

    private var remainingBudget: Double
    private var lastRefill: TimeInterval

    public init() {
        self.remainingBudget = Self.maxGainPerSecond
        self.lastRefill = 0
    }

    /// Consume budget, return allowed gain
    public func consume(requestedGain: Double, timestamp: TimeInterval) -> Double {
        refill(timestamp: timestamp)
        let allowed = min(requestedGain, remainingBudget)
        remainingBudget -= allowed
        return allowed
    }

    private func refill(timestamp: TimeInterval) {
        let elapsed = timestamp - lastRefill
        remainingBudget = min(Self.maxGainPerSecond, remainingBudget + elapsed * Self.maxGainPerSecond)
        lastRefill = timestamp
    }
}
```

**File:** `Core/Evidence/EvidenceBudget.swift`

---

### 2.4 Spatial Consistency Check

```swift
/// Spatial consistency checker
public enum SpatialConsistency {
    /// Check if patch evidence is consistent with neighbors
    public static func consistencyScore(
        patchId: String,
        neighborIds: [String],
        ledger: PatchEvidenceMap
    ) -> Double {
        let patchEvidence = ledger.evidence(for: patchId)
        let neighborEvidences = neighborIds.compactMap { ledger.evidence(for: $0) }

        guard !neighborEvidences.isEmpty else { return 1.0 }

        let avgNeighbor = neighborEvidences.reduce(0, +) / Double(neighborEvidences.count)
        let diff = abs(patchEvidence - avgNeighbor)

        // Large difference = low consistency
        return max(0, 1.0 - diff / 0.5)
    }
}
```

**File:** `Core/Evidence/SpatialConsistency.swift`

---

### 2.5 Rollback Safe Points

```swift
/// Safe point manager for potential rollback
public final class SafePointManager {
    public static let maxSafePoints: Int = 5
    public static let safePointInterval: Double = 30.0

    private var safePoints: [(timestamp: TimeInterval, state: Data)] = []

    public func maybeSavePoint(state: Data, timestamp: TimeInterval) {
        guard let last = safePoints.last else {
            safePoints.append((timestamp, state))
            return
        }

        if timestamp - last.timestamp >= Self.safePointInterval {
            safePoints.append((timestamp, state))
            if safePoints.count > Self.maxSafePoints {
                safePoints.removeFirst()
            }
        }
    }

    public func rollback() -> Data? {
        return safePoints.popLast()?.state
    }

    public func clear() {
        safePoints.removeAll()
    }
}
```

**File:** `Core/Evidence/SafePointManager.swift`

---

### 2.6 Evidence Provenance Tracking

```swift
/// Evidence provenance for debugging
public struct EvidenceProvenance: Codable {
    /// Top contributing frames (max 5)
    public struct FrameContribution: Codable {
        public let frameId: String
        public let quality: Double
        public let timestamp: TimeInterval
    }

    public let topFrames: [FrameContribution]
    public let firstObserved: TimeInterval
    public let bestObserved: TimeInterval
    public let totalObservations: Int
    public let verdictHistory: [ObservationVerdict]  // Last 10
}

/// Provenance tracker (optional, for debugging builds only)
public final class ProvenanceTracker {
    private var provenance: [String: EvidenceProvenance] = [:]

    public func record(patchId: String, frameId: String, quality: Double, verdict: ObservationVerdict, timestamp: TimeInterval) {
        // Implementation...
    }

    public func getProvenance(for patchId: String) -> EvidenceProvenance? {
        return provenance[patchId]
    }
}
```

**File:** `Core/Evidence/EvidenceProvenance.swift`

---

### 2.7 Dynamic Threshold Adjustment

```swift
/// Scene condition for threshold adjustment
public enum SceneCondition {
    case normal
    case lowLight
    case highContrast
    case fastMotion
}

/// Dynamic threshold adjuster
public struct DynamicThresholds {
    /// Adjustment multipliers
    public static func multiplier(for condition: SceneCondition) -> Double {
        switch condition {
        case .normal:       return 1.0
        case .lowLight:     return 0.85  // Relax thresholds
        case .highContrast: return 1.1   // Tighten thresholds
        case .fastMotion:   return 0.9   // Slightly relax
        }
    }

    /// Adjust threshold
    public static func adjust(_ baseThreshold: Double, for condition: SceneCondition) -> Double {
        return baseThreshold * multiplier(for: condition)
    }
}
```

**File:** `Core/Evidence/DynamicThresholds.swift`

---

### 2.8 Batch Update Optimization

```swift
/// Batch observation for efficient processing
public struct ObservationBatch {
    public let observations: [(observation: Observation, verdict: ObservationVerdict, gateQuality: Double, softQuality: Double)]
    public let timestamp: TimeInterval
    public let frameId: String

    /// Process batch with single aggregation
    public func process(engine: EvidenceEngine) {
        // Sort by patch ID for cache locality
        let sorted = observations.sorted { $0.observation.patchId < $1.observation.patchId }

        // Process each observation
        for item in sorted {
            engine.processObservationInternal(
                item.observation,
                verdict: item.verdict,
                gateQuality: item.gateQuality,
                softQuality: item.softQuality
            )
        }

        // Single aggregation at end
        engine.finalizeFrame(timestamp: timestamp)
    }
}
```

**File:** `Core/Evidence/ObservationBatch.swift`

---

### 2.9 Test Data Generator

```swift
/// Test data generator for various scenarios
public enum TestScenario {
    case normalCapture(patchCount: Int, frameCount: Int)
    case spamAttack(targetPatch: String, spamFrames: Int)
    case sensorFailure(failureRate: Double, duration: TimeInterval)
    case viewAngleSpam(sameAngleFrames: Int)
    case perfectCapture(patchCount: Int)
}

public final class TestDataGenerator {
    public static func generate(scenario: TestScenario) -> [(Observation, Double, Double)] {
        switch scenario {
        case .normalCapture(let patchCount, let frameCount):
            return generateNormalCapture(patchCount: patchCount, frameCount: frameCount)
        // ... other cases
        }
    }

    private static func generateNormalCapture(patchCount: Int, frameCount: Int) -> [(Observation, Double, Double)] {
        var result: [(Observation, Double, Double)] = []
        for frame in 0..<frameCount {
            for patch in 0..<patchCount {
                let obs = Observation(
                    patchId: "patch_\(patch)",
                    isErroneous: false,
                    timestamp: Double(frame) * 0.033,
                    frameId: "frame_\(frame)"
                )
                let quality = 0.3 + Double(frame) / Double(frameCount) * 0.6
                result.append((obs, quality, quality * 0.9))
            }
        }
        return result
    }
}
```

**File:** `Tests/Evidence/TestDataGenerator.swift`

---

### 2.10 Performance Profiler

```swift
/// Performance profiler for evidence system
public final class EvidenceProfiler {

    public struct Timings {
        public var admissionMs: Double = 0
        public var verdictMs: Double = 0
        public var ledgerMs: Double = 0
        public var displayMs: Double = 0
        public var aggregationMs: Double = 0
        public var colorMappingMs: Double = 0
        public var totalMs: Double = 0

        public var isWithinBudget: Bool {
            return totalMs < PerformanceBudget.totalBudgetMs
        }
    }

    private var timings: Timings = Timings()
    private var timingsHistory: [Timings] = []

    public func profile<T>(_ block: () -> T, into keyPath: WritableKeyPath<Timings, Double>) -> T {
        let start = CACurrentMediaTime()
        let result = block()
        let elapsed = (CACurrentMediaTime() - start) * 1000  // ms
        timings[keyPath: keyPath] = elapsed
        return result
    }

    public func finalizeFrame() {
        timings.totalMs = timings.admissionMs + timings.verdictMs + timings.ledgerMs +
                         timings.displayMs + timings.aggregationMs + timings.colorMappingMs
        timingsHistory.append(timings)
        if timingsHistory.count > 100 {
            timingsHistory.removeFirst()
        }
        timings = Timings()
    }

    public var averageTimings: Timings {
        guard !timingsHistory.isEmpty else { return Timings() }
        var avg = Timings()
        for t in timingsHistory {
            avg.admissionMs += t.admissionMs
            avg.verdictMs += t.verdictMs
            avg.ledgerMs += t.ledgerMs
            avg.displayMs += t.displayMs
            avg.aggregationMs += t.aggregationMs
            avg.colorMappingMs += t.colorMappingMs
            avg.totalMs += t.totalMs
        }
        let count = Double(timingsHistory.count)
        avg.admissionMs /= count
        avg.verdictMs /= count
        avg.ledgerMs /= count
        avg.displayMs /= count
        avg.aggregationMs /= count
        avg.colorMappingMs /= count
        avg.totalMs /= count
        return avg
    }
}
```

**File:** `Core/Evidence/EvidenceProfiler.swift`

---

## Part 3: Legacy Code Cleanup Protocol

### 3.1 Conflict Keywords to Search and DELETE

```
CURSOR INSTRUCTION: Search entire codebase for these patterns and REMOVE them:

1. observation.quality (when used for ledger update)
   - Pattern: ledger.update.*quality.*observation\.quality
   - Action: DELETE, replace with explicit gateQuality/softQuality

2. [String: Any] serialization
   - Pattern: func export.*\[String: Any\]
   - Pattern: func load.*\[String: Any\]
   - Action: DELETE, replace with Codable

3. minDelta padding
   - Pattern: minDelta|min.*Delta|0\.001.*delta
   - Action: DELETE, delta should be exact (newDisplay - prevDisplay)

4. isErroneous: Bool (old path)
   - Pattern: isErroneous: Bool.*update
   - Action: REPLACE with verdict: ObservationVerdict

5. Delta calculated AFTER update
   - Pattern: display = max\(display.*\n.*delta =
   - Action: REORDER to calculate delta BEFORE max()

6. max(gateQuality, softQuality)
   - Pattern: max\(gateQuality.*softQuality\)|max\(gate.*soft\)
   - Action: DELETE, use SplitLedger with separate updates

7. totalEvidence() with full iteration every frame
   - Pattern: for.*in patches.*\{.*evidence \* weight
   - Action: REPLACE with AmortizedAggregator
```

### 3.2 Migration Mapping Table

```
CURSOR INSTRUCTION: Create this migration mapping:

| Old API | New API | Notes |
|---------|---------|-------|
| EvidenceLayers.ledger | EvidenceLayers.splitLedger | Use .gateLedger / .softLedger |
| PatchEvidenceMap.update(quality:isErroneous:) | PatchEvidenceMap.update(ledgerQuality:verdict:) | Verdict replaces bool |
| EvidenceLayers.gateDelta: Double | EvidenceLayers.gateDelta: DeltaTracker | Use .raw or .smoothed |
| exportState() -> [String: Any] | exportStateJSON() -> Data | Codable |
| loadState([String: Any]) | loadStateJSON(Data) | Codable |
| Observation.quality | REMOVED | Pass gateQuality/softQuality explicitly |
```

### 3.3 Deprecation Strategy

```swift
/// Mark old APIs as deprecated
@available(*, deprecated, message: "Use splitLedger.gateLedger/softLedger instead")
public var ledger: PatchEvidenceMap { ... }

@available(*, deprecated, message: "Use verdict: ObservationVerdict instead")
public func update(patchId: String, quality: Double, isErroneous: Bool, ...) { ... }

@available(*, deprecated, message: "Use exportStateJSON() instead")
public func exportState() -> [String: Any] { ... }
```

### 3.4 Compilation Error Driven Migration

```
CURSOR INSTRUCTION: Follow this migration order:

1. Change function signatures FIRST (causes compilation errors)
2. Fix each compilation error at call site
3. Run tests after each major change
4. Delete deprecated wrappers only after all call sites migrated
```

### 3.5 Behavior Lock Tests

```swift
/// Tests that MUST pass after migration

// 1. Deterministic JSON encoding
func testDeterministicJSONIsIdentical() {
    let state = createTestState()
    let json1 = try! DeterministicJSONEncoder.encode(state)
    let json2 = try! DeterministicJSONEncoder.encode(state)
    XCTAssertEqual(json1, json2, "JSON encoding must be deterministic")
}

// 2. Split ledger separation
func testGateLedgerIsSeparateFromSoftLedger() {
    let splitLedger = SplitLedger()
    splitLedger.update(observation: obs, gateQuality: 0.8, softQuality: 0.6, verdict: .good)

    XCTAssertEqual(splitLedger.gateLedger.evidence(for: "patch1"), 0.8)
    XCTAssertEqual(splitLedger.softLedger.evidence(for: "patch1"), 0.6)
}

// 3. Delta is NOT padded
func testDeltaIsNotPadded() {
    let engine = EvidenceEngine()
    // Process many frames with same quality
    for _ in 0..<100 {
        engine.processFrame(...)
    }
    // Delta should approach 0, not minDelta
    XCTAssertLessThan(engine.evidenceLayers.gateDelta.raw, 0.0001)
}

// 4. Verdict pipeline single writer
func testOnlyQuarantineChangesVerdict() {
    // RobustStatistics should NOT change verdict
    let quality = RobustStatistics.robustQuality(rawQuality: 0.2, currentEvidence: 0.8)
    // quality is adjusted, but this doesn't change verdict enum
}

// 5. Locking only affects ledger
func testLockingDoesNotAffectDisplay() {
    // Setup locked patch
    // Send bad observation
    // Ledger should NOT decrease
    // Display update should still follow normal rules
}
```

---

## Part 4: Updated File Structure (Final)

```
Core/Evidence/
├── Observation.swift
├── ObservationVerdict.swift
├── VerdictPipeline.swift                 # NEW (V3)
├── PenaltyConfig.swift
├── PatchEvidenceMap.swift                # UPDATED
├── SplitLedger.swift
├── PatchDisplayMap.swift                 # UPDATED
├── DeltaTracker.swift
├── AdmissionController.swift             # NEW (V3) - replaces separate spam components
├── SpamProtection.swift
├── TokenBucketLimiter.swift
├── AnomalyQuarantine.swift
├── RobustStatistics.swift
├── EvidenceLocking.swift                 # UPDATED
├── ViewDiversityTracker.swift
├── ConfidenceDecay.swift                 # UPDATED
├── PatchIdStrategy.swift                 # UPDATED
├── DeterministicJSONEncoder.swift        # UPDATED
├── AmortizedAggregator.swift             # NEW (V3)
├── EvidenceHealthMonitor.swift           # NEW (V3)
├── EvidenceSnapshotDiff.swift            # NEW (V3)
├── EvidenceBudget.swift                  # NEW (V3)
├── SpatialConsistency.swift              # NEW (V3)
├── SafePointManager.swift                # NEW (V3)
├── EvidenceProvenance.swift              # NEW (V3)
├── DynamicThresholds.swift               # NEW (V3)
├── ObservationBatch.swift                # NEW (V3)
├── PerformanceBudget.swift               # NEW (V3)
├── EvidenceProfiler.swift                # NEW (V3)
├── EvidenceLayers.swift                  # UPDATED
├── EvidenceEngine.swift                  # UPDATED
├── ColorMapping.swift
├── DynamicWeights.swift
├── MetricSmoother.swift
├── EvidenceState.swift                   # UPDATED
└── EvidenceError.swift

Core/Constants/
└── EvidenceConstants.swift               # UPDATED

Tests/Evidence/
├── ... existing tests ...
├── VerdictPipelineTests.swift            # NEW (V3)
├── AdmissionControllerTests.swift        # NEW (V3)
├── AmortizedAggregatorTests.swift        # NEW (V3)
├── DeterministicEncodingTests.swift      # UPDATED
├── BehaviorLockTests.swift               # NEW (V3) - migration verification
└── TestDataGenerator.swift               # NEW (V3)
```

---

## Part 5: Implementation Order (V3)

```
Phase 1: Critical Hardening (MUST DO FIRST)
1. VerdictPipeline - establish single-writer rule
2. Update Rule A examples - remove max(gate, soft)
3. Add softWriteRequiresGateMin to constants
4. Update PatchDisplayMap - EMA + locking acceleration
5. AdmissionController - unified admission decision

Phase 2: Performance & Stability
6. ConfidenceDecay - clarify weight-only effect
7. EvidenceLocking - clarify ledger-only scope
8. DeterministicJSONEncoder - container stability
9. PatchIdStrategy - coordinate definition
10. AmortizedAggregator - O(1) aggregation

Phase 3: Enhancements
11. EvidenceHealthMonitor
12. EvidenceSnapshotDiff
13. EvidenceBudget
14. SpatialConsistency
15. SafePointManager
16. EvidenceProvenance
17. DynamicThresholds
18. ObservationBatch
19. PerformanceBudget
20. EvidenceProfiler

Phase 4: Legacy Cleanup
21. Search and delete conflict patterns
22. Apply migration mapping
23. Deprecate old APIs
24. Run behavior lock tests
25. Delete deprecated code

Phase 5: Final Testing
26. Run all unit tests
27. Run all integration tests
28. Run performance benchmarks
29. Verify deterministic encoding
30. Verify cross-platform compatibility
```

---

**Document Version:** Patch V3
**Author:** Claude Code
**Last Updated:** 2026-01-29
