# PR#6 Evidence Grid System — Master Plan Report
## Version 2.0 | 2026-02-07
## Status: DRAFT — Code-Grounded Rewrite

---

# Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Existing Code Ground Truth](#2-existing-code-ground-truth)
3. [Architecture Decision Records](#3-architecture-decision-records)
4. [Integration Map — PR6 ON TOP of PR1-PR5](#4-integration-map)
5. [Data Flow: Camera → S5 (End-to-End)](#5-data-flow)
6. [State System Reconciliation](#6-state-system-reconciliation)
7. [State Machine (S0-S5)](#7-state-machine)
8. [Observation Model (L0-L6)](#8-observation-model)
9. [EvidenceGrid — Spatial Storage Layer](#9-evidencegrid)
10. [15-Dimension Evidence Model](#10-15-dimension-evidence-model)
11. [CoverageEstimator](#11-coverageestimator)
12. [PIZ Detection](#12-piz-detection)
13. [4-Ledger Architecture (extending SplitLedger)](#13-4-ledger-architecture)
14. [Memory & Performance Budget](#14-memory-and-performance-budget)
15. [Constitutional Guardrails](#15-constitutional-guardrails)
16. [File-by-File Implementation Plan](#16-file-by-file-implementation-plan)
17. [Acceptance Criteria & Golden Cases](#17-acceptance-criteria)
18. [Camera Resolution Policy](#18-camera-resolution-policy)
19. [Research Foundation](#19-research-foundation)
20. [Sources & References](#20-sources)

---

# 1. Executive Summary

PR#6 implements the **Evidence Grid System** — a spatial intelligence layer that transforms raw camera observations into structured, multi-dimensional evidence about 3D capture quality and completeness.

**Core principle: PR6 builds ON the existing Evidence engine, NOT alongside it.**

PR6 does NOT replace IsolatedEvidenceEngine, SplitLedger, PatchDisplayMap, or any PR1-PR5 component. It WRAPS and EXTENDS them:

| Existing Component (PRESERVED) | PR6 Extension |
|-------------------------------|---------------|
| `IsolatedEvidenceEngine` (29 files, @EvidenceActor) | New `processFrameWithGrid()` method added, calls existing `processObservation()` internally |
| `SplitLedger` (Gate + Soft) | Extended to `MultiLedger` (Gate + Soft + Provenance + Advanced), wraps existing SplitLedger |
| `DynamicWeights` (2-way smoothstep) | Extended to 4-way smoothstep, preserving existing Gate/Soft computation |
| `PatchDisplayMap` (monotonic EMA) | **UNCHANGED** — PR6's dimensional scores feed into existing PatchDisplayMap pipeline |
| `EvidenceConstants` (SSOT, 40+ constants) | **EXTENDED** with new PR6 constants (PIZ, D-S, dimensional) — all existing values unchanged |
| `EvidenceConfidenceLevel` (L0-L3) | **EXTENDED** with L4-L6 appended (append-only enum) |
| `ColorState` (black→original) | **PRESERVED** as-is — S5 condition already defined: `totalDisplay ≥ 0.88 AND softDisplay ≥ 0.75` |
| `GateQualityComputer` (PR3 5-step) | **PRESERVED** — PR6 adds dimensions AFTER gate computation |
| `ObservationVerdict` (good/suspect/bad) | **PRESERVED** — maps directly to D-S mass assignment |
| `PatchEntry` (evidence, counts, locking) | **PRESERVED** — PR6 adds dimensional scores as a PARALLEL data structure |
| `BucketedAmortizedAggregator` (O(k)) | **PRESERVED** — continues aggregating total evidence |

**S0-S5 state machine** (S5 = original color = render-ready for world models / robotics / autonomous driving)
**L0-L6 observation levels** (L0-L3 from existing `EvidenceConfidenceLevel`, L4-L6 appended)
**15-dimension evidence** model (Gate: ①-③⑩, Soft: ④-⑥⑨, Provenance: ⑦⑧, Advanced: ⑪-⑮)
**PIZ detection**: purely internal algorithm, zero user prompts — affects only triangle brightness
**Camera resolution**: always max device resolution, no user choice

---

# 2. Existing Code Ground Truth

This section documents EVERY existing file and type that PR6 must connect to. No PR6 design decision is valid unless it references a concrete integration point here.

## 2.1 Core Evidence Engine (29 files)

**Path:** `Core/Evidence/`

| File | Key Types | PR6 Interaction |
|------|-----------|-----------------|
| `IsolatedEvidenceEngine.swift` | `IsolatedEvidenceEngine` (@EvidenceActor), `EvidenceSnapshot` | **PRIMARY INTEGRATION POINT** — PR6 adds `processFrameWithGrid()` method |
| `SplitLedger.swift` | `SplitLedger` (gateLedger + softLedger) | Wrapped by new `MultiLedger` (adds Provenance + Advanced) |
| `DynamicWeights.swift` | `DynamicWeights.weights(progress:)` — smoothstep Gate↔Soft | Extended to 4-way: `weights4(progress:)` returns (gate, soft, provenance, advanced) |
| `PatchDisplayMap.swift` | `PatchDisplayMap` — monotonic EMA, locked patch acceleration | **UNCHANGED** — PR6's dimensional total feeds existing `update(patchId:target:...)` |
| `PatchEvidenceMap.swift` | `PatchEvidenceMap`, `PatchEntry` — per-patch storage | **UNCHANGED** — PR6's EvidenceGrid is a PARALLEL spatial index, not a replacement |
| `PatchWeightComputer.swift` | `PatchWeightComputer.computeWeight(observationCount:lastUpdate:currentTime:viewDiversityScore:)` | Extended: add `dimensionalCompleteness` as 4th factor |
| `BucketedAmortizedAggregator.swift` | 8 buckets × 15s = 120s window, decay weights | **UNCHANGED** |
| `Observation.swift` | `EvidenceObservation` (patchId: String, timestamp, frameId, errorType) | **UNCHANGED** — PR6 creates EvidenceObservation as before, dimensional scores stored separately |
| `ObservationVerdict.swift` | `ObservationVerdict` (good/suspect/bad/unknown), `JudgedObservation` | **UNCHANGED** — verdict.deltaMultiplier maps to D-S mass: good→m(O)=0.8, suspect→m(O)=0.3, bad→m(O)=0 |
| `ClampedEvidence.swift` | `@ClampedEvidence` property wrapper [0,1] | **UNCHANGED** — all dimensional scores use this |
| `ConfidenceDecay.swift` | `ConfidenceDecay` — halflife=60s | **UNCHANGED** |
| `EvidenceState.swift` | Schema v2.1, `PatchEntrySnapshot`, export/import JSON | EXTENDED: schema bumped to v3.0, adds dimensional snapshot |
| `EvidenceInvariants.swift` | Display-never-decreases, etc. | **PRESERVED** — all invariants still hold |
| `EvidenceError.swift` | `EvidenceError` enum | EXTENDED: add `.gridError`, `.dimensionError` cases |
| `EvidenceLogger.swift` | Logging facility | **UNCHANGED** |
| `EvidenceReplayEngine.swift` | `ObservationLogEntry`, replay capability | EXTENDED: log entry gains dimensional raw inputs |
| `HealthMonitorWithStrategies.swift` | `HealthMonitorWithStrategies`, `ColorState` enum, `EvidenceHealthMetrics` | **CRITICAL** — `ColorState` { black, darkGray, lightGray, white, original, unknown } is the existing S5 endpoint |
| `MemoryPressureHandler.swift` | `MemoryPressureHandler`, `TrimPriority` | EXTENDED: device-adaptive thresholds via `os_proc_available_memory()` |
| `SpamProtection.swift` | Time density, novelty gate | **UNCHANGED** |
| `TokenBucketLimiter.swift` | Rate limiting | **UNCHANGED** |
| `ViewDiversityTracker.swift` | 15° angle buckets, max 16 buckets/patch | **UNCHANGED** — feeds Dimension ① (Geometric) |
| `ObservationReorderBuffer.swift` | Observation ordering | **UNCHANGED** |
| `FrameRateIndependentPenalty.swift` | Frame-rate independent penalty scaling | **UNCHANGED** |
| `CoordinateNormalizer.swift` | Coordinate quantization pipeline | **REUSED** by EvidenceGrid for spatial hashing |
| `QuantizationPolicy.swift` | Quantization rules | **UNCHANGED** |
| `TrueDeterministicJSONEncoder.swift` | Deterministic JSON encoding | **UNCHANGED** |
| `UnifiedAdmissionController.swift` | Admission control (separate from FROZEN v2.3b AdmissionController) | **UNCHANGED** |
| `CrossPlatformTimestamp.swift` | Cross-platform timestamp | **UNCHANGED** — used in new DimensionalScore |
| `AsymmetricDeltaTracker.swift` | Delta tracking | **UNCHANGED** |

## 2.2 PR3 Gate Quality (sub-directory)

**Path:** `Core/Evidence/PR3/`

| File | Key Types | PR6 Interaction |
|------|-----------|-----------------|
| `GateQualityComputer.swift` | 5-step pipeline: validate→smooth→PR3InternalQuality→record→gateQuality | **PRESERVED** — PR6 calls this FIRST, then adds dimensional scoring |
| `GateGainFunctions.swift` | View, geometry, basic gain functions (weights: 0.40, 0.45, 0.15) | **PRESERVED** — gains feed Dimensions ①②③ |
| `GateCoverageTracker.swift` | Theta/phi bitsets | **PRESERVED** — bitset feeds Dimension ⑩ (Occlusion/Direction) |
| `GateInputValidator.swift` | Input validation | **PRESERVED** |
| `HardGatesV13.swift` | All gate threshold constants | **PRESERVED** |

## 2.3 Constants (SSOT)

**Path:** `Core/Constants/`

| File | Key Constants | PR6 Interaction |
|------|--------------|-----------------|
| `EvidenceConstants.swift` | 40+ constants: patchDisplayAlpha=0.2, softWriteRequiresGateMin=0.30, lockThreshold=0.85, whiteThreshold=0.88, s5MinSoftEvidence=0.75, dynamicWeightsGateEarly=0.65 | **EXTENDED** — add PR6 constants (PIZ, D-S, dimensional) |
| `CoveragePolicy.swift` | `EvidenceConfidenceLevel` {L0,L1,L2,L3}, `CoveragePolicySpec` per profile | **EXTENDED** — append L4,L5,L6 to `EvidenceConfidenceLevel` |
| `GridResolutionPolicy.swift` | 8 allowed resolutions: 0.25mm→5cm, per-profile allowed set | **REUSED** — EvidenceGrid resolution levels come from this closed set |
| `CaptureProfile.swift` | 5 profiles: standard, smallObjectMacro, largeScene, proMacro, cinematicScene | **FROZEN** — PR6 reads profiles, never modifies |

## 2.4 Quality Types

**Path:** `Core/Quality/Types/`

| File | Key Types | PR6 Interaction |
|------|-----------|-----------------|
| `VisualState.swift` | `VisualState` { black, gray, white, clear } — never-retreat, user-facing | **RECONCILED** — see Section 6 State System Reconciliation |
| `DecisionState.swift` | `DecisionState` { active, frozen, directionComplete, sessionComplete } | **PRESERVED** — orthogonal to S0-S5 |

## 2.5 PR5 Coverage Grid

**Path:** `Core/Quality/Models/`

| File | Key Types | PR6 Interaction |
|------|-----------|-----------------|
| `CoverageGrid.swift` | `CoverageGrid` 128×128, `CoverageState` { uncovered, gray, white, forbidden } | **COEXISTS** — PR6 EvidenceGrid is 3D spatial hash, CoverageGrid is 2D projection overlay. Both live simultaneously. |

## 2.6 PR4 Fusion Pipeline

**Path:** `Sources/PR4Fusion/`

| File | Key Types | PR6 Interaction |
|------|-----------|-----------------|
| `FrameProcessor.swift` | `FrameProcessor` — uses SoftQualityComputer, SoftGateMachine | **NOTE**: `softQuality: Double = 0.0` is still placeholder in IsolatedEvidenceEngine. PR6 fills this with Dimensions ④-⑥⑨ aggregate. |

---

# 3. Architecture Decision Records

## ADR-1: PR6 as Composition Layer (not Replacement)

**Decision:** PR6 is a composition layer that wraps existing components. No existing file is deleted or has its API broken.

**Rationale:**
- IsolatedEvidenceEngine + SplitLedger + PatchDisplayMap are battle-tested in PR1-PR5
- 29 existing Evidence files, 300+ existing tests depend on current APIs
- PR6 adds NEW capabilities (spatial grid, dimensional scoring, coverage estimation, PIZ) as parallel data structures
- The existing `processObservation()` call path is UNTOUCHED — PR6's `processFrameWithGrid()` calls it internally

**Implementation pattern:**
```swift
// PR6 adds a new convenience method to IsolatedEvidenceEngine
// This does NOT modify the existing processObservation() or processFrameWithGate()
@EvidenceActor
extension IsolatedEvidenceEngine {
    public func processFrameWithGrid(
        observation: EvidenceObservation,
        cameraPosition: EvidenceVector3,
        patchPosition: EvidenceVector3,
        rawMetrics: FrameRawMetrics,    // NEW: raw sensor data for 15-dim
        frameIndex: Int,
        verdict: ObservationVerdict
    ) {
        // Step 1: Compute gate quality (existing PR3 path, UNCHANGED)
        let gateQuality = gateComputer.computeGateQuality(...)

        // Step 2: Compute dimensional scores (NEW PR6)
        let dimScores = dimensionalComputer.compute(rawMetrics: rawMetrics, ...)

        // Step 3: Compute soft quality from dimensions ④-⑥⑨ (fills PR4 placeholder)
        let softQuality = dimScores.softAggregate

        // Step 4: Call existing processObservation (UNCHANGED call path)
        processObservation(observation, gateQuality: gateQuality, softQuality: softQuality, verdict: verdict)

        // Step 5: Update EvidenceGrid spatial index (NEW PR6)
        evidenceGrid.update(patchId: observation.patchId, position: patchPosition, dimScores: dimScores)

        // Step 6: Update Provenance + Advanced ledgers (NEW PR6)
        multiLedger.updateProvenance(observation: observation, dimScores: dimScores)
        multiLedger.updateAdvanced(observation: observation, dimScores: dimScores)

        // Step 7: Update coverage estimator (NEW PR6)
        coverageEstimator.incorporate(patchId: observation.patchId, level: dimScores.confidenceLevel)

        // Step 8: Check PIZ (NEW PR6, async background)
        pizDetector.markObserved(patchId: observation.patchId, timestamp: observation.timestamp)
    }
}
```

## ADR-2: Grid Storage — Flat Hash Table (not Octree)

**Decision:** Use MrHash-style flat spatial hash table with resolution levels from existing `GridResolutionPolicy`.

**Connection to existing code:** `GridResolutionPolicy.swift` already defines 8 allowed levels (0.25mm→5cm). The EvidenceGrid picks resolution from this closed set per-region. `CoordinateNormalizer.swift` handles coordinate quantization before hashing.

## ADR-3: Evidence Fusion — Dempster-Shafer (not Bayesian)

**Decision:** Use Dempster-Shafer theory for coverage accumulation.

**Connection to existing code:** `ObservationVerdict` (good/suspect/bad) maps directly to D-S mass functions:
- `good` (deltaMultiplier=1.0) → m(occupied)=0.8, m(free)=0.0, m(unknown)=0.2
- `suspect` (deltaMultiplier=0.3) → m(occupied)=0.3, m(free)=0.0, m(unknown)=0.7
- `bad` (deltaMultiplier=0.0) → m(occupied)=0.0, m(free)=0.3, m(unknown)=0.7

## ADR-4: Observation Levels — L0-L6 (extending existing L0-L3)

**Decision:** Extend `EvidenceConfidenceLevel` from {L0,L1,L2,L3} to {L0,L1,L2,L3,L4,L5,L6}.

**Connection to existing code:** `CoveragePolicy.swift:16-30` defines `EvidenceConfidenceLevel: UInt8, Codable, CaseIterable`. It's `append-only` by design comment. PR6 appends:
```swift
case L4 = 4  // Verified (photometric consistency + temporal stability)
case L5 = 5  // Certified (provenance chain intact)
case L6 = 6  // Absolute (all dimensions > 0.8, independent verification)
```

All existing `CoveragePolicySpec` references to `[.L0, .L1, .L2, .L3]` remain valid — L4-L6 are additions, not modifications.

## ADR-5: S0-S5 State Machine (preserving existing S5)

**Decision:** S0-S5 states where S5 = `ColorState.original` = photorealistic render-ready.

**Connection to existing code:**
- `EvidenceConstants.whiteThreshold = 0.88` (comment: "S5 total requirement")
- `EvidenceConstants.s5MinSoftEvidence = 0.75`
- `HealthMonitorWithStrategies.swift` defines `ColorState` enum with `.original` case
- `ColorState.isS5` computed property already exists in the codebase

PR6 does NOT change the S5 condition. It adds the S0→S4 state machine transitions driven by D-S coverage, leading to S4→S5 via the existing condition.

## ADR-6: Memory — Device-Adaptive (no fixed cap)

**Decision:** Use `os_proc_available_memory()` instead of fixed limits.

**Connection to existing code:** `MemoryPressureHandler.swift` already handles memory pressure with `TrimPriority`. PR6 replaces hardcoded thresholds with device-adaptive computation, using the SAME `TrimPriority` enum for eviction.

---

# 4. Integration Map — PR6 ON TOP of PR1-PR5

This section is the structural backbone of PR6. Every arrow below represents a real function call or data dependency.

## 4.1 Existing Data Flow (PR1-PR5, UNCHANGED)

```
Camera Frame
    │
    ▼
EvidenceObservation(patchId: String, timestamp, frameId, errorType?)  [Observation.swift]
    │
    ▼
ObservationVerdict (good/suspect/bad)  [ObservationVerdict.swift]
    │
    ├──► GateQualityComputer.computeGateQuality(patchId:direction:reproj:edge:...)  [PR3/]
    │         │
    │         ▼
    │    gateQuality: Double (0-1)
    │
    ├──► softQuality: Double = 0.0  ◄── PLACEHOLDER (PR4 stub)
    │
    ▼
IsolatedEvidenceEngine.processObservation(observation, gateQuality, softQuality, verdict)
    │
    ├──► SplitLedger.update(observation, gateQuality, softQuality, verdict, ...)
    │         │
    │         ├──► gateLedger (PatchEvidenceMap) — always writes
    │         └──► softLedger (PatchEvidenceMap) — writes only if gateQuality > 0.30
    │
    ├──► DynamicWeights.weights(currentTotal:) → (gate: 0.65→0.35, soft: 0.35→0.65)
    │
    ├──► SplitLedger.patchEvidence(for:currentProgress:) → fused evidence value
    │
    ├──► PatchDisplayMap.update(patchId, target, timestampMs, isLocked) → monotonic EMA
    │
    ├──► PatchWeightComputer.computeWeight(obsCount, lastUpdate, currentTime, viewDiversity)
    │
    └──► BucketedAmortizedAggregator.updatePatch(...) → totalEvidence
```

## 4.2 PR6 Extended Data Flow (NEW, wrapping existing)

```
Camera Frame + Raw Sensor Metrics
    │
    ▼
EvidenceObservation(patchId, timestamp, frameId, errorType?)  [UNCHANGED]
    │
    ▼
ObservationVerdict (good/suspect/bad)  [UNCHANGED]
    │
    ├──► GateQualityComputer.computeGateQuality(...)  [UNCHANGED]
    │         │
    │         ▼
    │    gateQuality: Double
    │
    ├──► ★ DimensionalComputer.compute(rawMetrics:) → DimensionalScoreSet  [NEW PR6]
    │         │
    │         ├── Dim ①②③⑩ → Gate dimensions (from existing PR3 outputs)
    │         ├── Dim ④⑤⑥⑨ → Soft dimensions (fills PR4 softQuality placeholder)
    │         ├── Dim ⑦⑧ → Provenance dimensions
    │         └── Dim ⑪-⑮ → Advanced dimensions (stub=0)
    │         │
    │         ▼
    │    softQuality = dimScores.softAggregate  ◄── FILLS PR4 PLACEHOLDER
    │
    ▼
IsolatedEvidenceEngine.processObservation(observation, gateQuality, softQuality, verdict)
    │                                                                      [UNCHANGED CALL]
    ├──► SplitLedger.update(...)  [UNCHANGED]
    ├──► DynamicWeights.weights(...)  [UNCHANGED — still 2-way for Gate/Soft display]
    ├──► PatchDisplayMap.update(...)  [UNCHANGED]
    ├──► BucketedAmortizedAggregator.updatePatch(...)  [UNCHANGED]
    │
    ▼  (After existing pipeline completes, PR6 additions run)
    │
    ├──► ★ EvidenceGrid.update(patchId, worldPosition, dimScores)  [NEW PR6]
    │         └── Spatial hash table indexed by Morton code
    │         └── Resolution from GridResolutionPolicy closed set
    │
    ├──► ★ MultiLedger.updateProvenance(observation, dimScores)  [NEW PR6]
    │         └── Provenance ledger: SHA-256 chain, C2PA assertion
    │
    ├──► ★ MultiLedger.updateAdvanced(observation, dimScores)  [NEW PR6]
    │         └── Advanced ledger: spectral/thermal/physics (stub until sensors available)
    │
    ├──► ★ CoverageEstimator.incorporate(patchId, level)  [NEW PR6]
    │         └── D-S mass accumulation, level-weighted coverage%
    │
    ├──► ★ PIZDetector.markObserved(patchId, timestamp)  [NEW PR6]
    │         └── Persistence tracking, connected component analysis
    │
    └──► ★ EvidenceStateMachine.evaluate(coverage%, pizRegions, snapshot)  [NEW PR6]
              └── S0→S1→S2→S3→S4→S5 transitions
              └── S5 condition: existing whiteThreshold + s5MinSoftEvidence check
```

**Key insight:** The ★ marked steps are ALL additions that run AFTER the existing pipeline. The existing pipeline runs IDENTICALLY to PR1-PR5. This means all 300+ existing tests continue to pass with zero modification.

## 4.3 Integration Points Summary

| Integration Point | Existing Method | PR6 Action |
|-------------------|----------------|------------|
| Gate quality | `gateComputer.computeGateQuality()` | READ outputs → feed Dims ①②③⑩ |
| Soft quality | `softQuality: Double = 0.0` placeholder | WRITE: `dimScores.softAggregate` fills this |
| Patch evidence | `splitLedger.patchEvidence(for:currentProgress:)` | READ: used by CoverageEstimator |
| Display update | `patchDisplay.update(patchId:target:...)` | UNCHANGED: existing EMA pipeline |
| Color mapping | `EvidenceConstants.whiteThreshold = 0.88` | READ: S5 condition check |
| S5 check | `ColorState.isS5` (totalDisplay ≥ 0.88 AND softDisplay ≥ 0.75) | READ: EvidenceStateMachine uses this for S4→S5 |
| Locking | `PatchEntry.isLocked` (evidence ≥ 0.85 AND obs ≥ 20) | READ: PIZDetector excludes locked patches |
| Resolution | `GridResolutionPolicy` (8 levels) | READ: EvidenceGrid resolution source |
| Coordinates | `CoordinateNormalizer` | REUSE: spatial hash quantization |
| Admission | `UnifiedAdmissionController` | UNCHANGED: rate limiting still applies |

---

# 5. Data Flow: Camera → S5 (End-to-End)

## 5.1 Complete Pipeline (with line numbers)

```
1. Camera captures frame at max device resolution (Section 18)
   → AVCaptureDevice.activeFormat = highest available

2. Frame enters PR5Capture pipeline (Sources/PR5Capture/)
   → FrameProcessor extracts raw metrics

3. EvidenceObservation created (Core/Evidence/Observation.swift:52-103)
   → patchId: String (from spatial hash or voxel ID)
   → timestamp: TimeInterval
   → frameId: String

4. Verdict assigned (Core/Evidence/ObservationVerdict.swift:13-89)
   → good (1.0) / suspect (0.3) / bad (0.0)

5. PR3 Gate quality computed (Core/Evidence/PR3/GateQualityComputer.swift)
   → 5-step: validate → smooth → PR3InternalQuality → record → gateQuality
   → Weights: view=0.40, geom=0.45, basic=0.15

6. ★ PR6 Dimensional scores computed (NEW: DimensionalComputer)
   → 15 dimensions scored [0,1] each
   → softQuality = aggregate of Dims ④⑤⑥⑨ → FILLS PR4 PLACEHOLDER

7. Engine processes observation (Core/Evidence/IsolatedEvidenceEngine.swift:61-128)
   → SplitLedger.update() — Gate always, Soft if gateQuality > 0.30
   → DynamicWeights.weights() — smoothstep blending
   → PatchDisplayMap.update() — monotonic EMA, locked acceleration
   → BucketedAmortizedAggregator.updatePatch() — O(k) total

8. ★ PR6 post-processing (NEW: runs after Step 7)
   → EvidenceGrid spatial index update
   → MultiLedger Provenance + Advanced update
   → CoverageEstimator D-S mass accumulation
   → PIZDetector persistence tracking

9. ★ State machine evaluation (NEW: EvidenceStateMachine)
   → Coverage% drives S0→S1→S2→S3
   → Quality gate drives S3→S4
   → S5 gate: totalDisplay ≥ 0.88 AND softDisplay ≥ 0.75 (existing constants)

10. Color mapping to triangles (existing, Core/Constants/EvidenceConstants.swift:166-180)
    → < 0.20 = Black (S1: scan here)
    → 0.20-0.45 = DarkGray (S1→S2)
    → 0.45-0.70 = LightGray (S2→S3)
    → 0.70-0.88 = White (S3→S4)
    → ≥ 0.88 total AND ≥ 0.75 soft = Original color (S5: render-ready)
```

---

# 6. State System Reconciliation

The existing codebase has FOUR state systems. PR6 must reconcile them, not create a fifth.

## 6.1 Existing State Systems

| System | File | States | Purpose |
|--------|------|--------|---------|
| `ColorState` | HealthMonitorWithStrategies.swift | black, darkGray, lightGray, white, original, unknown | Internal evidence progression → triangle color |
| `VisualState` | Core/Quality/Types/VisualState.swift | black, gray, white, clear | User-facing display state, never retreats |
| `CoverageState` | Core/Quality/Models/CoverageGrid.swift | uncovered, gray, white, forbidden | PR5 128×128 2D grid cells |
| `DecisionState` | Core/Quality/Types/DecisionState.swift | active, frozen, directionComplete, sessionComplete | Session lifecycle state |

## 6.2 PR6 Reconciliation

PR6's S0-S5 **maps to existing ColorState**, not a new enum:

| PR6 State | ColorState Mapping | VisualState Mapping | CoverageState Mapping |
|-----------|-------------------|--------------------|-----------------------|
| S0 (Initial) | — (no data yet) | — | uncovered |
| S1 (Exploring) | black → darkGray | black | uncovered → gray |
| S2 (Building) | darkGray → lightGray | gray | gray |
| S3 (Refining) | lightGray → white | white | gray → white |
| S4 (Complete) | white | white | white |
| S5 (Original) | **original** | clear (transparent overlay) | white |

**PR6 does NOT create a new `EvidenceGridState` enum.** Instead, `EvidenceStateMachine` outputs a `ColorState` value that feeds into the existing `HealthMonitorWithStrategies` pipeline.

**DecisionState is orthogonal** — it tracks session lifecycle (active/frozen/complete), not evidence quality. PR6 respects it: if DecisionState == .frozen, evidence processing pauses.

---

# 7. State Machine (S0-S5)

## 7.1 State Definitions

| State | Name | ColorState | Entry Condition | Exit Condition |
|-------|------|------------|-----------------|----------------|
| S0 | Initial | — | Session start | First valid observation processed |
| S1 | Exploring | black→darkGray | First observation, D-S coverage < 40% | D-S coverage ≥ 40% |
| S2 | Building | darkGray→lightGray | D-S coverage ≥ 40% | D-S coverage ≥ 75% |
| S3 | Refining | lightGray→white | D-S coverage ≥ 75% | D-S coverage ≥ 95% AND all non-PIZ patches at L3+ |
| S4 | Complete | white | Quality requirements met | ALL patches: totalDisplay ≥ 0.88 AND softDisplay ≥ 0.75 |
| S5 | Original | **original** (transparent overlay) | S5 condition from existing `EvidenceConstants` | Session ends |

**S5 is the ultimate goal.** The scan quality is sufficient to reproduce the object's true appearance — original colors, PBR materials, occlusion boundaries — at fidelity usable for world models (robotics, autonomous driving, digital twins).

## 7.2 Transition Truth Table

```
From → To   | Condition                                        | Reversible?
S0 → S1     | First valid observation processed                 | No
S1 → S2     | D-S coverage% ≥ 40%                              | No
S2 → S3     | D-S coverage% ≥ 75%                              | No
S3 → S4     | D-S coverage% ≥ 95% AND qualityCheck.passed      | No
S4 → S5     | ALL patches: totalDisplay ≥ 0.88 AND softDisplay ≥ 0.75 | No
S1 → S3     | Impossible (must pass through S2)                 | —
S3 → S2     | NOT ALLOWED (monotonically increasing)            | No
Any → S5    | Only from S4                                      | —
```

States are **MONOTONICALLY INCREASING** (S0→S1→S2→S3→S4→S5). No rollback. This matches existing `PatchDisplayMap` invariant (display evidence never decreases) and `VisualState` (never retreats).

## 7.3 Implementation Connection

```swift
/// EvidenceStateMachine — outputs ColorState, NOT a new enum
@EvidenceActor
public final class EvidenceStateMachine {
    private var currentState: ColorState = .unknown  // S0

    /// Evaluate state transition based on current metrics
    /// Called after each processFrameWithGrid()
    func evaluate(
        coverage: CoverageResult,         // from CoverageEstimator
        pizRegions: [PIZRegion],          // from PIZDetector
        snapshot: EvidenceSnapshot         // from IsolatedEvidenceEngine.snapshot()
    ) -> ColorState {
        // S4→S5: Use EXISTING constants
        if currentState == .white {  // S4
            if snapshot.totalEvidence >= EvidenceConstants.whiteThreshold   // 0.88
               && snapshot.softDisplay >= EvidenceConstants.s5MinSoftEvidence // 0.75
            {
                currentState = .original  // S5
            }
        }
        // ... S3→S4, S2→S3, S1→S2, S0→S1 transitions
        return currentState
    }
}
```

## 7.4 Trigger Sources

1. **Coverage%** (D-S) — primary trigger for S0→S1→S2→S3
2. **PIZ detection** — can cause stall in S1/S2 (never rollback)
3. **Quality gate** — S3→S4 requires all non-PIZ patches at L3+
4. **S5 gate** — existing `whiteThreshold=0.88 AND s5MinSoftEvidence=0.75`

NOT triggered by: patch count alone, time elapsed, user action.

---

# 8. Observation Model (L0-L6)

## 8.1 Level Definitions

Extends existing `EvidenceConfidenceLevel` enum (CoveragePolicy.swift:16-30).

| Level | Name | Entry Condition | Source |
|-------|------|-----------------|--------|
| L0 | Unobserved | Default state | EXISTING |
| L1 | Detected | ≥1 observation with confidence > 0.3 | EXISTING |
| L2 | Observed | ≥2 observations, baseline/depth ratio > 0.05 | EXISTING |
| L3 | Triangulated | ≥3 observations from ≥2 directions (>15°), reproj < 2px | EXISTING |
| L4 | Verified | L3 + photometric consistency > 0.7, temporal stability > 0.8 across ≥5 frames | **NEW PR6** |
| L5 | Certified | L4 + provenance chain intact, all 4 Gate dimensions > 0.6 | **NEW PR6** |
| L6 | Absolute | L5 + ≥6 viewpoints, all 10 active dimensions > 0.8 | **NEW PR6** |

## 8.2 Level Promotion Rules

Level promotion is **append-only** (never demote in the same session). This matches existing `VisualState` never-retreat invariant.

```swift
/// Extends existing EvidenceConfidenceLevel enum
extension EvidenceConfidenceLevel {
    case L4 = 4  // Verified
    case L5 = 5  // Certified
    case L6 = 6  // Absolute
}

/// Level promotion uses existing ViewDiversityTracker (15° buckets)
/// and existing GateCoverageTracker (theta/phi bitsets) to count directions
func evaluatePromotion(
    patch: PatchEntry,              // EXISTING type
    dimScores: DimensionalScoreSet, // NEW PR6 type
    diversityTracker: ViewDiversityTracker  // EXISTING type
) -> EvidenceConfidenceLevel {
    let directions = diversityTracker.occupiedBucketCount(for: patch)
    let obsCount = patch.observationCount

    if obsCount >= 6 && directions >= 6
       && dimScores.allActive.allSatisfy({ $0.rawValue > 0.8 })
       && dimScores.provenanceChainIntact {
        return .L6
    }
    // ... cascade L5, L4, L3, L2, L1
}
```

## 8.3 "Distinct Direction" Definition

Uses existing `ViewDiversityTracker` (15° buckets, max 16 per patch) from `Core/Evidence/ViewDiversityTracker.swift`.

---

# 9. EvidenceGrid — Spatial Storage Layer

## 9.1 Purpose

EvidenceGrid is a **PARALLEL spatial index** alongside existing `PatchEvidenceMap`. It does NOT replace `PatchEvidenceMap`.

- `PatchEvidenceMap` (existing): Dictionary<String, PatchEntry> — stores evidence values, observation counts, locking
- `EvidenceGrid` (NEW): Spatial hash table — stores 3D positions, dimensional scores, D-S masses, resolution levels

Both are indexed by `patchId: String` (the existing patch identifier).

## 9.2 Data Structure

```swift
/// Core grid storage using spatial hashing
/// Inspired by MrHash (ACM TOG 2025) and nvblox (NVIDIA Isaac)
/// Resolution levels from EXISTING GridResolutionPolicy (8 levels, closed set)
public struct EvidenceGrid: Sendable {

    /// Hash table: SpatialKey → GridCell
    private var cells: [SpatialKey: GridCell]

    /// Resolution level from GridResolutionPolicy.allowedLevels(for: profile)
    private var resolutionLevel: GridResolutionLevel  // FROM EXISTING CLOSED SET

    /// Memory budget tracker
    private var memoryBudget: DeviceAdaptiveMemoryBudget
}

/// Spatial key using Morton code, quantized through EXISTING CoordinateNormalizer
public struct SpatialKey: Hashable, Sendable {
    let mortonCode: UInt64
    let level: UInt8  // Maps to GridResolutionPolicy level index (0-7)
}

/// Grid cell storing dimensional evidence for a patch
public struct GridCell: Sendable {
    let patchId: String             // Links back to PatchEvidenceMap
    var position: EvidenceVector3   // World position
    var dimScores: DimensionalScoreSet  // 15-dim scores
    var dsMass: DSMassFunction      // D-S mass (occupied, free, unknown)
    var level: EvidenceConfidenceLevel  // Current observation level (L0-L6)
    var directionalBitmask: UInt32  // Which directions observed from
    var lastUpdated: CrossPlatformTimestamp  // EXISTING type
}
```

## 9.3 Hash Function — Quantized Morton Code

```swift
/// Uses EXISTING CoordinateNormalizer for quantization before Morton encoding
static func spatialKey(position: EvidenceVector3, level: UInt8) -> SpatialKey {
    let quantized = CoordinateNormalizer.quantize(position, level: level)
    let morton = mortonEncode(x: quantized.x, y: quantized.y, z: quantized.z)
    return SpatialKey(mortonCode: morton, level: level)
}
```

## 9.4 Variance-Adaptive Resolution

```swift
/// Uses EXISTING GridResolutionPolicy closed set (8 levels: 0.25mm → 5cm)
func shouldRefine(cell: GridCell, profile: CaptureProfile) -> Bool {
    let variance = computeLocalVariance(cell)
    let currentLevel = cell.resolutionLevel
    let finerLevel = GridResolutionPolicy.nextFinerLevel(currentLevel)

    return variance > varianceThreshold(for: currentLevel)
        && finerLevel != nil
        && GridResolutionPolicy.isAllowed(finerLevel!, for: profile)  // EXISTING API
}
```

---

# 10. 15-Dimension Evidence Model

## 10.1 Dimension Map (with existing code sources)

| # | Dimension | Ledger | FPS | Source of Raw Data |
|---|-----------|--------|-----|--------------------|
| ① | Geometric | Gate | 60 | **EXISTING** GateGainFunctions.viewGain + GateCoverageTracker |
| ② | Feature | Gate | 60 | **EXISTING** GateGainFunctions.geomGain (reproj, edge RMS) |
| ③ | Volumetric | Gate | 30 | NEW: TSDF integration from depth map |
| ④ | Semantic | Soft | 12 | NEW: Material classification via ANE |
| ⑤ | Temporal | Soft | 60 | **PARTIALLY EXISTING** ObservationErrorType.motionBlur, .exposureDrift |
| ⑥ | Radiometric | Soft | 60 | **PARTIALLY EXISTING** GateInputValidator.sharpness, overexposureRatio |
| ⑦ | Provenance | Prov | 15 | NEW: SHA-256 chain, C2PA |
| ⑧ | Trajectory | Prov | 15 | **PARTIALLY EXISTING** ViewDiversityTracker angle buckets |
| ⑨ | Resolution | Soft | 30 | NEW: Effective pixels per patch, GSD |
| ⑩ | Occlusion | Gate | 60 | **EXISTING** GateCoverageTracker theta/phi bitsets |
| ⑪-⑮ | Advanced | Adv | 7 | STUB=0 (future hardware sensors) |

**Key: 6 of 10 active dimensions derive data from EXISTING code.** PR6 adds dimensional scoring on top of existing raw metrics, not new sensor pipelines.

## 10.2 DimensionalScoreSet

```swift
/// 15-dimension score set
/// Each score uses EXISTING ClampedEvidence property wrapper for [0,1] guarantee
public struct DimensionalScoreSet: Codable, Sendable {
    @ClampedEvidence var geometric: Double     // ① from GateGainFunctions
    @ClampedEvidence var feature: Double       // ② from GateGainFunctions
    @ClampedEvidence var volumetric: Double    // ③ new
    @ClampedEvidence var semantic: Double      // ④ new
    @ClampedEvidence var temporal: Double      // ⑤ from ObservationErrorType
    @ClampedEvidence var radiometric: Double   // ⑥ from sharpness/exposure
    @ClampedEvidence var provenance: Double    // ⑦ new
    @ClampedEvidence var trajectory: Double    // ⑧ from ViewDiversityTracker
    @ClampedEvidence var resolution: Double    // ⑨ new
    @ClampedEvidence var occlusion: Double     // ⑩ from GateCoverageTracker
    // ⑪-⑮ advanced (stub = 0)

    /// Aggregate for soft quality (fills PR4 placeholder)
    var softAggregate: Double {
        (semantic + temporal + radiometric + resolution) / 4.0
    }

    /// Confidence level based on dimensional completeness
    var confidenceLevel: EvidenceConfidenceLevel { ... }
}
```

## 10.3 Dimension → Ledger Weight Schedule

Extended `DynamicWeights` with 4-way smoothstep. Existing 2-way Gate/Soft logic is PRESERVED for the main pipeline — 4-way is used only for dimensional aggregation.

```swift
extension DynamicWeights {
    /// 4-way weights for PR6 dimensional aggregation
    /// EXISTING 2-way weights() method is UNCHANGED
    public static func weights4(progress: Double) -> (gate: Double, soft: Double, provenance: Double, advanced: Double) {
        let (gateW, softW) = weights(progress: progress)  // EXISTING computation
        // Split provenance + advanced from proportional allocation
        let provW = (1.0 - gateW - softW) * 0.75  // 0 when gate+soft=1.0 early on
        let advW = (1.0 - gateW - softW) * 0.25
        // ...with proper transition schedule
    }
}
```

---

# 11. CoverageEstimator

## 11.1 Coverage Formula (Dempster-Shafer)

```swift
/// D-S based coverage using EXISTING observation levels and verdict mapping
func computeCoverage() -> CoverageResult {
    var numerator: Double = 0
    var denominator: Double = 0

    for cell in evidenceGrid.validCells {
        let beliefOccupied = cell.dsMass.occupied  // [0, 1]
        let levelW = levelWeight(cell.level)       // Uses EXISTING EvidenceConfidenceLevel

        let weight = levelW * cell.dimScores.completeness
        numerator += beliefOccupied * weight
        denominator += weight > 0 ? 1 : 0
    }

    return CoverageResult(
        percentage: denominator > 0 ? numerator / denominator : 0,
        totalCells: evidenceGrid.activeCellCount,
        validCells: evidenceGrid.validCellCount,
        levelDistribution: computeLevelDistribution()
    )
}
```

## 11.2 Level Weights

| Level | Weight | Rationale |
|-------|--------|-----------|
| L0 | 0.00 | Unobserved = no coverage |
| L1 | 0.20 | Detected but not validated |
| L2 | 0.50 | Multi-view observed |
| L3 | 0.80 | Triangulated, consistent |
| L4 | 0.90 | Verified across modalities |
| L5 | 0.95 | Certified with provenance |
| L6 | 1.00 | Absolute certainty |

## 11.3 Update Frequency

- **Every frame** during S1/S2 (fast exploration)
- **Every 5 frames** during S3/S4 (reduce compute)
- EMA smoothing (alpha=0.15) to prevent UI jitter

---

# 12. PIZ Detection

## 12.1 Definition

**PIZ = Persistently Insufficient Zone**: A contiguous region of patches where coverage quality is insufficient and has NOT improved despite continued scanning.

```
PIZ(region R) = TRUE iff:
  1. R is a connected component of GridCells with level < L3
  2. area(R) > minPIZArea (profile-dependent, from CoveragePolicy)
  3. R has been observed for > 30 seconds
  4. improvement_rate(R, last 30s) < 0.01/sec
```

## 12.2 PIZ Output

```swift
struct PIZRegion: Codable, Sendable {
    let regionId: UUID
    let patchIds: Set<String>            // links to EXISTING PatchEvidenceMap entries
    let centroid: EvidenceVector3
    let areaEstimate: Float              // square meters
    let averageLevel: Float              // mean EvidenceConfidenceLevel
    let persistenceDuration: TimeInterval
    let occlusionLikelihood: Float       // probability PIZ is due to occlusion
}
```

## 12.3 PIZ → UI Interaction (Zero Prompts)

**PIZ is purely internal. No text prompts, no popups, no toast messages, no user-facing labels.**

PIZ affects ONLY:
- **Triangle brightness**: PIZ regions stay dark (black/dark gray) in the existing grayscale overlay, preventing false brightness increases through existing `PatchDisplayMap` pipeline
- **Coverage% computation**: PIZ patches receive reduced weight in D-S coverage formula
- **State machine gating**: S3→S4 blocked while unresolved PIZ exists — user sees "triangles not all white yet"

User guidance is entirely implicit through the existing grayscale overlay:
- Dark triangles = "scan here more" — user naturally moves camera toward dark areas
- PIZ regions that cannot be resolved (occlusionLikelihood > 0.8) auto-reclassify as "structurally occluded" and are excluded from coverage denominator — triangles brighten automatically

**No "PIZ detected" message. No "try scanning from angle X" text. No question dialogs.**

## 12.4 PIZ → State Machine Interaction

- PIZ does NOT force state rollback (monotonic states)
- PIZ in S1/S2: Expected (still exploring), internal bookkeeping only
- PIZ in S3: Prevents S3→S4 transition — triangles stay dark
- PIZ in S4: Prevents S4→S5 — patches in PIZ cannot reach S5 quality
- PIZ auto-resolution: occlusionLikelihood > 0.8 → excluded from coverage denominator → triangles brighten

## 12.5 Golden Test Cases

| Case | Input | Expected PIZ Output |
|------|-------|-------------------|
| No gaps | All patches L3+ | PIZ count = 0 |
| Small gap | 5 adjacent patches at L1 | PIZ count = 0 (below min area) |
| Large gap | 200 adjacent patches at L0, stalled 30s+ | PIZ count = 1 |
| Multiple gaps | 3 separate clusters of L1 patches | PIZ count = 3 |
| Edge gap | Bottom of object never visible | PIZ count = 1, occlusionLikelihood > 0.7 |

---

# 13. 4-Ledger Architecture (extending SplitLedger)

## 13.1 MultiLedger wraps existing SplitLedger

```swift
/// 4-ledger architecture
/// WRAPS existing SplitLedger — does NOT replace it
@EvidenceActor
public final class MultiLedger {
    /// EXISTING SplitLedger (Gate + Soft) — UNCHANGED
    public let coreLedger: SplitLedger

    /// NEW: Provenance ledger (C2PA chain, device attestation)
    private let provenanceLedger: PatchEvidenceMap  // REUSES EXISTING type

    /// NEW: Advanced ledger (spectral, thermal, physics)
    private let advancedLedger: PatchEvidenceMap    // REUSES EXISTING type

    public init() {
        self.coreLedger = SplitLedger()  // Existing 2-ledger
        self.provenanceLedger = PatchEvidenceMap()
        self.advancedLedger = PatchEvidenceMap()
    }

    /// Delegate core observation to EXISTING SplitLedger
    public func updateCore(
        observation: EvidenceObservation,
        gateQuality: Double,
        softQuality: Double,
        verdict: ObservationVerdict,
        frameId: String,
        timestamp: TimeInterval
    ) {
        coreLedger.update(
            observation: observation,
            gateQuality: gateQuality,
            softQuality: softQuality,
            verdict: verdict,
            frameId: frameId,
            timestamp: timestamp
        )
    }
}
```

## 13.2 Weight Fusion

For dimensional aggregation, weights are 4-way. But the EXISTING `IsolatedEvidenceEngine.processObservation()` still uses 2-way `DynamicWeights.weights()` — this is UNCHANGED.

The 4-way weights are used only for the new `EvidenceGrid.GridCell.totalScore` computation:
```swift
let (gW, sW, pW, aW) = DynamicWeights.weights4(progress: coverage.percentage)
let total = gW * gateDimAvg + sW * softDimAvg + pW * provDimAvg + aW * advDimAvg
```

---

# 14. Memory & Performance Budget

## 14.1 Device-Adaptive Memory Policy

```swift
struct DeviceAdaptiveMemoryBudget {
    static func compute() -> MemoryBudget {
        let availableRAM = os_proc_available_memory()
        let evidenceBudget = availableRAM / 10  // 10% of available

        return MemoryBudget(
            evidenceGrid: evidenceBudget * 0.45,
            dimensionalScores: evidenceBudget * 0.25,
            workingBuffers: evidenceBudget * 0.30
        )
    }
}
```

| Device | Available RAM | Evidence Budget | Max Grid Cells |
|--------|--------------|-----------------|----------------|
| iPhone 13 Pro (6GB) | ~3GB | ~300MB | ~150K |
| iPhone 15 Pro (8GB) | ~4.5GB | ~450MB | ~225K |
| iPhone 17 Pro (12GB) | ~7.5GB | ~750MB | ~375K |

## 14.2 Performance Targets

| Operation | Budget | Notes |
|-----------|--------|-------|
| processObservation() | < 4.4ms | EXISTING (unchanged) |
| DimensionalComputer.compute() | < 2ms | NEW — 10 active dimensions |
| EvidenceGrid.update() | < 0.5ms | NEW — hash table insert |
| CoverageEstimator.incorporate() | < 1ms | NEW |
| PIZDetector.markObserved() | < 0.3ms | NEW |
| Total PR6 overhead | < 4ms | On top of existing ~4.4ms |
| Total frame time | < 8.5ms | Existing + PR6 |

## 14.3 Eviction Strategy

Uses EXISTING `MemoryPressureHandler.TrimPriority` enum:
1. `.lowestEvidence` — evict lowest-confidence cells first
2. `.oldestLastUpdate` — evict stale cells
3. `.notLocked` — protect locked patches (evidence ≥ 0.85 AND obs ≥ 20)

PR6 adds: cells with `dsMass.unknown > 0.8` are evicted before low-evidence cells.

---

# 15. Constitutional Guardrails

## 15.1 Evidence Constitution (Non-negotiable Invariants)

All EXISTING invariants from `EvidenceInvariants.swift` are PRESERVED. PR6 adds:

```swift
enum EvidenceGridConstitution {
    // EXISTING (from EvidenceInvariants.swift):
    // C1: Display evidence NEVER decreases (PatchDisplayMap monotonic)

    // PR6 additions:
    // C2: State machine is MONOTONICALLY INCREASING (S0→S1→...→S5, no rollback)
    // C3: Observation levels are APPEND-ONLY (never demote in session)
    // C4: Coverage% uses EMA smoothing, never artificially inflated
    // C5: PIZ regions computed deterministically (same input → same output)
    // C6: Provenance chain hash is append-only (SHA-256, no removal)
    // C7: Grid resolution changes respect GridResolutionPolicy closed set
    // C8: Memory eviction NEVER destroys evidence above L3
    // C9: All dimensional scores are [0,1] (ClampedEvidence property wrapper)
    // C10: D-S mass invariant: m(occupied) + m(free) + m(unknown) = 1.0
}
```

## 15.2 Schema Versioning

Extends existing `EvidenceState` schema (currently v2.1):
```swift
// EvidenceState.swift currently:
//   static let currentSchemaVersion = "2.1"
//   compatible with "2.0"+

// PR6 bumps to:
//   static let currentSchemaVersion = "3.0"
//   compatible with "2.0"+ (backward read) + "3.0" (full dimensional data)
```

## 15.3 Forensic Audit Trail

Every state transition produces:
```swift
struct EvidenceStateTransitionRecord: Codable {
    let timestamp: CrossPlatformTimestamp  // EXISTING type
    let fromState: ColorState             // EXISTING type
    let toState: ColorState               // EXISTING type
    let triggerType: TransitionTrigger
    let coverageAtTransition: Float
    let patchCountAtTransition: Int
    let pizCountAtTransition: Int
    let sha256: String
    let prevRecordHash: String
}
```

---

# 16. File-by-File Implementation Plan

## Phase 1: Core Types & EvidenceGrid (estimated 2h)

### Step 1.1: Extend `EvidenceConfidenceLevel` in `CoveragePolicy.swift`
- ADD `case L4 = 4`, `case L5 = 5`, `case L6 = 6`
- All existing code referencing L0-L3 is UNAFFECTED (append-only)
- Update `name` computed property for L4/L5/L6

### Step 1.2: NEW `Core/Evidence/DimensionalEvidence.swift`
- `DimensionalScoreSet` struct (15 dimensions, each `@ClampedEvidence`)
- `DimensionalComputer` class — computes scores from raw metrics
- Dimensions ①②⑥⑧⑩: derive from EXISTING `GateGainFunctions`, `GateCoverageTracker`, `ViewDiversityTracker`
- Dimensions ③④⑨: new computation from depth/semantic/resolution data
- Dimensions ⑤: derive from EXISTING `ObservationErrorType` detection
- Dimensions ⑦: new SHA-256 chain computation
- Dimensions ⑪-⑮: stub = 0.0

### Step 1.3: NEW `Core/Evidence/DSMassFusion.swift`
- `DSMassFunction` struct: (occupied, free, unknown) where sum = 1.0
- `dempsterCombine(_:_:)` function — standard Dempster combination rule
- Maps from EXISTING `ObservationVerdict.deltaMultiplier`:
  - good(1.0) → m(O)=0.8, m(F)=0.0, m(U)=0.2
  - suspect(0.3) → m(O)=0.3, m(F)=0.0, m(U)=0.7
  - bad(0.0) → m(O)=0.0, m(F)=0.3, m(U)=0.7
- Invariant enforcement: `assert(m.occupied + m.free + m.unknown ≈ 1.0)`

### Step 1.4: NEW `Core/Evidence/EvidenceGrid.swift`
- `SpatialKey` (Morton code), `GridCell` (patchId, position, dimScores, dsMass, level)
- `EvidenceGrid` — flat hash table using EXISTING `CoordinateNormalizer` for quantization
- Resolution from EXISTING `GridResolutionPolicy` closed set (8 levels)
- Variance-adaptive refinement within allowed levels

### Step 1.5: NEW `Core/Evidence/DirectionalBitmask.swift`
- 26-direction bitmask (UInt32) for observation direction tracking
- Compatible with EXISTING `GateCoverageTracker` theta/phi bucketing
- Used for L3+ promotion (≥2 distinct directions)

## Phase 2: Multi-Ledger & State Machine (estimated 2h)

### Step 2.1: NEW `Core/Evidence/MultiLedger.swift`
- Wraps EXISTING `SplitLedger` (Gate + Soft)
- Adds Provenance + Advanced ledgers (both using EXISTING `PatchEvidenceMap` type)
- `updateCore()` delegates to existing `SplitLedger.update()`
- `updateProvenance()` and `updateAdvanced()` are new

### Step 2.2: EXTEND `DynamicWeights.swift`
- ADD `weights4(progress:)` method — 4-way smoothstep
- EXISTING `weights(progress:)` and `weights(currentTotal:)` are UNCHANGED
- Invariant: gate + soft + provenance + advanced = 1.0

### Step 2.3: NEW `Core/Evidence/EvidenceStateMachine.swift`
- S0-S5 transitions outputting EXISTING `ColorState` enum values
- Monotonically increasing (matches existing `VisualState` never-retreat invariant)
- S5 condition uses EXISTING constants: `whiteThreshold=0.88`, `s5MinSoftEvidence=0.75`
- Receives `CoverageResult` from CoverageEstimator, `PIZRegion[]` from PIZDetector, `EvidenceSnapshot` from engine

### Step 2.4: NEW `Core/Evidence/CoverageEstimator.swift`
- D-S based coverage computation from `EvidenceGrid` cells
- Level-weighted formula using EXISTING `EvidenceConfidenceLevel` (now L0-L6)
- EMA smoothing (alpha=0.15) — consistent with existing smoothing patterns

### Step 2.5: NEW `Core/Evidence/PIZDetector.swift`
- Connected component analysis on low-level grid cells
- 30s persistence window, 0.01/sec improvement threshold
- `PIZRegion` output with `occlusionLikelihood`
- Auto-resolution: occlusionLikelihood > 0.8 → excluded from coverage denominator

## Phase 3: Engine Integration & Wiring (estimated 1.5h)

### Step 3.1: EXTEND `IsolatedEvidenceEngine.swift`
- ADD `processFrameWithGrid()` method (see ADR-1 for signature)
- This calls EXISTING `processObservation()` internally
- Then runs PR6 post-processing: EvidenceGrid, MultiLedger, CoverageEstimator, PIZDetector, StateMachine
- ADD new private properties: `evidenceGrid`, `multiLedger`, `coverageEstimator`, `pizDetector`, `stateMachine`
- ADD to `reset()`: reset new components
- ADD to `snapshot()`: include coverage%, state, piz count

### Step 3.2: EXTEND `EvidenceConstants.swift`
- ADD PIZ constants: `pizPersistenceWindowSec = 30.0`, `pizImprovementThreshold = 0.01`, `pizMinAreaSqM = 0.001`
- ADD D-S constants: `dsDefaultOccupiedGood = 0.8`, `dsDefaultUnknownGood = 0.2`, etc.
- ADD dimensional constants: per-dimension weight defaults
- ALL existing constants UNCHANGED

### Step 3.3: EXTEND `EvidenceState.swift`
- Bump schema to v3.0
- ADD `dimensionalSnapshots` to export format
- ADD `coveragePercentage`, `stateMachineState`, `pizRegionCount` to export
- PRESERVE backward compatibility: v2.x data loads with dimensional fields defaulting to nil

### Step 3.4: EXTEND `PatchWeightComputer.swift`
- ADD `dimensionalCompleteness` as 4th factor in weight computation
- Existing 3-factor computation (frequency × decay × diversity) UNCHANGED when dimensional data absent
- `computeWeight()` signature extended with optional `dimensionalCompleteness: Double? = nil`

### Step 3.5: NEW `Core/Evidence/ProvenanceChain.swift`
- SHA-256 hash chain for evidence state transitions
- C2PA assertion skeleton (full implementation in later PR)
- Each state transition record hashes: timestamp + fromState + toState + prevHash

## Phase 4: Constants & Polish (estimated 0.5h)

### Step 4.1: NEW `Core/Constants/PIZConstants.swift`
- Per-profile PIZ thresholds (minArea, persistence window, improvement threshold)
- References EXISTING `CaptureProfile` profiles

### Step 4.2: NEW `Core/Constants/DimensionalConstants.swift`
- Per-dimension weight defaults, thresholds, acceptable ranges
- References EXISTING `EvidenceConstants` pattern (SSOT with documentation)

## Phase 5: Testing & Validation (estimated 2h)

### Step 5.1: Unit tests for new types
- `DimensionalScoreSet` — all scores clamped [0,1]
- `DSMassFusion` — combination rule, invariant m(O)+m(F)+m(U)=1.0, conflict handling
- `EvidenceGrid` — insert, query, evict, resolution refinement
- `DirectionalBitmask` — popcount, direction encoding
- `MultiLedger` — delegates to SplitLedger correctly

### Step 5.2: State machine tests
- S0→S1→S2→S3→S4→S5 golden path
- Monotonic enforcement (no rollback under any input)
- S5 condition: whiteThreshold AND s5MinSoftEvidence

### Step 5.3: Coverage golden cases
| Case | Input | Expected Coverage% |
|------|-------|-------------------|
| Empty grid | 0 cells | 0.00% |
| All L0 | 1000 cells, all L0 | 0.00% |
| Mixed L1-L3 | 500 L1 + 300 L2 + 200 L3 | ~52.0% |
| High quality | 1000 cells, all L5 | ~95.0% |
| With PIZ | 800 L3 + 200 L0 (PIZ) | ~64.0% |

### Step 5.4: PIZ golden cases
| Case | Input | Expected PIZ |
|------|-------|-------------|
| No gaps | All L3+ | PIZ count = 0 |
| Small gap | 5 L1 patches | PIZ count = 0 (below min area) |
| Large gap | 200 L0, stalled 30s+ | PIZ count = 1 |
| Multiple gaps | 3 separate L1 clusters | PIZ count = 3 |
| Occluded | Bottom never visible | PIZ count = 1, occlusionLikelihood > 0.7 |

### Step 5.5: Integration test
- Existing `processObservation()` path produces IDENTICAL results with PR6 code present
- All existing PR1-PR5 tests pass with ZERO modification
- `processFrameWithGrid()` produces valid state machine transitions + coverage%

### Step 5.6: Performance benchmarks
- 8K cells: DimensionalComputer.compute() < 2ms
- 8K cells: EvidenceGrid.update() < 0.5ms
- 8K cells: CoverageEstimator < 1ms
- Total PR6 overhead < 4ms on iPhone 15 Pro

---

# 17. Acceptance Criteria

## 17.1 Original Criteria (must still pass)

- [ ] S0-S5 transitions correct (truth table verified)
- [ ] S5 = original color per existing `ColorState.original` and `EvidenceConstants.whiteThreshold=0.88 + s5MinSoftEvidence=0.75`
- [ ] Coverage% computed (D-S weighted formula)
- [ ] PIZ detection works (5 golden cases)
- [ ] ALL existing PR1-PR5 tests pass with zero modification

## 17.2 Extended Criteria

- [ ] 15-dimension scores computed for Dims ①-⑥, ⑧-⑩ (10 active)
- [ ] EvidenceGrid insert/query/evict in O(1) amortized
- [ ] Resolution from existing `GridResolutionPolicy` closed set (8 levels)
- [ ] D-S mass invariant: m(O)+m(F)+m(U)=1.0 for all cells
- [ ] State machine monotonic S0→S5 (no rollback in any test scenario)
- [ ] Coverage% deterministic (same observations → identical coverage%)
- [ ] Memory budget respects device-adaptive limits
- [ ] Provenance hash chain integrity verified
- [ ] Performance: PR6 overhead < 4ms on iPhone 15 Pro
- [ ] `processObservation()` path produces identical results to pre-PR6

## 17.3 User Experience

- Users see ONLY grayscale triangles (black→white→original color) — 15 dimensions invisible
- No numbers, percentages, radar charts, or text prompts on main scanning screen
- Black = scan here, White = done, Original color = S5 (render-ready)
- No PIZ warnings, no "scan from angle X" suggestions — algorithm manages everything through triangle brightness
- PIZ auto-resolves occluded areas without asking user
- Haptic feedback for quality events (speed warning, level promotion, completion)

---

# 18. Camera Resolution Policy

**The app camera always captures at the device's maximum available resolution. No user choice. No downsampling.**

`AVCaptureDevice.activeFormat` is set to the highest resolution format at session start. One-time configuration.

**"Resolution" in EvidenceGrid (Section 9) = spatial grid cell size (0.25mm-5cm), NOT camera pixels. These are independent concepts:**
- Camera resolution = pixels per photo (always max, locked)
- Grid resolution = 3D spatial cell size (variance-adaptive per region)

---

# 19. Research Foundation

## Key Papers Informing PR6 Design

- **MrHash** (ACM TOG 2025): Variance-adaptive voxel grid → EvidenceGrid design
- **DB-TSDF** (Sep 2025): Directional bitmask evidence → DirectionalBitmask
- **DS-K3DOM** (IEEE): D-S evidential grids → CoverageEstimator
- **VIN-NBV** (May 2025): Quality-optimized view planning → PIZ detection logic
- **3DGS-QA** (Nov 2025): Quality assessment for Gaussian splats → Dimensional scoring
- **C2PA 2.3** (2025): Provenance chain specification → ProvenanceChain
- **NIST OSAC 2025-N-0022**: Forensic evidence standards → Audit trail design

## Hardware Target

- Apple A19 Pro: ~7.4 TFLOPS GPU, 8GB+ RAM, Metal 4 Tensor APIs
- Budget allows 15-dimension computation at 30+ FPS

---

# 20. Sources & References

## Academic Papers
- [3DGS-QA: Perceptual Quality Assessment of 3DGS](https://arxiv.org/abs/2511.08032) (Nov 2025)
- [GS-QA: Comprehensive Quality Assessment Benchmark](https://colab.ws/articles/10.1109/qomex65720.2025.11219925) (QoMEX 2025)
- [MUGSQA: Multi-Uncertainty-Based Quality Assessment](https://arxiv.org/abs/2511.06830) (Nov 2025)
- [MrHash: Variance-Adaptive Voxel Grids](https://doi.org/10.1145/3777909) (ACM TOG 2025)
- [DB-TSDF: Directional Bitmask-based TSDF](https://arxiv.org/html/2509.20081v1) (Sep 2025)
- [VIN-NBV: View Introspection Network](https://arxiv.org/html/2505.06219v1) (May 2025)
- [DS-K3DOM: 3D Dynamic Occupancy Mapping with D-S Theory](https://ieeexplore.ieee.org/iel7/10160211/10160212/10160364.pdf) (IEEE)

## Standards & Specifications
- [C2PA Specification v2.3](https://spec.c2pa.org/specifications/specifications/2.3/specs/C2PA_Specification.html)
- [NIST OSAC 2025-N-0022: Terrestrial LiDAR Scanner Data Capture](https://www.nist.gov/system/files/documents/2025/06/25/2025-N-0022_Standard_for_Terrestrial_LiDAR_Scanner_Data_Capture_OPEN%20COMMENT_VERSION_1.0.pdf)
- [NIST IR 8387: Digital Evidence Preservation](https://nvlpubs.nist.gov/nistpubs/ir/2022/NIST.IR.8387.pdf)

## Industry & Hardware
- [nvblox: GPU-Accelerated TSDF Mapping](https://github.com/nvidia-isaac/nvblox)
- [Metal Benchmarks (Apple GPU)](https://github.com/philipturner/metal-benchmarks)

---

*This document is grounded in the actual Aether3D codebase (29 Evidence files, 40+ Constants, 4 state systems). Every design decision references a concrete existing file, type, or method. PR6 builds ON the existing PR1-PR5 foundation — it does not design in isolation.*

*Existing data flow through IsolatedEvidenceEngine → SplitLedger → PatchDisplayMap → ColorState is PRESERVED. PR6 adds a composition layer that runs AFTER the existing pipeline, feeding new capabilities (spatial grid, dimensional scoring, D-S coverage, PIZ detection, state machine) into the same output: triangle brightness on screen.*
