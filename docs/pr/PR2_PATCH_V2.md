# PR2 Evidence System - Patch V2 (Hardening Supplement)

**Document Version:** Patch V2
**Status:** SUPPLEMENT TO PR2_DETAILED_PROMPT_EN.md
**Created:** 2026-01-29
**Purpose:** Address critical gaps and strengthen the evidence system architecture

---

## Overview

This patch addresses 7 critical issues identified in the PR2 plan and adds 6 additional enhancements for industrial-grade robustness. All changes maintain the core constraints:
- All code runs on-device
- Cross-platform consistency
- UI monotonicity (never gets darker)

---

## Part 1: Critical Fixes (MUST IMPLEMENT)

### 1.1 Split Ledger into GateLedger + SoftLedger

**Problem:** Using `max(gateQuality, softQuality)` for ledgerQuality pollutes the ledger with semantically different signals.
- Gate = "reachability" (view angles, geometry, basic quality)
- Soft = "summit quality" (depth, topology, occlusion)
- Mixing them makes diagnosis impossible

**Solution:** Separate ledgers that merge at display layer

```swift
/// Split ledger architecture
public final class SplitLedger {

    /// Gate ledger: stores reachability evidence
    public let gateLedger: PatchEvidenceMap

    /// Soft ledger: stores quality evidence
    public let softLedger: PatchEvidenceMap

    public init() {
        self.gateLedger = PatchEvidenceMap()
        self.softLedger = PatchEvidenceMap()
    }

    /// Update both ledgers with their respective qualities
    public func update(
        observation: Observation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict
    ) {
        // Gate ledger only receives gateQuality
        gateLedger.update(
            patchId: observation.patchId,
            ledgerQuality: gateQuality,
            verdict: verdict,
            frameId: observation.frameId,
            timestamp: observation.timestamp
        )

        // Soft ledger only receives softQuality (with stricter write policy)
        // Soft ledger only writes if gateQuality is also decent
        if gateQuality > 0.3 {
            softLedger.update(
                patchId: observation.patchId,
                ledgerQuality: softQuality,
                verdict: verdict,
                frameId: observation.frameId,
                timestamp: observation.timestamp
            )
        }
    }

    /// Compute patch evidence with dynamic weight fusion
    public func patchEvidence(for patchId: String, currentProgress: Double) -> Double {
        let gateEvidence = gateLedger.evidence(for: patchId)
        let softEvidence = softLedger.evidence(for: patchId)

        // Dynamic weights based on progress
        let (gateWeight, softWeight) = DynamicWeights.weights(currentTotal: currentProgress)

        return gateWeight * gateEvidence + softWeight * softEvidence
    }

    /// Total evidence across all patches
    public func totalEvidence(currentProgress: Double) -> (gate: Double, soft: Double, combined: Double) {
        let gateTotal = gateLedger.totalEvidence()
        let softTotal = softLedger.totalEvidence()

        let (gateWeight, softWeight) = DynamicWeights.weights(currentTotal: currentProgress)
        let combined = gateWeight * gateTotal + softWeight * softTotal

        return (gateTotal, softTotal, combined)
    }
}
```

**File:** `Core/Evidence/SplitLedger.swift`

---

### 1.2 Add ObservationVerdict (Closed Set)

**Problem:** `isErroneous` is a boolean with no judgment standard. PR4/PR5 will add detection logic but PR2 needs the interface.

**Solution:** Closed-set verdict enum with penalty routing

```swift
/// Observation verdict (closed set)
/// Determines how observation affects ledger
public enum ObservationVerdict: String, Codable, Sendable {

    /// Good observation: full credit
    case good

    /// Suspect observation: reduced delta multiplier, no penalty
    /// Used when uncertain (single frame anomaly, edge case)
    case suspect

    /// Bad observation: applies penalty with cooldown
    /// Only used when confident (confirmed dynamic object, sensor failure)
    case bad

    /// Verdict reason for debugging/analytics
    public struct Reason: Codable, Sendable {
        public let code: ReasonCode
        public let confidence: Double  // 0-1

        public enum ReasonCode: String, Codable, Sendable {
            // Good reasons
            case normalObservation
            case highConfidenceMatch
            case stableDepth

            // Suspect reasons
            case singleFrameAnomaly
            case edgeCaseGeometry
            case lowConfidenceMatch
            case slightMotionBlur

            // Bad reasons
            case confirmedDynamicObject
            case confirmedDepthFailure
            case confirmedExposureDrift
            case confirmedMotionBlur
            case multiFrameAnomaly
        }
    }
}

/// Extended observation with verdict
public struct JudgedObservation {
    public let observation: Observation
    public let verdict: ObservationVerdict
    public let reason: ObservationVerdict.Reason?

    /// Delta multiplier based on verdict
    public var deltaMultiplier: Double {
        switch verdict {
        case .good:    return 1.0
        case .suspect: return 0.3   // Slows down but doesn't stop
        case .bad:     return 0.0   // No positive contribution
        }
    }
}
```

**Update PatchEvidenceMap.update():**

```swift
public func update(
    patchId: String,
    ledgerQuality: Double,
    verdict: ObservationVerdict,  // Changed from isErroneous
    frameId: String,
    timestamp: TimeInterval
) {
    var entry = patches[patchId] ?? PatchEntry(lastUpdate: timestamp)

    switch verdict {
    case .good:
        // Reset error streak, update evidence if better
        entry.errorStreak = 0
        entry.lastGoodUpdate = timestamp
        if ledgerQuality > entry.evidence {
            entry.evidence = ledgerQuality
            entry.bestFrameId = frameId
        }

    case .suspect:
        // Don't penalize, but don't reset error streak
        // Just record the observation (for analytics)
        entry.suspectCount += 1

    case .bad:
        // Apply gradual penalty with cooldown
        entry.errorStreak += 1
        entry.errorCount += 1

        let penalty = PenaltyConfig.computePenalty(
            errorStreak: entry.errorStreak,
            lastGoodUpdate: entry.lastGoodUpdate,
            currentTime: timestamp
        )

        entry.evidence = max(0, entry.evidence - penalty)
    }

    entry.lastUpdate = timestamp
    entry.observationCount += 1
    patches[patchId] = entry
}
```

**File:** `Core/Evidence/ObservationVerdict.swift`

---

### 1.3 Add DeltaEMA for Smooth Brightness Animation

**Problem:** Raw delta is noisy, causing UI brightness speed to "stutter".

**Solution:** Separate `deltaRaw` (accurate) and `deltaEMA` (for UI animation)

```swift
/// Delta tracking with EMA smoothing
public struct DeltaTracker {

    /// Raw delta (accurate, for diagnostics)
    public private(set) var raw: Double = 0.0

    /// EMA-smoothed delta (for UI animation speed)
    public private(set) var smoothed: Double = 0.0

    /// EMA coefficient
    private let alpha: Double = 0.2

    /// Update with new delta
    public mutating func update(newDelta: Double) {
        raw = newDelta
        smoothed = alpha * newDelta + (1 - alpha) * smoothed
    }

    /// Reset
    public mutating func reset() {
        raw = 0.0
        smoothed = 0.0
    }
}

// In EvidenceLayers:
public final class EvidenceLayers {
    // ...

    /// Gate delta tracker
    public private(set) var gateDelta: DeltaTracker = DeltaTracker()

    /// Soft delta tracker
    public private(set) var softDelta: DeltaTracker = DeltaTracker()

    public func processObservation(...) {
        // ... compute smoothedGate, smoothedSoft ...

        let prevGateDisplay = gateDisplay
        let prevSoftDisplay = softDisplay

        gateDisplay = max(gateDisplay, smoothedGate)
        softDisplay = max(softDisplay, smoothedSoft)

        // Update delta trackers
        gateDelta.update(newDelta: gateDisplay - prevGateDisplay)
        softDelta.update(newDelta: softDisplay - prevSoftDisplay)

        // ...
    }
}
```

**File:** `Core/Evidence/DeltaTracker.swift`

---

### 1.4 Triple-Layer Frame Spam Protection

**Problem:** `observationCount/8` only blocks quantity spam, not quality spam or time spam.

**Solution:** Three-layer protection

```swift
/// Frame spam protection (triple layer)
public final class SpamProtection {

    // MARK: - Layer 1: Frequency Cap (existing)

    /// Weight cap denominator
    public static let weightCapDenominator: Double = 8.0

    public static func frequencyWeight(observationCount: Int) -> Double {
        return min(1.0, Double(observationCount) / weightCapDenominator)
    }

    // MARK: - Layer 2: Time Density Limiter (NEW)

    /// Minimum interval between updates for same patch (ms)
    public static let minUpdateIntervalMs: Double = 120.0

    /// Pending updates (patch -> last update timestamp)
    private var lastUpdateTime: [String: TimeInterval] = [:]

    /// Check if update is allowed (time density)
    public func shouldAllowUpdate(patchId: String, timestamp: TimeInterval) -> Bool {
        if let lastTime = lastUpdateTime[patchId] {
            let intervalMs = (timestamp - lastTime) * 1000
            if intervalMs < Self.minUpdateIntervalMs {
                return false  // Too fast, skip
            }
        }
        lastUpdateTime[patchId] = timestamp
        return true
    }

    // MARK: - Layer 3: Information Gain Filter (NEW)

    /// Minimum novelty to write to ledger
    public static let minNoveltyForLedger: Double = 0.1

    /// Compute effective quality with novelty discount
    public static func effectiveQuality(
        rawQuality: Double,
        novelty: Double  // 0-1, from pose/view difference
    ) -> Double {
        // If novelty is low (same view angle), discount the quality
        let noveltyFactor = max(Self.minNoveltyForLedger, novelty)
        return rawQuality * noveltyFactor
    }
}

// In PatchEntry, add:
public struct PatchEntry: Codable {
    // ... existing fields ...

    /// View angles observed (for novelty calculation)
    public var observedViewAngles: [Float] = []

    /// Compute novelty based on view diversity
    public func novelty(newViewAngle: Float) -> Double {
        guard !observedViewAngles.isEmpty else { return 1.0 }

        // Find minimum angle difference to any existing view
        let minDiff = observedViewAngles.map { abs($0 - newViewAngle) }.min() ?? 90.0

        // 15+ degrees difference = full novelty
        return min(1.0, Double(minDiff) / 15.0)
    }
}
```

**File:** `Core/Evidence/SpamProtection.swift`

---

### 1.5 Clarify Patch Display vs Ledger

**Problem:** Rule F uses `patchEvidence` but unclear if it's ledger (can decrease) or display (monotonic).

**Solution:** Explicit `PatchDisplayEvidence` that's monotonic

```swift
/// Patch display evidence (monotonic, separate from ledger)
public final class PatchDisplayMap {

    /// Patch display entry
    public struct DisplayEntry: Codable {
        /// Display evidence (monotonic)
        public var evidence: Double = 0.0

        /// Last update timestamp
        public var lastUpdate: TimeInterval = 0.0
    }

    private var patches: [String: DisplayEntry] = [:]

    /// Update patch display (monotonic)
    public func update(patchId: String, ledgerEvidence: Double, timestamp: TimeInterval) {
        var entry = patches[patchId] ?? DisplayEntry()

        // Monotonic: only increase
        entry.evidence = max(entry.evidence, ledgerEvidence)
        entry.lastUpdate = timestamp

        patches[patchId] = entry
    }

    /// Get patch display evidence
    public func evidence(for patchId: String) -> Double {
        return patches[patchId]?.evidence ?? 0.0
    }

    /// Compute color evidence for patch (Rule F)
    public func colorEvidence(
        for patchId: String,
        globalDisplay: Double
    ) -> Double {
        let patchDisplay = evidence(for: patchId)
        // Rule F: 70% local (monotonic) + 30% global (monotonic)
        return 0.7 * patchDisplay + 0.3 * globalDisplay
    }
}
```

**Update EvidenceLayers:**

```swift
public final class EvidenceLayers {
    // ...

    /// Patch-level display (monotonic)
    public let patchDisplay: PatchDisplayMap

    public func processObservation(...) {
        // ... update ledger ...

        // Update patch display (monotonic)
        let patchLedgerEvidence = ledger.patchEvidence(
            for: observation.patchId,
            currentProgress: _lastTotalDisplay
        )
        patchDisplay.update(
            patchId: observation.patchId,
            ledgerEvidence: patchLedgerEvidence,
            timestamp: observation.timestamp
        )

        // ... rest of processing ...
    }
}
```

**Global display computation (coverage-weighted):**

```swift
/// Compute global display with coverage weighting
public func computeGlobalDisplay(
    patchDisplay: PatchDisplayMap,
    coverageWeights: [String: Double]  // Spatial coverage weights
) -> Double {
    var weightedSum: Double = 0.0
    var totalWeight: Double = 0.0

    for (patchId, coverageWeight) in coverageWeights {
        let evidence = patchDisplay.evidence(for: patchId)
        weightedSum += evidence * coverageWeight
        totalWeight += coverageWeight
    }

    return totalWeight > 0 ? weightedSum / totalWeight : 0.0
}
```

**File:** `Core/Evidence/PatchDisplayMap.swift`

---

### 1.6 Deterministic JSON Encoding

**Problem:** Different platforms may serialize JSON differently, breaking cross-platform consistency.

**Solution:** Deterministic encoder with sorted keys and quantized floats

```swift
/// Deterministic JSON encoder for cross-platform consistency
public final class DeterministicJSONEncoder {

    /// Float precision (decimal places)
    public static let floatPrecision: Int = 4

    /// Quantize double to fixed precision
    public static func quantize(_ value: Double) -> Double {
        let multiplier = pow(10.0, Double(floatPrecision))
        return (value * multiplier).rounded() / multiplier
    }

    /// Encode state to deterministic JSON
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970

        // First encode normally
        let data = try encoder.encode(value)

        // Then re-parse and quantize floats
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        json = quantizeFloats(in: json)

        return try JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    /// Recursively quantize all floats in JSON
    private static func quantizeFloats(in json: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]

        for (key, value) in json {
            if let doubleValue = value as? Double {
                result[key] = quantize(doubleValue)
            } else if let dict = value as? [String: Any] {
                result[key] = quantizeFloats(in: dict)
            } else if let array = value as? [Any] {
                result[key] = array.map { item -> Any in
                    if let d = item as? Double {
                        return quantize(d)
                    } else if let dict = item as? [String: Any] {
                        return quantizeFloats(in: dict)
                    }
                    return item
                }
            } else {
                result[key] = value
            }
        }

        return result
    }
}

/// Partial load support for forward compatibility
public struct EvidenceState: Codable {
    // ... existing fields ...

    /// Schema version for compatibility check
    public let schemaVersion: String

    public static let currentSchemaVersion = "2.1"

    /// Minimum compatible schema version
    public static let minCompatibleVersion = "2.0"

    /// Check if version is compatible
    public static func isCompatible(version: String) -> Bool {
        // Simple semver comparison (major.minor)
        let current = currentSchemaVersion.split(separator: ".").compactMap { Int($0) }
        let check = version.split(separator: ".").compactMap { Int($0) }

        guard current.count >= 2, check.count >= 2 else { return false }

        // Same major version = compatible
        return check[0] == current[0]
    }
}

/// Decode with forward compatibility
extension EvidenceLayers {
    public func loadStateJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        // First decode just the version
        struct VersionCheck: Decodable {
            let schemaVersion: String
        }

        let versionInfo = try decoder.decode(VersionCheck.self, from: data)

        guard EvidenceState.isCompatible(version: versionInfo.schemaVersion) else {
            throw EvidenceError.incompatibleSchemaVersion(
                expected: EvidenceState.currentSchemaVersion,
                found: versionInfo.schemaVersion
            )
        }

        // Now decode full state (unknown fields are ignored by default)
        let state = try decoder.decode(EvidenceState.self, from: data)

        // Apply state...
    }
}
```

**File:** `Core/Evidence/DeterministicJSONEncoder.swift`

---

### 1.7 Define Patch ID Strategy

**Problem:** `patchId` is just String with no defined generation strategy or spatial scale.

**Solution:** PR2 uses screen-space tiles, with interface for PR3 3D voxels

```swift
/// Patch ID generation strategy
public protocol PatchIdStrategy {
    func patchId(for screenPoint: CGPoint, frameSize: CGSize) -> String
    func patchId(for worldPoint: SIMD3<Float>) -> String
}

/// PR2: Screen-space tile strategy
public final class ScreenSpaceTileStrategy: PatchIdStrategy {

    /// Tile size in pixels
    public let tileSize: Int

    /// Grid dimensions (computed from frame size)
    private var gridWidth: Int = 0
    private var gridHeight: Int = 0

    public init(tileSize: Int = 32) {
        self.tileSize = tileSize
    }

    /// Configure grid for frame size
    public func configure(frameSize: CGSize) {
        gridWidth = Int(ceil(frameSize.width / CGFloat(tileSize)))
        gridHeight = Int(ceil(frameSize.height / CGFloat(tileSize)))
    }

    /// Generate patch ID from screen point
    public func patchId(for screenPoint: CGPoint, frameSize: CGSize) -> String {
        let tileX = Int(screenPoint.x) / tileSize
        let tileY = Int(screenPoint.y) / tileSize
        return "tile_\(tileX)_\(tileY)"
    }

    /// World point: not supported in PR2
    public func patchId(for worldPoint: SIMD3<Float>) -> String {
        fatalError("World-space patch ID not supported in PR2. Use PR3 VoxelStrategy.")
    }
}

/// PR3: 3D Voxel strategy (stub for PR2)
public final class VoxelStrategy: PatchIdStrategy {

    /// Voxel size in meters
    public let voxelSize: Float

    public init(voxelSize: Float = 0.03) {  // 3cm default
        self.voxelSize = voxelSize
    }

    public func patchId(for screenPoint: CGPoint, frameSize: CGSize) -> String {
        fatalError("Screen-space patch ID not supported in VoxelStrategy. Project to world first.")
    }

    public func patchId(for worldPoint: SIMD3<Float>) -> String {
        let vx = Int(floor(worldPoint.x / voxelSize))
        let vy = Int(floor(worldPoint.y / voxelSize))
        let vz = Int(floor(worldPoint.z / voxelSize))
        return "voxel_\(vx)_\(vy)_\(vz)"
    }
}

/// PR2 default configuration
public enum PatchConfig {
    /// PR2: Use 32x32 screen-space tiles
    public static let defaultTileSize: Int = 32

    /// PR3: Use 3cm voxels
    public static let defaultVoxelSize: Float = 0.03

    /// Create default strategy for PR2
    public static func createPR2Strategy() -> PatchIdStrategy {
        return ScreenSpaceTileStrategy(tileSize: defaultTileSize)
    }
}
```

**File:** `Core/Evidence/PatchIdStrategy.swift`

---

## Part 2: Additional Enhancements

### 2.1 Confidence Decay for Stale Patches

**Purpose:** Old patches should have reduced influence on global evidence.

```swift
/// Confidence decay for stale patches
public enum ConfidenceDecay {

    /// Half-life in seconds
    public static let halfLifeSec: Double = 60.0

    /// Compute decay weight
    public static func weight(
        lastUpdate: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        let age = currentTime - lastUpdate
        return exp(-0.693 * age / halfLifeSec)  // 0.693 = ln(2)
    }
}

// Update totalEvidence to use decay:
public func totalEvidence(currentTime: TimeInterval) -> Double {
    guard !patches.isEmpty else { return 0.0 }

    var weightedSum: Double = 0.0
    var totalWeight: Double = 0.0

    for (_, entry) in patches {
        let freqWeight = SpamProtection.frequencyWeight(observationCount: entry.observationCount)
        let decayWeight = ConfidenceDecay.weight(lastUpdate: entry.lastUpdate, currentTime: currentTime)
        let combinedWeight = freqWeight * decayWeight

        weightedSum += entry.evidence * combinedWeight
        totalWeight += combinedWeight
    }

    return totalWeight > 0 ? weightedSum / totalWeight : 0.0
}
```

**File:** `Core/Evidence/ConfidenceDecay.swift`

---

### 2.2 Anomaly Quarantine Queue

**Purpose:** Avoid single-frame misjudgment by requiring consecutive anomalies.

```swift
/// Anomaly quarantine queue
/// Requires 3 consecutive suspect observations before judging as bad
public final class AnomalyQuarantine {

    /// Quarantine entry
    private struct QuarantineEntry {
        let timestamp: TimeInterval
        var consecutiveCount: Int
    }

    /// Quarantine threshold: consecutive suspect frames needed
    public static let quarantineThreshold: Int = 3

    /// Quarantine timeout: max age of quarantine entry
    public static let quarantineTimeoutSec: Double = 1.0

    /// Patch -> quarantine entry
    private var quarantine: [String: QuarantineEntry] = [:]

    /// Process observation and return final verdict
    /// - May upgrade suspect to bad if consecutive threshold reached
    /// - May clear quarantine if good observation received
    public func process(
        patchId: String,
        rawVerdict: ObservationVerdict,
        timestamp: TimeInterval
    ) -> ObservationVerdict {
        switch rawVerdict {
        case .good:
            // Good observation clears quarantine
            quarantine.removeValue(forKey: patchId)
            return .good

        case .suspect:
            // Add to quarantine, check threshold
            var entry = quarantine[patchId] ?? QuarantineEntry(timestamp: timestamp, consecutiveCount: 0)

            // Check if previous entry is stale
            if timestamp - entry.timestamp > Self.quarantineTimeoutSec {
                entry = QuarantineEntry(timestamp: timestamp, consecutiveCount: 0)
            }

            entry.consecutiveCount += 1
            entry.timestamp = timestamp
            quarantine[patchId] = entry

            // Upgrade to bad if threshold reached
            if entry.consecutiveCount >= Self.quarantineThreshold {
                quarantine.removeValue(forKey: patchId)
                return .bad
            }

            return .suspect

        case .bad:
            // Already confirmed bad, pass through
            quarantine.removeValue(forKey: patchId)
            return .bad
        }
    }

    /// Clean up stale entries
    public func cleanup(currentTime: TimeInterval) {
        quarantine = quarantine.filter { _, entry in
            currentTime - entry.timestamp < Self.quarantineTimeoutSec
        }
    }
}
```

**File:** `Core/Evidence/AnomalyQuarantine.swift`

---

### 2.3 Robust Statistics for Outlier Suppression

**Purpose:** Automatically downweight outlier observations without explicit bad judgment.

```swift
/// Robust statistics for outlier suppression
public enum RobustStatistics {

    /// Huber loss threshold
    public static let huberDelta: Double = 0.1

    /// Compute Huber weight for observation
    /// - Observations close to current evidence get full weight
    /// - Outliers get reduced weight
    public static func huberWeight(
        newQuality: Double,
        currentEvidence: Double
    ) -> Double {
        let residual = abs(newQuality - currentEvidence)

        if residual <= huberDelta {
            return 1.0  // Full weight for small residuals
        } else {
            return huberDelta / residual  // Reduced weight for outliers
        }
    }

    /// Apply robust weighting to quality
    public static func robustQuality(
        rawQuality: Double,
        currentEvidence: Double
    ) -> Double {
        let weight = huberWeight(newQuality: rawQuality, currentEvidence: currentEvidence)
        // Blend towards current evidence for outliers
        return weight * rawQuality + (1 - weight) * currentEvidence
    }
}

// Use in ledger update:
public func update(patchId: String, ledgerQuality: Double, ...) {
    let currentEvidence = patches[patchId]?.evidence ?? 0.0
    let robustQuality = RobustStatistics.robustQuality(
        rawQuality: ledgerQuality,
        currentEvidence: currentEvidence
    )
    // Use robustQuality instead of raw ledgerQuality
}
```

**File:** `Core/Evidence/RobustStatistics.swift`

---

### 2.4 Evidence Locking for High-Confidence Patches

**Purpose:** Once a patch reaches high confidence, protect it from erroneous penalties.

```swift
/// Evidence locking configuration
public enum EvidenceLocking {

    /// Evidence threshold for locking
    public static let lockThreshold: Double = 0.85

    /// Minimum observations for locking
    public static let minObservationsForLock: Int = 20

    /// Check if patch should be locked
    public static func isLocked(evidence: Double, observationCount: Int) -> Bool {
        return evidence >= lockThreshold && observationCount >= minObservationsForLock
    }
}

// In PatchEvidenceMap.update():
if EvidenceLocking.isLocked(evidence: entry.evidence, observationCount: entry.observationCount) {
    // Locked patch: only allow evidence increases, no penalties
    if verdict == .good && ledgerQuality > entry.evidence {
        entry.evidence = ledgerQuality
        entry.bestFrameId = frameId
    }
    entry.lastUpdate = timestamp
    entry.observationCount += 1
    patches[patchId] = entry
    return  // Skip normal update logic
}
```

**File:** `Core/Evidence/EvidenceLocking.swift`

---

### 2.5 View Diversity Tracking

**Purpose:** Reward observations from diverse view angles, not repeated same-angle spam.

```swift
/// View diversity tracker
public final class ViewDiversityTracker {

    /// Angle bucket size in degrees
    public static let angleBucketSize: Float = 15.0

    /// Maximum diversity score
    public static let maxDiversityScore: Double = 1.0

    /// Observed angle buckets per patch
    private var observedBuckets: [String: Set<Int>] = [:]

    /// Add observation and compute novelty
    public func addObservation(
        patchId: String,
        viewAngle: Float  // Degrees
    ) -> Double {
        let bucket = Int(viewAngle / Self.angleBucketSize)

        var buckets = observedBuckets[patchId] ?? Set<Int>()
        let isNew = buckets.insert(bucket).inserted
        observedBuckets[patchId] = buckets

        if isNew {
            return Self.maxDiversityScore  // New angle = full novelty
        }

        // Same angle bucket = reduced novelty
        return 0.3
    }

    /// Compute diversity score for patch
    public func diversityScore(for patchId: String) -> Double {
        let buckets = observedBuckets[patchId] ?? Set<Int>()

        // 6 buckets (90 degrees / 15) = full diversity
        return min(Self.maxDiversityScore, Double(buckets.count) / 6.0)
    }

    /// Reset for new session
    public func reset() {
        observedBuckets.removeAll()
    }
}
```

**File:** `Core/Evidence/ViewDiversityTracker.swift`

---

### 2.6 Token Bucket Rate Limiter

**Purpose:** More robust rate limiting than simple time check.

```swift
/// Token bucket rate limiter
public final class TokenBucketLimiter {

    /// Tokens per second
    public let refillRate: Double

    /// Maximum tokens (bucket size)
    public let maxTokens: Double

    /// Current tokens per patch
    private var tokens: [String: Double] = [:]

    /// Last refill time per patch
    private var lastRefill: [String: TimeInterval] = [:]

    public init(refillRate: Double = 10.0, maxTokens: Double = 10.0) {
        self.refillRate = refillRate
        self.maxTokens = maxTokens
    }

    /// Try to consume a token for patch
    /// - Returns: true if token available, false if rate limited
    public func tryConsume(patchId: String, timestamp: TimeInterval) -> Bool {
        // Refill tokens
        refill(patchId: patchId, timestamp: timestamp)

        // Check if token available
        let currentTokens = tokens[patchId] ?? maxTokens

        if currentTokens >= 1.0 {
            tokens[patchId] = currentTokens - 1.0
            return true
        }

        return false  // Rate limited
    }

    /// Refill tokens based on elapsed time
    private func refill(patchId: String, timestamp: TimeInterval) {
        let lastTime = lastRefill[patchId] ?? timestamp
        let elapsed = timestamp - lastTime

        if elapsed > 0 {
            let currentTokens = tokens[patchId] ?? maxTokens
            let newTokens = min(maxTokens, currentTokens + elapsed * refillRate)
            tokens[patchId] = newTokens
            lastRefill[patchId] = timestamp
        }
    }

    /// Reset
    public func reset() {
        tokens.removeAll()
        lastRefill.removeAll()
    }
}
```

**File:** `Core/Evidence/TokenBucketLimiter.swift`

---

## Part 3: Updated File Structure

```
Core/Evidence/
├── Observation.swift                 # (existing, unchanged)
├── ObservationVerdict.swift          # NEW: Verdict enum
├── PenaltyConfig.swift               # (existing, unchanged)
├── PatchEvidenceMap.swift            # UPDATED: verdict, locking
├── SplitLedger.swift                 # NEW: Gate + Soft ledgers
├── PatchDisplayMap.swift             # NEW: Monotonic patch display
├── EvidenceLayers.swift              # UPDATED: split ledger, delta tracker
├── EvidenceEngine.swift              # UPDATED: quarantine, diversity
├── DeltaTracker.swift                # NEW: Raw + EMA delta
├── SpamProtection.swift              # NEW: Triple-layer protection
├── AnomalyQuarantine.swift           # NEW: Multi-frame verdict
├── RobustStatistics.swift            # NEW: Huber weighting
├── EvidenceLocking.swift             # NEW: High-confidence lock
├── ViewDiversityTracker.swift        # NEW: Angle diversity
├── TokenBucketLimiter.swift          # NEW: Rate limiting
├── ConfidenceDecay.swift             # NEW: Stale patch decay
├── PatchIdStrategy.swift             # NEW: Tile/Voxel strategy
├── DeterministicJSONEncoder.swift    # NEW: Cross-platform JSON
├── ColorMapping.swift                # (existing, unchanged)
├── DynamicWeights.swift              # (existing, unchanged)
├── MetricSmoother.swift              # (existing, unchanged)
├── EvidenceState.swift               # UPDATED: version compat
└── EvidenceError.swift               # (existing, unchanged)
```

---

## Part 4: Updated Constants

```swift
/// EvidenceConstants (updated)
public enum EvidenceConstants {

    // ... existing constants ...

    // MARK: - Spam Protection (NEW)

    /// Time density minimum interval (ms)
    public static let minUpdateIntervalMs: Double = 120.0

    /// Minimum novelty to write to ledger
    public static let minNoveltyForLedger: Double = 0.1

    // MARK: - Anomaly Quarantine (NEW)

    /// Consecutive suspect frames for bad upgrade
    public static let quarantineThreshold: Int = 3

    /// Quarantine entry timeout (seconds)
    public static let quarantineTimeoutSec: Double = 1.0

    // MARK: - Confidence Decay (NEW)

    /// Confidence decay half-life (seconds)
    public static let confidenceHalfLifeSec: Double = 60.0

    // MARK: - Evidence Locking (NEW)

    /// Evidence threshold for locking
    public static let lockThreshold: Double = 0.85

    /// Minimum observations for locking
    public static let minObservationsForLock: Int = 20

    // MARK: - Robust Statistics (NEW)

    /// Huber loss delta
    public static let huberDelta: Double = 0.1

    // MARK: - View Diversity (NEW)

    /// Angle bucket size (degrees)
    public static let angleBucketSize: Float = 15.0

    // MARK: - Token Bucket (NEW)

    /// Tokens per second refill rate
    public static let tokenRefillRate: Double = 10.0

    /// Maximum tokens per patch
    public static let maxTokensPerPatch: Double = 10.0

    // MARK: - Patch Strategy (NEW)

    /// PR2 tile size (pixels)
    public static let defaultTileSize: Int = 32

    /// PR3 voxel size (meters)
    public static let defaultVoxelSize: Float = 0.03

    // MARK: - JSON Encoding (NEW)

    /// Float quantization precision
    public static let floatPrecision: Int = 4
}
```

---

## Part 5: Summary of Changes

| Category | Change | Files Affected |
|----------|--------|----------------|
| **Critical Fix #1** | Split GateLedger/SoftLedger | SplitLedger.swift, EvidenceLayers.swift |
| **Critical Fix #2** | ObservationVerdict enum | ObservationVerdict.swift, PatchEvidenceMap.swift |
| **Critical Fix #3** | DeltaEMA for smooth animation | DeltaTracker.swift, EvidenceLayers.swift |
| **Critical Fix #4** | Triple-layer spam protection | SpamProtection.swift, TokenBucketLimiter.swift |
| **Critical Fix #5** | PatchDisplayMap (monotonic) | PatchDisplayMap.swift, EvidenceLayers.swift |
| **Critical Fix #6** | Deterministic JSON | DeterministicJSONEncoder.swift, EvidenceState.swift |
| **Critical Fix #7** | PatchIdStrategy | PatchIdStrategy.swift |
| **Enhancement #1** | Confidence decay | ConfidenceDecay.swift |
| **Enhancement #2** | Anomaly quarantine | AnomalyQuarantine.swift |
| **Enhancement #3** | Robust statistics | RobustStatistics.swift |
| **Enhancement #4** | Evidence locking | EvidenceLocking.swift |
| **Enhancement #5** | View diversity | ViewDiversityTracker.swift |
| **Enhancement #6** | Token bucket | TokenBucketLimiter.swift |

---

## Part 6: Implementation Order

1. **Phase 1 (Critical):** ObservationVerdict, SplitLedger, PatchDisplayMap
2. **Phase 2 (Critical):** DeltaTracker, SpamProtection
3. **Phase 3 (Critical):** DeterministicJSONEncoder, PatchIdStrategy
4. **Phase 4 (Enhancement):** AnomalyQuarantine, RobustStatistics
5. **Phase 5 (Enhancement):** ConfidenceDecay, EvidenceLocking
6. **Phase 6 (Enhancement):** ViewDiversityTracker, TokenBucketLimiter
7. **Phase 7:** Update tests for all new components

---

**Document Version:** Patch V2
**Author:** Claude Code
**Last Updated:** 2026-01-29
