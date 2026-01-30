# PR2 Evidence System Foundation - Detailed Implementation Prompt

**Document Version:** 2.0 (Hardened)
**Status:** LOCKED (Patch V4)
**Created:** 2026-01-29
**Locked:** 2026-01-29
**Scope:** PR2 - Three-Layer Evidence System Foundation

---

## Part 0: Immutable Constraints (MUST NOT VIOLATE)

### 0.1 Architectural Constraints

```
┌─────────────────────────────────────────────────────────────────┐
│                    THREE IRON LAWS                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. ALL CODE MUST RUN ON-DEVICE                                 │
│     Cloud only handles: Training + Rendering + Storage          │
│     All inference, all debugging → mobile device                │
│                                                                 │
│  2. CROSS-PLATFORM CONSISTENCY IS MANDATORY                     │
│     iOS / Android / Web must have identical user experience     │
│     All on-device code must consider cross-platform abstraction │
│                                                                 │
│  3. USER NEVER SEES EVIDENCE REGRESSION                         │
│     UI is monotonic (only gets brighter)                        │
│     System can internally correct errors                        │
│     Error correction manifests as "slower brightening"          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 0.2 Product Philosophy

```
In the user's world, "re-capture" or "retry" does NOT exist.
The only thing users see: "Is this area getting brighter?"

UI NEVER shows text.
Users only see: Black → Gray → White → Original Color
Users only do one thing: Point, rotate, get closer, fill gaps
All "why isn't it working" exists ONLY in the algorithm
```

### 0.3 PR2 Scope Boundaries

**MUST DO in PR2:**
- Three-layer evidence architecture (ledger + display + delta)
- Color mapping (E_display → Black/Gray/White/Original)
- Dynamic weights (early: bias Gate, late: bias Soft)
- Time-window smoothing for jittery metrics
- Codable JSON serialization for cross-platform

**MUST NOT DO in PR2:**
- Gate/Soft gain functions (that's PR3/PR4)
- Depth fusion or edge classification (that's PR4)
- Capture control (that's PR5)
- Any UI code changes

---

## Part 1: Hardened Rules (COPY VERBATIM INTO IMPLEMENTATION)

### 1.1 Rule A: Ledger Input Closure

```swift
// ❌ WRONG - DO NOT USE observation.quality for ledger
ledger.update(quality: observation.quality)  // FORBIDDEN

// ✅ CORRECT - Use SplitLedger with separate updates
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

**Rationale:** `Observation.quality` is a placeholder in PR2. Using it would pollute the ledger with garbage values. PR3/PR4 will compute real `gateQuality`/`softQuality` and pass them explicitly.

**Implementation:**
- Remove `quality` field from `Observation` struct entirely
- Use SplitLedger with separate gateLedger and softLedger updates
- Gate ledger receives gateQuality only
- Soft ledger receives softQuality only (and only if gateQuality > softWriteRequiresGateMin)

### 1.2 Rule B: Gradual Penalty with Cooldown

```swift
// ❌ WRONG - Single frame can slash 0.2 (too brutal)
if isErroneous {
    entry.evidence = max(0, entry.evidence - 0.2)
}

// ✅ CORRECT - Gradual penalty with streak and cooldown
struct PenaltyConfig {
    static let basePenalty: Double = 0.05          // Reduced from 0.2
    static let maxPenaltyPerUpdate: Double = 0.15  // Hard cap
    static let errorCooldownSec: Double = 1.0      // Only penalize if recent good update
    static let maxErrorStreak: Int = 5             // Streak cap
}

func computePenalty(
    errorStreak: Int,
    lastGoodUpdate: TimeInterval,
    currentTime: TimeInterval
) -> Double {
    // Only penalize if there was a recent good update
    guard currentTime - lastGoodUpdate < PenaltyConfig.errorCooldownSec else {
        return 0.0  // Don't "whip the corpse" of old patches
    }

    // Sigmoid-based penalty that increases with streak
    let streakFactor = sigmoid(Double(min(errorStreak, PenaltyConfig.maxErrorStreak)) / 3.0)
    let penalty = PenaltyConfig.basePenalty * streakFactor

    return min(penalty, PenaltyConfig.maxPenaltyPerUpdate)
}
```

**Rationale:** Single-frame false positives (transient reflections, motion blur) would permanently damage evidence. Gradual penalty with cooldown makes error correction behave like "auto-braking" instead of "decapitation".

### 1.3 Rule C: No Frame-Spam Reward

```swift
// ❌ WRONG - observationCount as weight rewards frame spam
let weight = Double(entry.observationCount)
weightedSum += entry.evidence * weight

// ✅ CORRECT - Capped weight or log-based weight
func patchWeight(observationCount: Int) -> Double {
    // Option 1: Capped weight (recommended)
    return min(1.0, Double(observationCount) / 8.0)

    // Option 2: Log-based weight
    // return log1p(Double(observationCount))
}

// Total evidence is MEAN of patch evidences, not frame-weighted
func totalEvidence() -> Double {
    guard !patches.isEmpty else { return 0.0 }

    var weightedSum: Double = 0
    var totalWeight: Double = 0

    for (_, entry) in patches {
        let w = patchWeight(observationCount: entry.observationCount)
        weightedSum += entry.evidence * w
        totalWeight += w
    }

    return totalWeight > 0 ? weightedSum / totalWeight : 0.0
}
```

**Rationale:** Users shouldn't gain evidence by pointing at the same spot and spamming 200 frames. We want "more area covered" not "same area more dense". The weight cap ensures each patch contributes fairly.

### 1.4 Rule D: Delta Calculation Must Be Correct

```swift
// ❌ WRONG - Delta calculated AFTER display update (always ~0)
gateDisplay = max(gateDisplay, smoothedGate)
gateDelta = max(0, smoothedGate - gateDisplay + 0.001)  // Always 0.001!

// ✅ CORRECT - Delta calculated BEFORE display update
let prevGateDisplay = gateDisplay
gateDisplay = max(gateDisplay, smoothedGate)
gateDelta = gateDisplay - prevGateDisplay  // Actual delta

// DO NOT artificially add minDelta. If delta is 0, it's 0.
// "Always some growth" should be in UI animation, not fake delta.
```

**Rationale:** The previous code computed delta AFTER updating display, so `smoothedGate - gateDisplay` was always ≤ 0, making delta always equal to minDelta. This masked real progress/stagnation.

### 1.5 Rule E: Cross-Platform Serialization Must Be Codable JSON

```swift
// ❌ WRONG - [String: Any] is Swift-specific, not cross-platform
func exportState() -> [String: Any] { ... }
func loadState(from data: [String: Any]) { ... }

// ✅ CORRECT - Codable structs with JSON encoding
public struct EvidenceState: Codable {
    public let patches: [String: PatchSnapshot]
    public let gateDisplay: Double
    public let softDisplay: Double
    public let lastTotalDisplay: Double
}

public struct PatchSnapshot: Codable {
    public let evidence: Double
    public let lastUpdate: TimeInterval
    public let observationCount: Int
    public let bestFrameId: String?
    public let errorCount: Int
    public let errorStreak: Int
    public let lastGoodUpdate: TimeInterval?
}

// Export as JSON Data
func exportStateJSON() throws -> Data {
    let state = EvidenceState(...)
    return try JSONEncoder().encode(state)
}

// Import from JSON Data
func loadStateJSON(_ data: Data) throws {
    let state = try JSONDecoder().decode(EvidenceState.self, from: data)
    // Apply state...
}
```

**Rationale:** `[String: Any]` cannot be reliably parsed by Android/Web. Cross-platform consistency requires schema-defined JSON that all platforms can parse identically.

### 1.6 Rule F: Patch-Level vs Global Display Clarity

```swift
// PR2 Design Decision: NO patch-level softDisplay
// Only:
//   - patchLedgerEvidence (per patch)
//   - globalGateDisplay (global, monotonic)
//   - globalSoftDisplay (global, monotonic)

// For patch color mapping, use hybrid formula:
func colorEvidenceForPatch(_ patchId: String) -> Double {
    let patchEvidence = ledger.evidence(for: patchId)
    let globalDisplay = totalDisplay

    // Hybrid: 70% local, 30% global
    // This ensures "black holes" remain visible, but global progress helps
    return 0.7 * patchEvidence + 0.3 * globalDisplay
}
```

**Rationale:** Mixing global `softDisplay` with per-patch ledger evidence without defining patch-level soft evidence creates semantic confusion. PR2 keeps it simple: patches have ledger evidence, global has display evidence.

### 1.7 Rule G: MetricSmoother Window Size Constraint

```swift
// ❌ WRONG - Arbitrary window sizes cause performance issues
public init(windowSize: Int = 5) {
    self.windowSize = max(1, windowSize)  // Allows any size
}

// ✅ CORRECT - Constrained to known-good values
public enum AllowedWindowSize: Int, CaseIterable {
    case small = 3
    case medium = 5
    case large = 7
    case extraLarge = 9
}

public init(windowSize: AllowedWindowSize = .medium) {
    self.windowSize = windowSize.rawValue
}
```

**Rationale:** Using `sorted()` for median is O(n log n). For small fixed windows this is fine. Arbitrary large windows would hurt performance. Constraining to {3,5,7,9} ensures predictable behavior.

---

## Part 2: Architecture Design

### 2.1 Three-Layer Evidence System

```
┌─────────────────────────────────────────────────────────────────┐
│                    THREE-LAYER EVIDENCE SYSTEM                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Layer 1: E_ledger (True Ledger)                                │
│  ├─ Stored at patch/voxel granularity                           │
│  ├─ CAN decrease (error correction)                             │
│  ├─ NOT visible to users                                        │
│  ├─ Uses gradual penalty with cooldown                          │
│  └─ Input: gateQuality → gateLedger, softQuality → softLedger │
│                                                                 │
│  Layer 2: E_display (Display Evidence)                          │
│  ├─ EMA-smoothed from E_ledger                                  │
│  ├─ MONOTONIC (never decreases)                                 │
│  ├─ Visible to users via color                                  │
│  └─ Formula: E_display = max(E_display, EMA(E_ledger))         │
│                                                                 │
│  Layer 3: E_delta (Delta Evidence)                              │
│  ├─ Determines "how fast is it brightening"                     │
│  ├─ Computed BEFORE display update                              │
│  ├─ No artificial minDelta added                                │
│  └─ Formula: E_delta = newDisplay - prevDisplay                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow

```
Captured Frame
      │
      ▼
┌────────────────────┐
│    Observation     │  ← patchId, isErroneous, errorType, timestamp, frameId
└─────────┬──────────┘    (NO quality field used for ledger!)
          │
          ▼
┌────────────────────┐
│  Update SplitLedger │  ← gateLedger.update(gateQuality), softLedger.update(softQuality)
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Update Ledger     │  ← Gradual penalty with cooldown for errors
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Compute Total     │  ← Mean of patch evidences (capped weights)
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Update Display    │  ← prevDisplay stored, then max(prev, EMA(total))
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Compute Delta     │  ← delta = newDisplay - prevDisplay
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Color Mapping     │  ← E_display → Black/Gray/White/Original
└────────────────────┘
```

### 2.3 File Structure

```
Core/
├── Evidence/
│   ├── EvidenceLayers.swift          # Main three-layer structure
│   ├── PatchEvidenceMap.swift        # Patch-level storage
│   ├── Observation.swift             # Observation data (no quality field)
│   ├── EvidenceEngine.swift          # Unified update engine
│   ├── ColorMapping.swift            # Evidence → Color
│   ├── DynamicWeights.swift          # Gate/Soft weight scheduler
│   ├── MetricSmoother.swift          # Time-window median smoother
│   ├── PenaltyConfig.swift           # Gradual penalty constants
│   └── EvidenceState.swift           # Codable serialization
├── Constants/
│   └── EvidenceConstants.swift       # All evidence-related constants
└── Protocols/
    └── EvidenceProtocol.swift        # Cross-platform protocol (Codable)

Tests/
└── Evidence/
    ├── EvidenceLayersTests.swift
    ├── PatchEvidenceMapTests.swift
    ├── DeltaCalculationTests.swift
    ├── PenaltyGradualTests.swift
    ├── SerializationRoundTripTests.swift
    └── EvidenceEngineIntegrationTests.swift
```

---

## Part 3: Detailed Implementation Specifications

### 3.1 Observation (No quality field for ledger)

```swift
import Foundation

/// Observation data from a captured frame
/// NOTE: This struct does NOT contain a quality field for ledger updates.
/// Quality is computed externally by Gate/Soft functions and passed separately.
public struct Observation: Codable, Sendable {

    /// Patch ID this observation belongs to
    /// Uses spatial hash or voxel ID
    public let patchId: String

    /// Whether this observation is erroneous
    /// - Dynamic object entered/left frame
    /// - ARKit depth distortion (glass, mirrors)
    /// - Auto-exposure/white-balance drift
    public let isErroneous: Bool

    /// Observation timestamp
    public let timestamp: TimeInterval

    /// Source frame ID
    public let frameId: String

    /// Error type (if isErroneous = true)
    public let errorType: ObservationErrorType?

    public init(
        patchId: String,
        isErroneous: Bool,
        timestamp: TimeInterval,
        frameId: String,
        errorType: ObservationErrorType? = nil
    ) {
        self.patchId = patchId
        self.isErroneous = isErroneous
        self.timestamp = timestamp
        self.frameId = frameId
        self.errorType = errorType
    }
}

/// Observation error types
public enum ObservationErrorType: String, Codable, Sendable {
    case dynamicObject       // Moving object in scene
    case depthDistortion     // Depth sensor failure (glass, mirrors)
    case exposureDrift       // Auto-exposure changed
    case whiteBalanceDrift   // White balance shifted
    case motionBlur          // Camera moved too fast
}
```

### 3.2 PenaltyConfig (Gradual penalty constants)

```swift
import Foundation

/// Configuration for gradual error penalty
public enum PenaltyConfig {

    /// Base penalty per error observation
    /// Reduced from 0.2 to 0.05 to avoid single-frame damage
    public static let basePenalty: Double = 0.05

    /// Maximum penalty that can be applied in a single update
    /// Prevents catastrophic evidence loss
    public static let maxPenaltyPerUpdate: Double = 0.15

    /// Cooldown period: only penalize if last good update was within this window
    /// Prevents "whipping the corpse" of stale patches
    public static let errorCooldownSec: Double = 1.0

    /// Maximum error streak to consider
    /// Beyond this, penalty is capped
    public static let maxErrorStreak: Int = 5

    /// Compute penalty based on error streak and timing
    public static func computePenalty(
        errorStreak: Int,
        lastGoodUpdate: TimeInterval?,
        currentTime: TimeInterval
    ) -> Double {
        // Only penalize if there was a recent good update
        guard let lastGood = lastGoodUpdate,
              currentTime - lastGood < errorCooldownSec else {
            return 0.0
        }

        // Sigmoid-based penalty that increases with streak
        let cappedStreak = min(errorStreak, maxErrorStreak)
        let streakFactor = sigmoid(Double(cappedStreak) / 3.0)
        let penalty = basePenalty * (1.0 + streakFactor)

        return min(penalty, maxPenaltyPerUpdate)
    }

    /// Sigmoid function for smooth penalty curve
    private static func sigmoid(_ x: Double) -> Double {
        return 1.0 / (1.0 + exp(-x))
    }
}
```

### 3.3 PatchEvidenceMap (With corrected weighting)

```swift
import Foundation

/// Patch-level evidence storage
public final class PatchEvidenceMap {

    /// Patch evidence entry
    public struct PatchEntry: Codable {
        /// Current evidence value [0, 1]
        public var evidence: Double

        /// Last update timestamp
        public var lastUpdate: TimeInterval

        /// Observation count (for weight calculation)
        public var observationCount: Int

        /// Best observation frame ID
        public var bestFrameId: String?

        /// Total error count (for analytics)
        public var errorCount: Int

        /// Consecutive error streak (for penalty calculation)
        public var errorStreak: Int

        /// Last good (non-error) update timestamp
        public var lastGoodUpdate: TimeInterval?

        public init(
            evidence: Double = 0,
            lastUpdate: TimeInterval = 0,
            observationCount: Int = 0,
            bestFrameId: String? = nil,
            errorCount: Int = 0,
            errorStreak: Int = 0,
            lastGoodUpdate: TimeInterval? = nil
        ) {
            self.evidence = evidence
            self.lastUpdate = lastUpdate
            self.observationCount = observationCount
            self.bestFrameId = bestFrameId
            self.errorCount = errorCount
            self.errorStreak = errorStreak
            self.lastGoodUpdate = lastGoodUpdate
        }
    }

    /// Patch ID → Entry storage
    private var patches: [String: PatchEntry] = [:]

    /// Weight cap for observation count (prevents frame spam reward)
    private static let weightCapDenominator: Double = 8.0

    public init() {}

    // MARK: - Read

    /// Get evidence for a specific patch
    public func evidence(for patchId: String) -> Double {
        return patches[patchId]?.evidence ?? 0.0
    }

    /// Compute patch weight (capped to prevent frame spam)
    private func patchWeight(for entry: PatchEntry) -> Double {
        return min(1.0, Double(entry.observationCount) / Self.weightCapDenominator)
    }

    /// Get total evidence as weighted mean of patches
    /// Uses capped weights to prevent frame spam from dominating
    public func totalEvidence() -> Double {
        guard !patches.isEmpty else { return 0.0 }

        var weightedSum: Double = 0
        var totalWeight: Double = 0

        for (_, entry) in patches {
            let w = patchWeight(for: entry)
            weightedSum += entry.evidence * w
            totalWeight += w
        }

        return totalWeight > 0 ? weightedSum / totalWeight : 0.0
    }

    /// Get patch count
    public var count: Int { patches.count }

    /// Get all patch IDs
    public var allPatchIds: [String] { Array(patches.keys) }

    // MARK: - Write

    /// Update patch evidence with gradual penalty for errors
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - ledgerQuality: Quality from Gate/Soft (NOT observation.quality)
    ///   - isErroneous: Whether this observation is erroneous
    ///   - frameId: Source frame ID
    ///   - timestamp: Current timestamp
    public func update(
        patchId: String,
        ledgerQuality: Double,
        isErroneous: Bool,
        frameId: String,
        timestamp: TimeInterval
    ) {
        var entry = patches[patchId] ?? PatchEntry(lastUpdate: timestamp)

        if isErroneous {
            // Error observation: apply gradual penalty
            entry.errorStreak += 1
            entry.errorCount += 1

            let penalty = PenaltyConfig.computePenalty(
                errorStreak: entry.errorStreak,
                lastGoodUpdate: entry.lastGoodUpdate,
                currentTime: timestamp
            )

            entry.evidence = max(0, entry.evidence - penalty)
        } else {
            // Good observation: reset error streak
            entry.errorStreak = 0
            entry.lastGoodUpdate = timestamp

            // Only update if quality is better
            if ledgerQuality > entry.evidence {
                entry.evidence = ledgerQuality
                entry.bestFrameId = frameId
            }
        }

        entry.lastUpdate = timestamp
        entry.observationCount += 1

        patches[patchId] = entry
    }

    /// Prune stale patches (for memory management)
    public func pruneStale(olderThan threshold: TimeInterval, currentTime: TimeInterval) {
        patches = patches.filter { _, entry in
            currentTime - entry.lastUpdate < threshold
        }
    }

    /// Reset all patches
    public func reset() {
        patches.removeAll()
    }

    // MARK: - Serialization (Codable)

    /// Export as Codable snapshot
    public func exportSnapshot() -> [String: PatchEntry] {
        return patches
    }

    /// Load from Codable snapshot
    public func loadSnapshot(_ snapshot: [String: PatchEntry]) {
        patches = snapshot
    }
}
```

### 3.4 EvidenceState (Codable serialization)

```swift
import Foundation

/// Codable state for cross-platform serialization
public struct EvidenceState: Codable, Sendable {

    /// All patch snapshots
    public let patches: [String: PatchEvidenceMap.PatchEntry]

    /// Gate display evidence (global, monotonic)
    public let gateDisplay: Double

    /// Soft display evidence (global, monotonic)
    public let softDisplay: Double

    /// Last computed total display (for dynamic weights)
    public let lastTotalDisplay: Double

    /// Schema version for forward compatibility
    public let schemaVersion: String

    /// Export timestamp
    public let exportedAt: TimeInterval

    public static let currentSchemaVersion = "2.0"

    public init(
        patches: [String: PatchEvidenceMap.PatchEntry],
        gateDisplay: Double,
        softDisplay: Double,
        lastTotalDisplay: Double,
        exportedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.patches = patches
        self.gateDisplay = gateDisplay
        self.softDisplay = softDisplay
        self.lastTotalDisplay = lastTotalDisplay
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
    }
}
```

### 3.5 EvidenceLayers (Corrected delta calculation)

```swift
import Foundation

/// Three-layer evidence system
public final class EvidenceLayers {

    // MARK: - Layer 1: True Ledger (can decrease)

    /// Patch-level evidence storage
    public let ledger: PatchEvidenceMap

    // MARK: - Layer 2: Display Evidence (monotonic)

    /// Gate display evidence (never decreases)
    public private(set) var gateDisplay: Double = 0.0

    /// Soft display evidence (never decreases)
    public private(set) var softDisplay: Double = 0.0

    /// Compute total display with dynamic weights
    public var totalDisplay: Double {
        let (gateWeight, softWeight) = DynamicWeights.weights(currentTotal: _lastTotalDisplay)
        return gateWeight * gateDisplay + softWeight * softDisplay
    }

    /// Last computed total display (for dynamic weight calculation)
    private var _lastTotalDisplay: Double = 0.0

    // MARK: - Layer 3: Delta Evidence

    /// Gate delta (computed BEFORE display update)
    public private(set) var gateDelta: Double = 0.0

    /// Soft delta (computed BEFORE display update)
    public private(set) var softDelta: Double = 0.0

    // MARK: - EMA Parameter

    /// EMA smoothing coefficient
    private let emaAlpha: Double = 0.1

    // MARK: - Initialization

    public init() {
        self.ledger = PatchEvidenceMap()
    }

    // MARK: - Update

    /// Process a new observation
    /// - Parameters:
    ///   - observation: Observation data (patchId, isErroneous, etc.)
    ///   - gateQuality: Gate quality [0,1] from PR3 GateGainFunctions
    ///   - softQuality: Soft quality [0,1] from PR4 SoftGainFunctions
    public func processObservation(
        _ observation: Observation,
        gateQuality: Double,
        softQuality: Double
    ) {
        // Step 1: Compute ledgerQuality (CORRECT - uses passed values, not observation.quality)
        // Use SplitLedger with separate updates (see Rule A implementation)

        // Step 2: Update ledger (with gradual penalty)
        ledger.update(
            patchId: observation.patchId,
            ledgerQuality: ledgerQuality,
            isErroneous: observation.isErroneous,
            frameId: observation.frameId,
            timestamp: observation.timestamp
        )

        // Step 3: Compute smoothed values
        let smoothedGate = emaAlpha * gateQuality + (1 - emaAlpha) * gateDisplay
        let smoothedSoft = emaAlpha * softQuality + (1 - emaAlpha) * softDisplay

        // Step 4: Store previous values (BEFORE update)
        let prevGateDisplay = gateDisplay
        let prevSoftDisplay = softDisplay

        // Step 5: Update display (monotonic)
        gateDisplay = max(gateDisplay, smoothedGate)
        softDisplay = max(softDisplay, smoothedSoft)

        // Step 6: Compute delta (CORRECT - uses prev values)
        gateDelta = gateDisplay - prevGateDisplay
        softDelta = softDisplay - prevSoftDisplay

        // Step 7: Update last total display
        _lastTotalDisplay = totalDisplay
    }

    /// Reset for new capture session
    public func reset() {
        ledger.reset()
        gateDisplay = 0.0
        softDisplay = 0.0
        gateDelta = 0.0
        softDelta = 0.0
        _lastTotalDisplay = 0.0
    }

    // MARK: - Serialization

    /// Export state as Codable JSON
    public func exportStateJSON() throws -> Data {
        let state = EvidenceState(
            patches: ledger.exportSnapshot(),
            gateDisplay: gateDisplay,
            softDisplay: softDisplay,
            lastTotalDisplay: _lastTotalDisplay
        )
        return try JSONEncoder().encode(state)
    }

    /// Load state from Codable JSON
    public func loadStateJSON(_ data: Data) throws {
        let state = try JSONDecoder().decode(EvidenceState.self, from: data)

        // Validate schema version
        guard state.schemaVersion == EvidenceState.currentSchemaVersion else {
            throw EvidenceError.incompatibleSchemaVersion(
                expected: EvidenceState.currentSchemaVersion,
                found: state.schemaVersion
            )
        }

        ledger.loadSnapshot(state.patches)
        gateDisplay = state.gateDisplay
        softDisplay = state.softDisplay
        _lastTotalDisplay = state.lastTotalDisplay
    }
}

/// Evidence-related errors
public enum EvidenceError: Error {
    case incompatibleSchemaVersion(expected: String, found: String)
}
```

### 3.6 DynamicWeights (Gate/Soft scheduler)

```swift
import Foundation

/// Dynamic weight calculation
/// - Early stage: Bias toward Gate (faster initial progress)
/// - Late stage: Bias toward Soft (quality determines final achievement)
public enum DynamicWeights {

    // MARK: - Configuration

    /// Transition start point
    public static let transitionStart: Double = 0.45

    /// Transition end point
    public static let transitionEnd: Double = 0.75

    /// Early stage Gate weight
    public static let earlyGateWeight: Double = 0.65

    /// Late stage Gate weight
    public static let lateGateWeight: Double = 0.35

    // MARK: - Computation

    /// Compute Gate/Soft weights based on current progress
    public static func weights(currentTotal: Double) -> (gate: Double, soft: Double) {
        let t = smoothstep(transitionStart, transitionEnd, currentTotal)
        let gateWeight = lerp(earlyGateWeight, lateGateWeight, t)
        let softWeight = 1.0 - gateWeight

        return (gateWeight, softWeight)
    }

    /// Smoothstep interpolation
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Linear interpolation
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        return a + (b - a) * t
    }

    /// Clamp value
    private static func clamp(_ value: Double, _ minVal: Double, _ maxVal: Double) -> Double {
        return min(max(value, minVal), maxVal)
    }
}
```

### 3.7 ColorMapping (Evidence to color)

```swift
import Foundation
import simd

/// Color states for evidence visualization
public enum ColorState: String, Codable, Equatable, Sendable {
    case black       // E_display < 0.20
    case darkGray    // 0.20 ≤ E_display < 0.45
    case lightGray   // 0.45 ≤ E_display < 0.70
    case white       // 0.70 ≤ E_display < 0.88
    case original    // E_display ≥ 0.88 AND E_soft ≥ 0.75

    /// Get RGBA color for rendering
    public var color: SIMD4<Float> {
        switch self {
        case .black:     return SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
        case .darkGray:  return SIMD4<Float>(0.3, 0.3, 0.3, 1.0)
        case .lightGray: return SIMD4<Float>(0.6, 0.6, 0.6, 1.0)
        case .white:     return SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        case .original:  return SIMD4<Float>(0.0, 0.0, 0.0, 0.0)  // Transparent
        }
    }

    /// Is this S5 quality?
    public var isS5: Bool {
        return self == .original
    }
}

/// Color mapping from evidence to visual state
public enum ColorMapping {

    // MARK: - Thresholds

    public static let blackThreshold: Double = 0.20
    public static let darkGrayThreshold: Double = 0.45
    public static let lightGrayThreshold: Double = 0.70
    public static let whiteThreshold: Double = 0.88
    public static let originalMinSoftEvidence: Double = 0.75

    // MARK: - Mapping

    /// Map evidence values to color state
    public static func map(totalDisplay: Double, softDisplay: Double) -> ColorState {
        // S5 condition: total ≥ 0.88 AND soft ≥ 0.75
        if totalDisplay >= whiteThreshold && softDisplay >= originalMinSoftEvidence {
            return .original
        }

        // Threshold-based mapping
        if totalDisplay < blackThreshold {
            return .black
        } else if totalDisplay < darkGrayThreshold {
            return .darkGray
        } else if totalDisplay < lightGrayThreshold {
            return .lightGray
        } else {
            return .white
        }
    }

    /// Get transition progress within current color band [0, 1]
    public static func transitionProgress(totalDisplay: Double) -> Double {
        if totalDisplay < blackThreshold {
            return totalDisplay / blackThreshold
        } else if totalDisplay < darkGrayThreshold {
            return (totalDisplay - blackThreshold) / (darkGrayThreshold - blackThreshold)
        } else if totalDisplay < lightGrayThreshold {
            return (totalDisplay - darkGrayThreshold) / (lightGrayThreshold - darkGrayThreshold)
        } else if totalDisplay < whiteThreshold {
            return (totalDisplay - lightGrayThreshold) / (whiteThreshold - lightGrayThreshold)
        } else {
            return 1.0
        }
    }

    /// Blend between two colors for smooth animation
    public static func blendedColor(
        from fromState: ColorState,
        to toState: ColorState,
        progress: Double
    ) -> SIMD4<Float> {
        let fromColor = fromState.color
        let toColor = toState.color
        let t = Float(progress)

        return SIMD4<Float>(
            fromColor.x + (toColor.x - fromColor.x) * t,
            fromColor.y + (toColor.y - fromColor.y) * t,
            fromColor.z + (toColor.z - fromColor.z) * t,
            fromColor.w + (toColor.w - fromColor.w) * t
        )
    }
}
```

### 3.8 MetricSmoother (Constrained window sizes)

```swift
import Foundation

/// Allowed window sizes for median smoothing
public enum AllowedWindowSize: Int, CaseIterable, Sendable {
    case small = 3
    case medium = 5
    case large = 7
    case extraLarge = 9
}

/// Time-window median smoother for jittery metrics
/// Uses constrained window sizes to ensure predictable performance
public final class MetricSmoother {

    /// History buffer
    private var history: [Double] = []

    /// Window size
    private let windowSize: Int

    /// Initialize with constrained window size
    public init(windowSize: AllowedWindowSize = .medium) {
        self.windowSize = windowSize.rawValue
        self.history.reserveCapacity(windowSize.rawValue)
    }

    /// Add value and return smoothed result
    public func addAndSmooth(_ value: Double) -> Double {
        history.append(value)

        // Maintain window size
        if history.count > windowSize {
            history.removeFirst()
        }

        return median(of: history)
    }

    /// Get current smoothed value without adding
    public var currentSmoothed: Double {
        return history.isEmpty ? 0.0 : median(of: history)
    }

    /// Reset history
    public func reset() {
        history.removeAll(keepingCapacity: true)
    }

    /// Compute median
    /// For constrained window sizes (≤9), sorted() is efficient enough
    private func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }

        let sorted = values.sorted()
        let count = sorted.count

        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            return sorted[count / 2]
        }
    }
}
```

### 3.9 EvidenceEngine (Unified engine)

```swift
import Foundation

/// Unified evidence engine
/// Integrates all evidence components with correct data flow
public final class EvidenceEngine {

    // MARK: - Components

    /// Three-layer evidence system
    public let evidenceLayers: EvidenceLayers

    /// Metric smoothers for jittery signals
    private let depthEdgeSmoother: MetricSmoother
    private let occlusionSmoother: MetricSmoother
    private let holeRatioSmoother: MetricSmoother

    // MARK: - State

    /// Current color state
    public private(set) var currentColorState: ColorState = .black

    /// Previous color state (for change detection)
    private var previousColorState: ColorState = .black

    // MARK: - Callbacks

    /// Called when color state changes
    public var onColorStateChange: ((ColorState, ColorState) -> Void)?

    // MARK: - Initialization

    public init(smootherWindowSize: AllowedWindowSize = .medium) {
        self.evidenceLayers = EvidenceLayers()
        self.depthEdgeSmoother = MetricSmoother(windowSize: smootherWindowSize)
        self.occlusionSmoother = MetricSmoother(windowSize: smootherWindowSize)
        self.holeRatioSmoother = MetricSmoother(windowSize: smootherWindowSize)
    }

    // MARK: - Processing

    /// Process a frame observation
    /// - Parameters:
    ///   - observation: Observation data
    ///   - gateQuality: Gate quality from PR3 (placeholder 0.5 in PR2)
    ///   - softQuality: Soft quality from PR4 (placeholder 0.5 in PR2)
    ///   - rawDepthEdgeAlign: Raw depth-edge alignment (for smoothing)
    ///   - rawOcclusionSharpness: Raw occlusion sharpness (for smoothing)
    ///   - rawHoleRatio: Raw hole ratio (for smoothing)
    public func processFrame(
        observation: Observation,
        gateQuality: Double,
        softQuality: Double,
        rawDepthEdgeAlign: Double? = nil,
        rawOcclusionSharpness: Double? = nil,
        rawHoleRatio: Double? = nil
    ) {
        // Step 1: Smooth jittery metrics
        if let raw = rawDepthEdgeAlign {
            _ = depthEdgeSmoother.addAndSmooth(raw)
        }
        if let raw = rawOcclusionSharpness {
            _ = occlusionSmoother.addAndSmooth(raw)
        }
        if let raw = rawHoleRatio {
            _ = holeRatioSmoother.addAndSmooth(raw)
        }

        // Step 2: Update evidence layers
        evidenceLayers.processObservation(
            observation,
            gateQuality: gateQuality,
            softQuality: softQuality
        )

        // Step 3: Update color state
        updateColorState()
    }

    /// Update color state and fire callback if changed
    private func updateColorState() {
        let newState = ColorMapping.map(
            totalDisplay: evidenceLayers.totalDisplay,
            softDisplay: evidenceLayers.softDisplay
        )

        if newState != currentColorState {
            previousColorState = currentColorState
            currentColorState = newState
            onColorStateChange?(previousColorState, newState)
        }
    }

    // MARK: - Queries

    /// Get color evidence for a specific patch
    /// Uses hybrid formula: 70% local + 30% global
    public func colorEvidenceForPatch(_ patchId: String) -> Double {
        let patchEvidence = evidenceLayers.ledger.evidence(for: patchId)
        let globalDisplay = evidenceLayers.totalDisplay
        return 0.7 * patchEvidence + 0.3 * globalDisplay
    }

    /// Get color state for a specific patch
    public func colorStateForPatch(_ patchId: String) -> ColorState {
        let colorEvidence = colorEvidenceForPatch(patchId)
        return ColorMapping.map(
            totalDisplay: colorEvidence,
            softDisplay: evidenceLayers.softDisplay
        )
    }

    /// Get smoothed metric values
    public var smoothedDepthEdgeAlign: Double { depthEdgeSmoother.currentSmoothed }
    public var smoothedOcclusionSharpness: Double { occlusionSmoother.currentSmoothed }
    public var smoothedHoleRatio: Double { holeRatioSmoother.currentSmoothed }

    /// Get current Gate/Soft weights
    public var currentWeights: (gate: Double, soft: Double) {
        DynamicWeights.weights(currentTotal: evidenceLayers.totalDisplay)
    }

    // MARK: - Lifecycle

    /// Start new capture session
    public func startNewSession() {
        evidenceLayers.reset()
        depthEdgeSmoother.reset()
        occlusionSmoother.reset()
        holeRatioSmoother.reset()
        currentColorState = .black
        previousColorState = .black
    }

    // MARK: - Serialization

    /// Export state as JSON Data
    public func exportStateJSON() throws -> Data {
        return try evidenceLayers.exportStateJSON()
    }

    /// Load state from JSON Data
    public func loadStateJSON(_ data: Data) throws {
        try evidenceLayers.loadStateJSON(data)
        updateColorState()
    }
}
```

### 3.10 EvidenceConstants (All constants in one place)

```swift
import Foundation

/// All evidence-related constants
/// SSOT: Single Source of Truth for evidence system
public enum EvidenceConstants {

    // MARK: - EMA

    /// EMA smoothing coefficient (ledger → display)
    public static let emaAlpha: Double = 0.1

    // MARK: - Penalty

    /// Base penalty for error observations
    public static let basePenalty: Double = 0.05

    /// Maximum penalty per update
    public static let maxPenaltyPerUpdate: Double = 0.15

    /// Error cooldown period in seconds
    public static let errorCooldownSec: Double = 1.0

    /// Maximum error streak to consider
    public static let maxErrorStreak: Int = 5

    // MARK: - Weights

    /// Observation count weight cap denominator
    public static let weightCapDenominator: Double = 8.0

    /// Patch color blend: local weight
    public static let patchLocalWeight: Double = 0.7

    /// Patch color blend: global weight
    public static let patchGlobalWeight: Double = 0.3

    // MARK: - Dynamic Weights

    /// Weight transition start point
    public static let weightTransitionStart: Double = 0.45

    /// Weight transition end point
    public static let weightTransitionEnd: Double = 0.75

    /// Early stage Gate weight
    public static let earlyGateWeight: Double = 0.65

    /// Late stage Gate weight
    public static let lateGateWeight: Double = 0.35

    // MARK: - Color Mapping

    /// Black threshold
    public static let blackThreshold: Double = 0.20

    /// Dark gray threshold
    public static let darkGrayThreshold: Double = 0.45

    /// Light gray threshold
    public static let lightGrayThreshold: Double = 0.70

    /// White threshold (S5 total requirement)
    public static let whiteThreshold: Double = 0.88

    /// S5 minimum soft evidence requirement
    public static let s5MinSoftEvidence: Double = 0.75

    // MARK: - Stale Patch

    /// Stale patch threshold in seconds
    public static let patchStaleThreshold: TimeInterval = 300.0

    // MARK: - Smoother

    /// Default smoother window size
    public static let defaultSmootherWindowSize: AllowedWindowSize = .medium
}
```

### 3.11 EvidenceProtocol (Cross-platform protocol)

```swift
import Foundation

/// Cross-platform evidence protocol
/// All platforms (iOS/Android/Web) must implement this
public protocol EvidenceProtocol {

    // MARK: - Evidence Access

    /// Total display evidence (global, monotonic)
    var totalDisplay: Double { get }

    /// Gate display evidence
    var gateDisplay: Double { get }

    /// Soft display evidence
    var softDisplay: Double { get }

    /// Gate delta (last frame)
    var gateDelta: Double { get }

    /// Soft delta (last frame)
    var softDelta: Double { get }

    // MARK: - Patch Access

    /// Get evidence for a specific patch
    func evidenceForPatch(_ patchId: String) -> Double

    /// Get color evidence for a specific patch (hybrid formula)
    func colorEvidenceForPatch(_ patchId: String) -> Double

    // MARK: - Processing

    /// Process an observation
    func processObservation(
        _ observation: Observation,
        gateQuality: Double,
        softQuality: Double
    )

    // MARK: - Lifecycle

    /// Reset for new session
    func reset()

    // MARK: - Serialization (Codable JSON)

    /// Export state as JSON Data
    func exportStateJSON() throws -> Data

    /// Load state from JSON Data
    func loadStateJSON(_ data: Data) throws
}

// MARK: - Protocol Conformance

extension EvidenceLayers: EvidenceProtocol {

    public var gateDisplay: Double { self.gateDisplay }
    public var softDisplay: Double { self.softDisplay }
    public var gateDelta: Double { self.gateDelta }
    public var softDelta: Double { self.softDelta }

    public func evidenceForPatch(_ patchId: String) -> Double {
        return ledger.evidence(for: patchId)
    }

    public func colorEvidenceForPatch(_ patchId: String) -> Double {
        let patchEvidence = ledger.evidence(for: patchId)
        let globalDisplay = totalDisplay
        return EvidenceConstants.patchLocalWeight * patchEvidence +
               EvidenceConstants.patchGlobalWeight * globalDisplay
    }
}
```

---

## Part 4: Test Specifications

### 4.1 Unit Tests

```swift
import XCTest

final class EvidenceLayersTests: XCTestCase {

    var engine: EvidenceEngine!

    override func setUp() {
        super.setUp()
        engine = EvidenceEngine()
    }

    // MARK: - Monotonicity Tests

    func testDisplayNeverDecreases() {
        // Given: Decreasing quality values
        let qualities: [(gate: Double, soft: Double)] = [
            (0.8, 0.8),
            (0.6, 0.6),
            (0.4, 0.4),
            (0.2, 0.2),
            (0.1, 0.1)
        ]

        var lastDisplay: Double = 0

        for (i, q) in qualities.enumerated() {
            let observation = Observation(
                patchId: "test",
                isErroneous: false,
                timestamp: Double(i),
                frameId: "frame\(i)"
            )

            engine.processFrame(
                observation: observation,
                gateQuality: q.gate,
                softQuality: q.soft
            )

            XCTAssertGreaterThanOrEqual(
                engine.evidenceLayers.totalDisplay,
                lastDisplay,
                "Display must never decrease"
            )

            lastDisplay = engine.evidenceLayers.totalDisplay
        }
    }

    // MARK: - Delta Calculation Tests

    func testDeltaIsComputedCorrectly() {
        let observation = Observation(
            patchId: "test",
            isErroneous: false,
            timestamp: 1.0,
            frameId: "frame1"
        )

        // First observation
        engine.processFrame(
            observation: observation,
            gateQuality: 0.5,
            softQuality: 0.5
        )

        let firstDelta = engine.evidenceLayers.gateDelta

        // Delta should be positive for first observation
        XCTAssertGreaterThan(firstDelta, 0, "First delta should be positive")

        // Second observation with same quality
        engine.processFrame(
            observation: observation,
            gateQuality: 0.5,
            softQuality: 0.5
        )

        let secondDelta = engine.evidenceLayers.gateDelta

        // Delta should be smaller (display approaching steady state)
        XCTAssertLessThan(secondDelta, firstDelta, "Delta should decrease as display stabilizes")
    }

    func testDeltaIsNotArtificiallyPadded() {
        let observation = Observation(
            patchId: "test",
            isErroneous: false,
            timestamp: 1.0,
            frameId: "frame1"
        )

        // Many observations with same quality
        for _ in 0..<100 {
            engine.processFrame(
                observation: observation,
                gateQuality: 0.5,
                softQuality: 0.5
            )
        }

        // After many frames, delta should approach 0 (not minDelta)
        let finalDelta = engine.evidenceLayers.gateDelta
        XCTAssertLessThan(finalDelta, 0.001, "Delta should approach 0, not be artificially padded")
    }

    // MARK: - Gradual Penalty Tests

    func testGradualPenaltyNotTooSevere() {
        // First: Build up evidence
        let goodObs = Observation(
            patchId: "patch1",
            isErroneous: false,
            timestamp: 1.0,
            frameId: "frame1"
        )

        engine.processFrame(
            observation: goodObs,
            gateQuality: 0.8,
            softQuality: 0.8
        )

        let evidenceBefore = engine.evidenceLayers.ledger.evidence(for: "patch1")

        // Then: Single error observation
        let badObs = Observation(
            patchId: "patch1",
            isErroneous: true,
            timestamp: 1.5,
            frameId: "frame2",
            errorType: .dynamicObject
        )

        engine.processFrame(
            observation: badObs,
            gateQuality: 0.3,
            softQuality: 0.3
        )

        let evidenceAfter = engine.evidenceLayers.ledger.evidence(for: "patch1")
        let penalty = evidenceBefore - evidenceAfter

        // Penalty should be gradual (≤ basePenalty for single error)
        XCTAssertLessThanOrEqual(
            penalty,
            PenaltyConfig.basePenalty * 2,  // Allow some margin
            "Single error penalty should be gradual"
        )

        // Evidence should not drop to 0 from single error
        XCTAssertGreaterThan(evidenceAfter, 0.5, "Single error should not devastate evidence")
    }

    func testCooldownPreventsCorpsePenalty() {
        // First: Create old patch with no recent updates
        let oldObs = Observation(
            patchId: "stale_patch",
            isErroneous: false,
            timestamp: 0.0,  // Very old
            frameId: "old_frame"
        )

        engine.processFrame(
            observation: oldObs,
            gateQuality: 0.8,
            softQuality: 0.8
        )

        let evidenceBefore = engine.evidenceLayers.ledger.evidence(for: "stale_patch")

        // Then: Error observation much later (outside cooldown)
        let lateErrorObs = Observation(
            patchId: "stale_patch",
            isErroneous: true,
            timestamp: 100.0,  // Way past cooldown
            frameId: "late_frame",
            errorType: .dynamicObject
        )

        engine.processFrame(
            observation: lateErrorObs,
            gateQuality: 0.3,
            softQuality: 0.3
        )

        let evidenceAfter = engine.evidenceLayers.ledger.evidence(for: "stale_patch")

        // Should have minimal or no penalty (cooldown protection)
        XCTAssertEqual(
            evidenceAfter,
            evidenceBefore,
            accuracy: 0.01,
            "Stale patches should not be penalized (corpse protection)"
        )
    }

    // MARK: - Weight Cap Tests

    func testFrameSpamDoesNotDominateEvidence() {
        // Create many observations for one patch
        for i in 0..<50 {
            let spamObs = Observation(
                patchId: "spam_patch",
                isErroneous: false,
                timestamp: Double(i) * 0.1,
                frameId: "spam_\(i)"
            )

            engine.processFrame(
                observation: spamObs,
                gateQuality: 0.9,
                softQuality: 0.9
            )
        }

        // Create single observation for another patch
        let singleObs = Observation(
            patchId: "single_patch",
            isErroneous: false,
            timestamp: 10.0,
            frameId: "single"
        )

        engine.processFrame(
            observation: singleObs,
            gateQuality: 0.3,
            softQuality: 0.3
        )

        // Total evidence should not be dominated by spam patch
        let totalEvidence = engine.evidenceLayers.ledger.totalEvidence()

        // With capped weights, spam patch (0.9) and single patch (0.3)
        // should have similar influence. Total should be between them.
        XCTAssertLessThan(totalEvidence, 0.85, "Spam patch should not dominate")
        XCTAssertGreaterThan(totalEvidence, 0.35, "Single patch should still contribute")
    }

    // MARK: - Color Mapping Tests

    func testColorMappingThresholds() {
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.0, softDisplay: 0.0), .black)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.19, softDisplay: 0.0), .black)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.20, softDisplay: 0.0), .darkGray)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.44, softDisplay: 0.0), .darkGray)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.45, softDisplay: 0.0), .lightGray)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.69, softDisplay: 0.0), .lightGray)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.70, softDisplay: 0.0), .white)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.87, softDisplay: 0.0), .white)

        // S5 requires BOTH conditions
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.88, softDisplay: 0.74), .white)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.88, softDisplay: 0.75), .original)
        XCTAssertEqual(ColorMapping.map(totalDisplay: 0.95, softDisplay: 0.80), .original)
    }

    // MARK: - Dynamic Weights Tests

    func testDynamicWeightsTransition() {
        // Early: Gate-biased
        let early = DynamicWeights.weights(currentTotal: 0.2)
        XCTAssertGreaterThan(early.gate, early.soft)
        XCTAssertEqual(early.gate + early.soft, 1.0, accuracy: 0.001)

        // Mid: Balanced
        let mid = DynamicWeights.weights(currentTotal: 0.6)
        XCTAssertLessThan(abs(mid.gate - mid.soft), 0.15)
        XCTAssertEqual(mid.gate + mid.soft, 1.0, accuracy: 0.001)

        // Late: Soft-biased
        let late = DynamicWeights.weights(currentTotal: 0.9)
        XCTAssertLessThan(late.gate, late.soft)
        XCTAssertEqual(late.gate + late.soft, 1.0, accuracy: 0.001)
    }

    // MARK: - Serialization Tests

    func testSerializationRoundTrip() throws {
        // Build up some state
        for i in 0..<10 {
            let obs = Observation(
                patchId: "patch_\(i % 3)",
                isErroneous: i == 5,
                timestamp: Double(i),
                frameId: "frame_\(i)",
                errorType: i == 5 ? .dynamicObject : nil
            )

            engine.processFrame(
                observation: obs,
                gateQuality: 0.5 + Double(i) * 0.03,
                softQuality: 0.4 + Double(i) * 0.03
            )
        }

        // Export
        let jsonData = try engine.exportStateJSON()

        // Verify JSON is valid
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: jsonData))

        // Create new engine and import
        let newEngine = EvidenceEngine()
        try newEngine.loadStateJSON(jsonData)

        // Verify state matches
        XCTAssertEqual(
            newEngine.evidenceLayers.gateDisplay,
            engine.evidenceLayers.gateDisplay,
            accuracy: 0.001
        )
        XCTAssertEqual(
            newEngine.evidenceLayers.softDisplay,
            engine.evidenceLayers.softDisplay,
            accuracy: 0.001
        )
        XCTAssertEqual(
            newEngine.evidenceLayers.ledger.count,
            engine.evidenceLayers.ledger.count
        )
    }

    // MARK: - Smoother Tests

    func testSmootherMedian() {
        let smoother = MetricSmoother(windowSize: .medium)  // 5

        _ = smoother.addAndSmooth(1.0)
        _ = smoother.addAndSmooth(2.0)
        _ = smoother.addAndSmooth(3.0)
        _ = smoother.addAndSmooth(4.0)
        let result = smoother.addAndSmooth(5.0)

        XCTAssertEqual(result, 3.0, accuracy: 0.001)

        // Outlier resistance
        let withOutlier = smoother.addAndSmooth(100.0)
        // Window: [2, 3, 4, 5, 100] → median = 4
        XCTAssertEqual(withOutlier, 4.0, accuracy: 0.001)
    }
}
```

### 4.2 Integration Tests

```swift
import XCTest

final class EvidenceEngineIntegrationTests: XCTestCase {

    func testFullCaptureSession() {
        let engine = EvidenceEngine()

        var colorChanges: [(from: ColorState, to: ColorState)] = []
        engine.onColorStateChange = { from, to in
            colorChanges.append((from, to))
        }

        // Phase 1: Initial capture (black → dark gray)
        for i in 0..<20 {
            let obs = Observation(
                patchId: "patch_\(i % 5)",
                isErroneous: false,
                timestamp: Double(i),
                frameId: "frame_\(i)"
            )

            engine.processFrame(
                observation: obs,
                gateQuality: 0.3 + Double(i) * 0.01,
                softQuality: 0.2 + Double(i) * 0.005
            )
        }

        XCTAssertTrue(colorChanges.contains { $0.to == .darkGray })

        // Phase 2: Continued capture (dark gray → light gray → white)
        for i in 20..<100 {
            let obs = Observation(
                patchId: "patch_\(i % 10)",
                isErroneous: false,
                timestamp: Double(i),
                frameId: "frame_\(i)"
            )

            engine.processFrame(
                observation: obs,
                gateQuality: 0.5 + Double(i - 20) * 0.005,
                softQuality: 0.4 + Double(i - 20) * 0.005
            )
        }

        XCTAssertEqual(engine.currentColorState, .white)

        // Phase 3: Error observations (display does NOT regress)
        let displayBeforeErrors = engine.evidenceLayers.totalDisplay

        for i in 100..<110 {
            let obs = Observation(
                patchId: "patch_\(i % 5)",
                isErroneous: true,
                timestamp: Double(i),
                frameId: "error_\(i)",
                errorType: .dynamicObject
            )

            engine.processFrame(
                observation: obs,
                gateQuality: 0.3,
                softQuality: 0.2
            )
        }

        // Display must not decrease
        XCTAssertGreaterThanOrEqual(
            engine.evidenceLayers.totalDisplay,
            displayBeforeErrors
        )

        // Color must not regress
        XCTAssertEqual(engine.currentColorState, .white)
    }

    func testS5Achievement() {
        let engine = EvidenceEngine()

        // Push to S5
        for i in 0..<200 {
            let obs = Observation(
                patchId: "patch_\(i % 20)",
                isErroneous: false,
                timestamp: Double(i),
                frameId: "frame_\(i)"
            )

            engine.processFrame(
                observation: obs,
                gateQuality: 0.9 + Double(i) * 0.0005,
                softQuality: 0.85 + Double(i) * 0.0005
            )
        }

        // Should achieve S5
        XCTAssertTrue(engine.currentColorState.isS5)
        XCTAssertEqual(engine.currentColorState, .original)
    }
}
```

---

## Part 5: Acceptance Criteria

### 5.1 Functional Acceptance

| ID | Criterion | Test Method |
|----|-----------|-------------|
| F1 | E_display is monotonic (never decreases) | `testDisplayNeverDecreases` |
| F2 | Delta is computed correctly (before update) | `testDeltaIsComputedCorrectly` |
| F3 | Delta is not artificially padded | `testDeltaIsNotArtificiallyPadded` |
| F4 | Gradual penalty (not single-frame destruction) | `testGradualPenaltyNotTooSevere` |
| F5 | Cooldown protects stale patches | `testCooldownPreventsCorpsePenalty` |
| F6 | Frame spam does not dominate | `testFrameSpamDoesNotDominateEvidence` |
| F7 | Color mapping thresholds correct | `testColorMappingThresholds` |
| F8 | Dynamic weights transition correctly | `testDynamicWeightsTransition` |
| F9 | Serialization round-trip works | `testSerializationRoundTrip` |
| F10 | Full capture session works | `testFullCaptureSession` |
| F11 | S5 can be achieved | `testS5Achievement` |

### 5.2 Performance Acceptance

| ID | Criterion | Target |
|----|-----------|--------|
| P1 | Single frame processing latency | < 5ms |
| P2 | Memory footprint increase | < 10MB |
| P3 | Patch storage capacity | > 10,000 patches |
| P4 | Serialization size | < 1MB for 10K patches |

### 5.3 Cross-Platform Acceptance

| ID | Criterion | Verification |
|----|-----------|--------------|
| X1 | No platform-specific imports in Core | Code review |
| X2 | All serialization uses Codable JSON | Code review |
| X3 | Protocol can be implemented on Android/Web | API review |
| X4 | Constants are in SSOT location | Code review |

---

## Part 6: Deliverables Checklist

### 6.1 Required Files

```
Core/Evidence/
├── EvidenceLayers.swift          ✓ (Three-layer system)
├── PatchEvidenceMap.swift        ✓ (Capped weights, gradual penalty)
├── Observation.swift             ✓ (No quality field)
├── EvidenceEngine.swift          ✓ (Unified engine)
├── ColorMapping.swift            ✓ (Thresholds)
├── DynamicWeights.swift          ✓ (Gate/Soft scheduler)
├── MetricSmoother.swift          ✓ (Constrained window)
├── PenaltyConfig.swift           ✓ (Gradual penalty config)
└── EvidenceState.swift           ✓ (Codable serialization)

Core/Constants/
└── EvidenceConstants.swift       ✓ (All constants)

Core/Protocols/
└── EvidenceProtocol.swift        ✓ (Cross-platform)

Tests/Evidence/
├── EvidenceLayersTests.swift     ✓ (Unit tests)
└── EvidenceEngineIntegrationTests.swift  ✓ (Integration tests)
```

### 6.2 Code Standards

- All public APIs must have documentation comments
- All constants must be in `EvidenceConstants.swift`
- All platform-specific code must use `#if` guards
- Unit test coverage > 80%
- No use of `[String: Any]` for serialization

---

## Part 6.5: PR1 → PR2 Interface Update

### PR1 Output Interface Change

PR1 must output `gateQuality` and `softQuality` separately, instead of a single `quality` value.

#### ObservationOutput Structure

```swift
/// Output from PR1 to PR2
public struct ObservationOutput: Sendable {
    let patchId: String
    let gateQuality: Double    // [0, 1] - Geometric stability
    let softQuality: Double    // [0, 1] - Depth/topology quality
    let timestamp: TimeInterval
    let frameId: String
}
```

#### Quality Computation Split

**gateQuality (geometric foundation):**
- ARKit tracking state (normal = 1.0, limited = 0.5, notAvailable = 0.0)
- Pose confidence
- Motion blur detection (high blur = lower quality)
- Camera exposure stability

**softQuality (depth/topology):**
- Depth map confidence (ARKit depthConfidence)
- Occlusion edge quality
- Surface normal consistency
- Depth discontinuity detection

#### Implementation Example

```swift
// In PR1's frame processing:

func processFrame(_ frame: ARFrame) -> ObservationOutput {
    // Gate quality: geometric stability
    let trackingScore = trackingStateScore(frame.camera.trackingState)
    let poseScore = poseConfidenceScore(frame)
    let blurScore = motionBlurScore(frame)
    let gateQuality = (trackingScore * 0.4 + poseScore * 0.4 + blurScore * 0.2)
    
    // Soft quality: depth/topology
    let depthScore = depthConfidenceScore(frame.sceneDepth)
    let occlusionScore = occlusionEdgeScore(frame)
    let softQuality = (depthScore * 0.6 + occlusionScore * 0.4)
    
    return ObservationOutput(
        patchId: computePatchId(frame),
        gateQuality: gateQuality.clamped(to: 0...1),
        softQuality: softQuality.clamped(to: 0...1),
        timestamp: frame.timestamp,
        frameId: generateFrameId()
    )
}
```

#### Key Rule

**softQuality is only meaningful when gateQuality is sufficient.**

PR2 enforces this with `softWriteRequiresGateMin` threshold (default: 0.30). PR1 does not need to handle this logic - just output both values independently. PR2's `SplitLedger` will automatically enforce the soft write policy:

```swift
// PR2's SplitLedger.update() automatically handles this:
if gateQuality > EvidenceConstants.softWriteRequiresGateMin {
    softLedger.update(...)  // Only writes if gate is sufficient
}
```

#### Migration from PR1

If PR1 currently outputs a single `quality` value:

1. **Split the computation** into gateQuality and softQuality components
2. **Remove** any single `quality` field from Observation structures
3. **Update** PR1's output to use `ObservationOutput` with separate gateQuality/softQuality
4. **PR2 will handle** the soft write policy automatically

---

## Part 7: PR3/PR4 Dependencies

After PR2 is complete:

**PR3 (Gate System) will:**
- Implement `GateGainFunctions` to compute real `gateQuality`
- Pass computed `gateQuality` to `EvidenceEngine.processFrame()`
- Use `EvidenceEngine.smoothedDepthEdgeAlign` etc. for calculations

**PR4 (Soft System) will:**
- Implement `SoftGainFunctions` to compute real `softQuality`
- Pass computed `softQuality` to `EvidenceEngine.processFrame()`
- Implement edge classification and depth fusion

---

**Document Version:** 2.0 (Hardened)
**Author:** Claude Code
**Last Updated:** 2026-01-29

---

## STATUS: LOCKED (Patch V4)

This document is **LOCKED** as of Patch V4 implementation completion.

### Implementation Status

- ✅ Three-layer evidence architecture (ledger, display, delta)
- ✅ SplitLedger (gate/soft separation)
- ✅ PatchEvidenceMap with locking, decay, cooldown
- ✅ PatchDisplayMap (monotonic, EMA, locked acceleration)
- ✅ DynamicWeights (deterministic blending)
- ✅ BucketedAmortizedAggregator (O(k) performance)
- ✅ UnifiedAdmissionController (hard/soft separation)
- ✅ TrueDeterministicJSONEncoder (byte-identical)
- ✅ IsolatedEvidenceEngine (actor-based concurrency)
- ✅ Golden fixture testing
- ✅ ForbiddenPatternLint (CI gate)
- ✅ End-to-end integration tests
- ✅ Evidence invariants (code-enforced)
- ✅ Structured observability
- ✅ Evidence replay engine

### System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              PR2 Evidence System Architecture                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Observation → UnifiedAdmissionController                    │
│              ↓ (hard-block or qualityScale)                 │
│  SplitLedger (gateLedger + softLedger)                       │
│              ↓ (PatchEvidenceMap updates)                    │
│  PatchDisplayMap (monotonic, EMA, locked acceleration)      │
│              ↓ (Rule D: delta computed BEFORE update)        │
│  AsymmetricDeltaTracker (fast up, slow down)                │
│              ↓ (aggregation)                                 │
│  BucketedAmortizedAggregator (O(k) totals)                  │
│              ↓ (DynamicWeights blending)                     │
│  EvidenceSnapshot (immutable, cross-thread safe)             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Invariants (Non-Negotiable)

1. **Display Monotonicity**: Display evidence NEVER decreases per patch
2. **Ledger Bounds**: Ledger evidence ∈ [0, 1] (enforced by @ClampedEvidence)
3. **Decay Invariant**: ConfidenceDecay NEVER mutates stored evidence (only affects aggregation weight)
4. **Admission Gate**: UnifiedAdmissionController is the ONLY throughput gate
5. **Throughput Guarantee**: Minimum 25% quality scale enforced
6. **Delta Semantics (Rule D)**: Delta computed BEFORE display update
7. **Determinism**: JSON encoding is byte-identical across 1000 iterations

### Admission Semantics

**Hard Blocks** (observation completely rejected):
- Time density violation (same patch, < 33ms interval)
- Confirmed spam (spamScore >= 0.95)

**Soft Penalties** (quality scale reduction):
- Token bucket exhaustion
- Low view diversity/novelty
- Frequency cap (too many updates per window)

**Guaranteed Minimum**: Even worst-case compound penalties cannot reduce quality scale below 25%.

### Determinism Guarantees

- **JSON Encoding**: Byte-identical across platforms and iterations (TrueDeterministicJSONEncoder)
- **Ordering**: All snapshots/exports use deterministic sorting (never Dictionary iteration order)
- **Timestamps**: CrossPlatformTimestamp (Int64 ms) ensures cross-platform consistency
- **Quantization**: Selective quantization policy for numeric fields

### Forbidden Patterns (Zero Tolerance)

The following patterns are **FORBIDDEN** and will fail CI:

1.  - Use SplitLedger instead
2.  - Use explicit gateQuality/softQuality parameters
3.  in public APIs - Use Codable types
4.  padding for evidence delta - Delta must be exact
5. Computing delta AFTER display update - Must compute BEFORE (Rule D)
6. O(n) per-frame full iteration for totals - Use BucketedAmortizedAggregator

### Migration Rules

- **From PR1**: Replace `observation.quality` with explicit `gateQuality`/`softQuality` (see Part 6.5 for interface specification)
- **From PR1**: Replace `isErroneous: Bool` with `verdict: ObservationVerdict`
- **From PR1**: Replace single ledger with `SplitLedger` (gateLedger + softLedger)
- **From PR1**: Replace `AmortizedAggregator` with `BucketedAmortizedAggregator`
- **From PR1**: Update output to use `ObservationOutput` structure with separate gateQuality/softQuality fields 

### Patch V4 Changes

- Removed all  occurrences
- Evidence locking only affects ledger (not display)
- Delta computed from previous display values BEFORE update (Rule D)
- Serialization is byte-identical deterministic (1000x test)
- Evidence engine is single-writer actor ()
- CI gates include ForbiddenPatternLint and GoldenFixtureTests

---

**This document is immutable unless Patch V5 is declared.**

