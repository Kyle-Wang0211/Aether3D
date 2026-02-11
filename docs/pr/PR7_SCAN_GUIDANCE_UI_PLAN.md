# PR#7: Scan Guidance UI — Engineering Blueprint v7.0.3

**Version:** v7.0.3 (Merged — all v7.0.1 + v7.0.2 + v7.0.3 patches inlined)
**Author:** Claude Opus 4.6 + User Collaboration
**Date:** 2026-02-08
**Branch:** `pr7/scan-guidance-ui` (worktree: `progect2-pr7/`)
**Scope:** ~9,800 lines (19 new files + 1 modified + 10 test files)

---

## Part A: Architectural Overview

### A.1 Nine-Layer Architecture

```
Layer 9: Cross-Platform Ports    ← Protocol abstractions for Android/HarmonyOS
Layer 8: Tuning Constants        ← 65+ SSOT-registered constants
Layer 7: Performance & Safety    ← Thermal adaptation, LOD, frame budget
Layer 6: Haptic & Toast          ← 3 warnings + 1 completion, debounced
Layer 5: Animation               ← Flip (threshold-triggered) + Ripple (BFS)
Layer 4: Lighting                ← Cook-Torrance BRDF, 3-tier environment
Layer 3: Geometry                ← 3D wedge extrusion, bevel edges, LOD
Layer 2: Render Pipeline         ← Metal 6-pass, triple-buffered
Layer 1: Data Source             ← PatchDisplayMap, EvidenceStateMachine, QualityFeedback
```

**Platform Split Rule (v7.0.1):**
- `Core/` = pure algorithms, Foundation + simd only. **NO** `import Metal`, `import MetalKit`, `import ARKit`, `import CoreHaptics`. Must compile on Linux.
- `App/` = Apple-platform code (Metal, ARKit, CoreHaptics, SwiftUI). Only compiles on iOS/macOS via Xcode project (not SwiftPM on Linux).

**v7.0.2 Clarification — simd on Linux:**
`SIMD3<Float>`, `SIMD2<Int>` etc. are part of the Swift standard library and available on Linux without a separate module. `#if canImport(simd)` / `import simd` is used for explicit API access (e.g., `simd_float4x4`), and this is the existing pattern in `Core/Quality/Admission/DuplicateDetector.swift` and `PatchTracker.swift`. PR7 follows the same pattern.

**v7.0.3 CRITICAL — Build system reality:**
- **No `.xcodeproj` exists.** The entire project builds via SwiftPM only.
- **`App/` is NOT in any SwiftPM target.** Files in `App/` are currently uncompiled — they are reserved for future Xcode project integration.
- **`#if canImport(Metal)` = TRUE on macOS SwiftPM** (empirically verified). This means `canImport(Metal)` CANNOT be used as a guard to distinguish SwiftPM vs Xcode builds.
- **GuidanceRenderer.swift stays UNMODIFIED in PR7.** The plan uses a protocol-injection pattern instead: `GuidanceRendererDelegate` protocol in Core/ allows App-layer types to be injected at runtime without Core/ referencing them at compile time. See Appendix for details.

### A.2 Data Flow (Per-Frame Update)

```
PatchDisplayMap.snapshotSorted()
        │  returns [DisplayEntry]
        │  (v7.0.2: converted to [String: Double] in pipeline)
        ▼
┌─────────────────────────┐
│ ScanGuidanceRenderPipeline.update() │  ← App/ScanGuidance/
│   ├─ displaySnapshot: [String: Double]  │
│   │   (v7.0.2: converted from [DisplayEntry])  │
│   ├─ colorStates: [String: ColorState]  │
│   ├─ meshTriangles: [ScanTriangle]      │
│   ├─ lightEstimate: ARLightEstimate?    │
│   ├─ cameraTransform: simd_float4x4    │
│   └─ frameDeltaTime: TimeInterval       │
└──────────┬──────────────┘
           │
     ┌─────┼──────┬──────────┬──────────┐
     ▼     ▼      ▼          ▼          ▼
  Wedge  Border  Metallic  Flip/     Haptic
  Geom   Width   BRDF      Ripple    Check
  (Core)  (Core) (App)     (Core)    (App)
     │     │      │          │          │
     └─────┴──────┴──────────┘          │
           │                            ▼
     Metal Encode              GuidanceHapticEngine
     (6 passes)                  .fire(pattern:)
           │                            │
           ▼                            ▼
     MTLCommandBuffer          CHHapticEngine +
     .commit()                 GuidanceToastPresenter
```

**v7.0.2: DisplayEntry → [String: Double] conversion** (done in ScanGuidanceRenderPipeline caller):
```swift
let entries = patchDisplayMap.snapshotSorted()  // [DisplayEntry]
let displaySnapshot = Dictionary(
    uniqueKeysWithValues: entries.map { ($0.patchId, $0.display) }
)
// DisplayEntry fields: patchId: String, display: Double (@ClampedEvidence),
//   ema: Double, observationCount: Int, lastUpdateMs: Int64
```

### A.3 Hard Constraints (Non-Negotiable)

| ID | Constraint | Source |
|----|-----------|--------|
| HC-01 | Triangle colors ONLY black/darkGray/lightGray/white/original/unknown — NO new ColorState cases | ColorState enum in HealthMonitorWithStrategies.swift |
| HC-02 | Display evidence NEVER decreases (monotonic) | PatchDisplayMap invariant |
| HC-03 | GuidanceSignal enum is IMMUTABLE — 4 cases only | GuidanceSignal.swift sealed |
| HC-04 | MUST NOT use text as primary UX path | GuidanceRenderer v2.3b sealed |
| HC-05 | StaticOverlayView stays EmptyView() | Design decision |
| HC-06 | Completion triggered by stop button, NOT coverage threshold | User requirement |
| HC-07 | No global coverage dependency (no getLastCoverage()) | Architecture decision |
| HC-08 | hapticBlurThreshold == QualityThresholds.laplacianBlurThreshold (120.0) | SSOT alignment |
| HC-09 | All Double/Int constants registered via ThresholdSpec/SystemConstantSpec; Bool constants excluded from allSpecs (no BoolConstantSpec in AnyConstantSpec) | SSOTTypes.swift pattern |
| HC-10 | Toast is SECONDARY feedback only (paired with haptic), text alone is NOT primary guidance | v2.3b + PR7 design |
| HC-11 | All code must compile with swift-tools-version: 5.9 (no parameter packs, no typed throws, no ~Copyable) | Package.swift |
| HC-12 | `Core/` must NOT import Metal/MetalKit/ARKit/CoreHaptics — must compile on Linux | pr1_audit.sh, ban_apple_only_imports.sh |
| HC-13 | `ProcessInfo.ThermalState` is Darwin-only — must wrap in `#if os(iOS) \|\| os(macOS)` in Core/ files | MobileThermalStateHandler.swift pattern |

---

## Part B: Complete File Manifest

### B.1 New Production Files (19)

**Core/ files (9) — pure algorithms, Linux-safe:**

| # | Path | Lines | Layer | Description |
|---|------|-------|-------|-------------|
| 1 | `Core/Constants/ScanGuidanceConstants.swift` | ~500 | 8 | 65+ SSOT constants in 9 sections |
| 2 | `Core/Quality/Geometry/WedgeGeometryGenerator.swift` | ~550 | 3 | Triangle→wedge extrusion with bevel |
| 3 | `Core/Quality/Geometry/MeshAdjacencyGraph.swift` | ~250 | 3 | Shared-edge adjacency for ripple BFS |
| 4 | `Core/Quality/Geometry/ScanTriangle.swift` | ~80 | 3 | Triangle data type (vertices, patchId, area) |
| 5 | `Core/Quality/Animation/FlipAnimationController.swift` | ~400 | 5 | Threshold-crossing flip with overshoot easing |
| 6 | `Core/Quality/Animation/RipplePropagationEngine.swift` | ~350 | 5 | BFS wave propagation through adjacency |
| 7 | `Core/Quality/Visualization/AdaptiveBorderCalculator.swift` | ~200 | 2 | Dual-factor (display + area) border width |
| 8 | `Core/Quality/Performance/ThermalQualityAdapter.swift` | ~350 | 7 | 4-tier thermal-adaptive quality system |
| 9 | `Core/Quality/Platform/RenderingPlatformProtocol.swift` | ~150 | 9 | Cross-platform interface ports |

**App/ files (10) — Apple-platform, Metal/ARKit/CoreHaptics:**

| # | Path | Lines | Layer | Description |
|---|------|-------|-------|-------------|
| 10 | `App/ScanGuidance/ScanGuidanceRenderPipeline.swift` | ~650 | 2 | Metal 6-pass orchestrator, triple-buffered |
| 11 | `App/ScanGuidance/Shaders/ScanGuidance.metal` | ~800 | 2-4 | All Metal vertex/fragment shaders |
| 12 | `App/ScanGuidance/EnvironmentLightEstimator.swift` | ~400 | 4 | 3-tier light estimation (ARKit/vision/fallback) |
| 13 | `App/ScanGuidance/EvidenceRenderer.swift` | ~450 | 2 | SwiftUI↔Metal bridge for HEAT_COOL_COVERAGE |
| 14 | `App/ScanGuidance/GuidanceHints.swift` | ~200 | 2 | DIRECTIONAL_AFFORDANCE implementation |
| 15 | `App/ScanGuidance/GuidanceHapticEngine.swift` | ~450 | 6 | 3+1 haptic patterns with debounce |
| 16 | `App/ScanGuidance/GuidanceToastPresenter.swift` | ~250 | 6 | Black-bg/white-text toast (secondary to haptic) |
| 17 | `App/ScanGuidance/ScanCaptureControls.swift` | ~200 | 6 | White-border black-fill circle, long-press menu |
| 18 | `App/ScanGuidance/ScanCompletionBridge.swift` | ~80 | 6 | NotificationCenter bridge: RecordingController→HapticEngine |
| 19 | `App/ScanGuidance/GrayscaleMapper.swift` | ~120 | 2 | Continuous [0,1]→grayscale, bypasses discrete ColorState |

### B.2 Modified Files (2)

| Path | Change |
|------|--------|
| `Core/Quality/Visualization/GuidanceRenderer.swift` | **v7.0.3: NO MODIFICATION.** Stays exactly as-is. `HeatCoolCoverageView()` / `DirectionalAffordanceView()` remain `EmptyView()` placeholders. PR7 does NOT touch this file — wiring to real views happens via `GuidanceRendererDelegate` injection at App-layer when Xcode project is created. |
| `Core/Constants/SSOTRegistry.swift` | **v7.0.3:** Add `all.append(contentsOf: ScanGuidanceConstants.allSpecs)` and `errors.append(contentsOf: ScanGuidanceConstants.validateRelationships())` |

### B.3 Test Files (10)

**v7.0.3: Tests are split into two categories:**
- **Core-only tests (7):** In SwiftPM `ScanGuidanceTests` target, depend on `Aether3DCore`, compile on macOS + Linux.
- **App-layer tests (3):** Reference App/ types (`EnvironmentLightEstimator`, `GuidanceHapticEngine`, `ScanGuidanceRenderPipeline`). These are **deferred** until Xcode project exists. For now, they are written as stub files with all test bodies wrapped in `#if canImport(CoreHaptics)` / `#if canImport(Metal)` guards so they compile but produce no tests in SwiftPM.

**Core-only tests (compile and run in SwiftPM):**

| # | Path | Tests |
|---|------|-------|
| 1 | `Tests/ScanGuidanceTests/ScanGuidanceConstantsTests.swift` | SSOT registration, cross-validation, range checks |
| 2 | `Tests/ScanGuidanceTests/WedgeGeometryTests.swift` | Extrusion correctness, LOD triangle counts, bevel normals |
| 3 | `Tests/ScanGuidanceTests/FlipAnimationTests.swift` | Easing curve, threshold detection, duration bounds |
| 4 | `Tests/ScanGuidanceTests/RipplePropagationTests.swift` | BFS distances, damping decay, max hop limit |
| 5 | `Tests/ScanGuidanceTests/AdaptiveBorderTests.swift` | Dual-factor width, gamma correction, min/max clamp |
| 6 | `Tests/ScanGuidanceTests/ThermalQualityTests.swift` | Tier transitions, hysteresis 10s, LOD mapping |
| 7 | `Tests/ScanGuidanceTests/MonotonicityStressTests.swift` | 10k random updates never decrease display |

**App-layer tests (stubs — bodies guarded, deferred until Xcode project):**

| # | Path | Tests (deferred) |
|---|------|-----------------|
| 8 | `Tests/ScanGuidanceTests/EnvironmentLightTests.swift` | Tier fallback, SH coefficient count, fallback direction |
| 9 | `Tests/ScanGuidanceTests/GuidanceHapticTests.swift` | Debounce 5s, max 4/min, pattern→CHHaptic mapping |
| 10 | `Tests/ScanGuidanceTests/RenderPipelineTests.swift` | Triple buffer semaphore, pass ordering, quality tier |

### B.4 Package.swift Changes

```swift
// TWO changes required in Package.swift:

// 1. Add "ScanGuidanceTests" to Aether3DCoreTests exclude list
// (existing target at line ~82-92, path: "Tests", exclude: [...])
.testTarget(
    name: "Aether3DCoreTests",
    dependencies: ["Aether3DCore"],
    path: "Tests",
    exclude: [
        // ... existing excludes ...
        "EvidenceGridDeterminismTests",
        "ScanGuidanceTests"  // ← v7.0.2 ADD THIS
    ],
    // ... resources stay same ...
)

// 2. Add new ScanGuidanceTests target
.testTarget(
    name: "ScanGuidanceTests",
    dependencies: ["Aether3DCore"],
    path: "Tests/ScanGuidanceTests"
)
```

**v7.0.2 CRITICAL:** Without adding `"ScanGuidanceTests"` to `Aether3DCoreTests.exclude`, SwiftPM will error: `multiple targets have overlapping sources`. This matches the existing pattern — every separate test target (PR4MathTests, PR5CaptureTests, EvidenceGridTests, etc.) is already in the exclude list.

Note: `Core/Quality/` files are automatically included in `Aether3DCore` target (path: "Core"). `App/ScanGuidance/` files are managed by Xcode project (not SwiftPM), compiled only on iOS/macOS.

**Total: 19 new + 1 modified + 10 test = 30 files, ~9,800 lines**

---

## Part C: Per-File Interface Definitions

### C.1 ScanGuidanceConstants.swift (Layer 8) — `Core/Constants/`

```swift
// Core/Constants/ScanGuidanceConstants.swift
// 65+ constants in 9 sections, all SSOT-registered
// NO platform imports — Foundation only

import Foundation

public enum ScanGuidanceConstants {

    // MARK: - Section 1: Grayscale Mapping (8 constants)
    // Colors read from CoverageVisualizationConstants — NOT redefined here
    // NOTE: PR7 uses CONTINUOUS grayscale from display [0,1],
    //       NOT discrete ColorState (S1/S2 both map to .darkGray in EvidenceStateMachine).
    //       GrayscaleMapper.swift converts display→RGB directly.

    /// S0→S1 threshold (display value)
    public static let s0ToS1Threshold: Double = 0.10
    /// S1→S2 threshold
    public static let s1ToS2Threshold: Double = 0.25
    /// S2→S3 threshold
    public static let s2ToS3Threshold: Double = 0.50
    /// S3→S4 threshold
    public static let s3ToS4Threshold: Double = 0.75
    /// S4→S5 threshold (white threshold from EvidenceStateMachine)
    public static let s4ToS5Threshold: Double = 0.88
    /// S5 minimum soft evidence
    public static let s5MinSoftEvidence: Double = 0.75
    /// Continuous grayscale interpolation gamma
    public static let grayscaleGamma: Double = 1.0
    /// S4 transparency alpha (original color shows through)
    public static let s4TransparencyAlpha: Double = 0.0

    // MARK: - Section 2: Border System (8 constants)

    /// Base border width (pixels)
    public static let borderBaseWidthPx: Double = 6.0
    /// Minimum border width (pixels)
    public static let borderMinWidthPx: Double = 1.0
    /// Maximum border width (pixels)
    public static let borderMaxWidthPx: Double = 12.0
    /// Display factor weight in border calculation
    public static let borderDisplayWeight: Double = 0.6
    /// Area factor weight in border calculation
    public static let borderAreaWeight: Double = 0.4
    /// Border gamma (Stevens' Power Law for brightness perception)
    public static let borderGamma: Double = 1.4
    /// Border color: white RGB(255,255,255)
    /// v7.0.3: Changed from UInt8 to Int for SystemConstantSpec registration
    public static let borderColorR: Int = 255
    /// Border alpha at S0 (fully opaque)
    public static let borderAlphaAtS0: Double = 1.0

    // MARK: - Section 3: Wedge Geometry (8 constants)

    /// Base wedge thickness (meters) at display=0
    public static let wedgeBaseThicknessM: Double = 0.008
    /// Minimum wedge thickness (meters) at display≈1
    public static let wedgeMinThicknessM: Double = 0.0005
    /// Thickness decay exponent: thickness = base * (1-display)^exponent
    public static let thicknessDecayExponent: Double = 0.7
    /// Area factor reference (median area normalization)
    public static let areaFactorReference: Double = 1.0
    /// Bevel segments for LOD0
    public static let bevelSegmentsLOD0: Int = 2
    /// Bevel segments for LOD1
    public static let bevelSegmentsLOD1: Int = 1
    /// Bevel radius ratio (fraction of thickness)
    public static let bevelRadiusRatio: Double = 0.15
    /// LOD0 triangles per prism
    public static let lod0TrianglesPerPrism: Int = 44

    // MARK: - Section 4: Metallic Material (6 constants)

    /// Base metallic value
    public static let metallicBase: Double = 0.3
    /// Metallic increase at S3+
    public static let metallicS3Bonus: Double = 0.4
    /// Base roughness
    public static let roughnessBase: Double = 0.6
    /// Roughness decrease at S3+
    public static let roughnessS3Reduction: Double = 0.3
    /// Fresnel F0 for dielectric
    public static let fresnelF0: Double = 0.04
    /// Fresnel F0 for metallic
    public static let fresnelF0Metallic: Double = 0.7

    // MARK: - Section 5: Flip Animation (8 constants)

    /// Flip duration (seconds)
    public static let flipDurationS: Double = 0.5
    /// Flip easing control point 1 X (cubic bezier)
    public static let flipEasingCP1X: Double = 0.34
    /// Flip easing control point 1 Y (overshoot)
    public static let flipEasingCP1Y: Double = 1.56
    /// Flip easing control point 2 X
    public static let flipEasingCP2X: Double = 0.64
    /// Flip easing control point 2 Y
    public static let flipEasingCP2Y: Double = 1.0
    /// Maximum concurrent flips
    public static let flipMaxConcurrent: Int = 20
    /// Flip stagger delay between adjacent triangles (seconds)
    public static let flipStaggerDelayS: Double = 0.03
    /// Minimum display delta to trigger flip
    public static let flipMinDisplayDelta: Double = 0.05

    // MARK: - Section 6: Ripple Propagation (7 constants)

    /// Delay per BFS hop (seconds)
    public static let rippleDelayPerHopS: Double = 0.06
    /// Maximum BFS hops
    public static let rippleMaxHops: Int = 8
    /// Amplitude damping per hop
    public static let rippleDampingPerHop: Double = 0.85
    /// Initial ripple amplitude
    public static let rippleInitialAmplitude: Double = 1.0
    /// Ripple thickness multiplier
    public static let rippleThicknessMultiplier: Double = 0.3
    /// Maximum concurrent ripple waves
    public static let rippleMaxConcurrentWaves: Int = 5
    /// Minimum interval between ripple spawns from same source (seconds)
    public static let rippleMinSpawnIntervalS: Double = 0.5

    // MARK: - Section 7: Haptic & Toast (10 constants)

    /// Haptic debounce interval (seconds)
    public static let hapticDebounceS: Double = 5.0
    /// Maximum haptic events per minute
    public static let hapticMaxPerMinute: Int = 4
    /// Haptic blur threshold — MUST equal QualityThresholds.laplacianBlurThreshold
    public static let hapticBlurThreshold: Double = 120.0
    /// Haptic motion threshold
    public static let hapticMotionThreshold: Double = 0.7
    /// Haptic exposure threshold
    public static let hapticExposureThreshold: Double = 0.2
    /// Toast display duration (seconds)
    public static let toastDurationS: Double = 2.0
    /// Toast accessibility duration (seconds) — VoiceOver users
    public static let toastAccessibilityDurationS: Double = 5.0
    /// Toast background color alpha
    public static let toastBackgroundAlpha: Double = 0.85
    /// Toast corner radius (points)
    public static let toastCornerRadius: Double = 12.0
    /// Toast font size (points)
    public static let toastFontSize: Double = 15.0

    // MARK: - Section 8: Performance & Thermal (8 constants)

    /// Maximum inflight Metal buffers
    public static let kMaxInflightBuffers: Int = 3
    /// Nominal tier: max triangles
    public static let thermalNominalMaxTriangles: Int = 5000
    /// Fair tier: max triangles
    public static let thermalFairMaxTriangles: Int = 3000
    /// Serious tier: max triangles
    public static let thermalSeriousMaxTriangles: Int = 1500
    /// Critical tier: max triangles
    public static let thermalCriticalMaxTriangles: Int = 500
    /// Thermal hysteresis duration (seconds)
    public static let thermalHysteresisS: Double = 10.0
    /// Frame budget overshoot threshold (ratio of target frame time)
    public static let frameBudgetOvershootRatio: Double = 1.2
    /// Frame budget measurement window (frames)
    public static let frameBudgetWindowFrames: Int = 30

    // MARK: - Section 9: Accessibility (4 constants)

    /// Minimum contrast ratio (WCAG 2.1 AAA for toast)
    public static let minContrastRatio: Double = 17.4
    /// VoiceOver announcement delay after haptic (seconds)
    public static let voiceOverDelayS: Double = 0.3
    /// Reduce motion: disable flip animation
    /// v7.0.2: Bool constants are NOT registered in allSpecs (no BoolConstantSpec)
    public static let reduceMotionDisablesFlip: Bool = true
    /// Reduce motion: disable ripple animation
    public static let reduceMotionDisablesRipple: Bool = true

    // MARK: - SSOT Specifications
    // v7.0.2: Only Double/Int constants registered. Bool constants excluded
    //         because AnyConstantSpec has no BoolConstantSpec case.
    //         63 specs (65 total - 2 Bool constants)

    public static let allSpecs: [AnyConstantSpec] = [
        // ... 63 specs registered here (Double→ThresholdSpec, Int→SystemConstantSpec)
        // Bool constants (reduceMotionDisablesFlip, reduceMotionDisablesRipple) NOT included
    ]

    // MARK: - Cross-Validation

    public static func validateRelationships() -> [String] {
        var errors: [String] = []
        if hapticBlurThreshold != QualityThresholds.laplacianBlurThreshold {
            errors.append("hapticBlurThreshold (\(hapticBlurThreshold)) != QualityThresholds.laplacianBlurThreshold (\(QualityThresholds.laplacianBlurThreshold))")
        }
        let thresholds = [s0ToS1Threshold, s1ToS2Threshold, s2ToS3Threshold, s3ToS4Threshold, s4ToS5Threshold]
        for i in 1..<thresholds.count {
            if thresholds[i] <= thresholds[i-1] {
                errors.append("S-thresholds not monotonic at index \(i)")
            }
        }
        return errors
    }
}
```

### C.2 ScanGuidanceRenderPipeline.swift (Layer 2) — `App/ScanGuidance/`

```swift
// App/ScanGuidance/ScanGuidanceRenderPipeline.swift
// Metal 6-pass render orchestrator with triple buffering
// Apple-platform only (import Metal)

import Metal
import MetalKit
import simd
import QuartzCore  // for CACurrentMediaTime — OK in App/

public final class ScanGuidanceRenderPipeline {

    public static let kMaxInflightBuffers: Int = ScanGuidanceConstants.kMaxInflightBuffers
    private let inflightSemaphore: DispatchSemaphore
    private var currentBufferIndex: Int = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var wedgeFillPipeline: MTLRenderPipelineState!
    private var borderStrokePipeline: MTLRenderPipelineState!
    private var metallicLightingPipeline: MTLRenderPipelineState!

    // Sub-systems (Core/ pure algorithms)
    private let wedgeGenerator: WedgeGeometryGenerator
    private let flipController: FlipAnimationController
    private let rippleEngine: RipplePropagationEngine
    private let borderCalculator: AdaptiveBorderCalculator
    private let thermalAdapter: ThermalQualityAdapter

    // Sub-systems (App/ platform-specific)
    private let lightEstimator: EnvironmentLightEstimator
    private let grayscaleMapper: GrayscaleMapper

    // Triple-buffered Metal buffers
    private var vertexBuffers: [MTLBuffer]
    private var uniformBuffers: [MTLBuffer]
    private var instanceBuffers: [MTLBuffer]

    public init(device: MTLDevice) throws {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.inflightSemaphore = DispatchSemaphore(value: Self.kMaxInflightBuffers)
        self.wedgeGenerator = WedgeGeometryGenerator()
        self.lightEstimator = EnvironmentLightEstimator()
        self.flipController = FlipAnimationController()
        self.rippleEngine = RipplePropagationEngine()
        self.borderCalculator = AdaptiveBorderCalculator()
        self.thermalAdapter = ThermalQualityAdapter()
        self.grayscaleMapper = GrayscaleMapper()
        self.vertexBuffers = []
        self.uniformBuffers = []
        self.instanceBuffers = []
    }

    /// Per-frame update — reads from PatchDisplayMap snapshot, no coverage dependency
    /// v7.0.2: displaySnapshot is [String: Double], converted from [DisplayEntry]
    ///         by caller (see Part A.2 for conversion pattern)
    public func update(
        displaySnapshot: [String: Double],
        colorStates: [String: ColorState],
        meshTriangles: [ScanTriangle],
        lightEstimate: Any?,  // ARLightEstimate on iOS
        cameraTransform: simd_float4x4,
        frameDeltaTime: TimeInterval
    ) {
        let tier = thermalAdapter.currentTier
        let lodLevel = tier.lodLevel

        let wedgeData = wedgeGenerator.generate(
            triangles: meshTriangles,
            displayValues: displaySnapshot,
            lod: lodLevel
        )

        let lightState = lightEstimator.update(
            lightEstimate: lightEstimate,
            cameraImage: nil,
            timestamp: CACurrentMediaTime()
        )

        let flipAngles = flipController.tick(deltaTime: frameDeltaTime)
        let rippleAmplitudes = rippleEngine.tick(currentTime: CACurrentMediaTime())
        let borderWidths = borderCalculator.calculate(
            displayValues: displaySnapshot,
            triangleAreas: meshTriangles.map { $0.areaSqM },
            medianArea: meshTriangles.medianArea
        )

        uploadToBuffers(
            wedgeData: wedgeData,
            lightState: lightState,
            flipAngles: flipAngles,
            rippleAmplitudes: rippleAmplitudes,
            borderWidths: borderWidths,
            cameraTransform: cameraTransform
        )
    }

    /// Encode all render passes into command buffer
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        inflightSemaphore.wait()
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }
        let bufferIndex = currentBufferIndex
        currentBufferIndex = (currentBufferIndex + 1) % Self.kMaxInflightBuffers

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else { return }

        encodeWedgeFill(encoder: encoder, bufferIndex: bufferIndex)
        encodeBorderStroke(encoder: encoder, bufferIndex: bufferIndex)
        encodeMetallicLighting(encoder: encoder, bufferIndex: bufferIndex)
        encoder.endEncoding()
    }

    public func applyRenderTier(_ tier: ThermalQualityAdapter.RenderTier) {
        thermalAdapter.forceRenderTier(tier)
    }

    private func encodeWedgeFill(encoder: MTLRenderCommandEncoder, bufferIndex: Int) { /* ... */ }
    private func encodeBorderStroke(encoder: MTLRenderCommandEncoder, bufferIndex: Int) { /* ... */ }
    private func encodeMetallicLighting(encoder: MTLRenderCommandEncoder, bufferIndex: Int) { /* ... */ }
    private func uploadToBuffers(wedgeData: WedgeVertexData, lightState: EnvironmentLightEstimator.LightState, flipAngles: [Float], rippleAmplitudes: [Float], borderWidths: [Float], cameraTransform: simd_float4x4) { /* ... */ }
}
```

### C.3 ScanGuidance.metal (Layers 2-4) — `App/ScanGuidance/Shaders/`

```metal
// App/ScanGuidance/Shaders/ScanGuidance.metal
// ~800 lines — All Metal shading for scan guidance

#include <metal_stdlib>
using namespace metal;

// ─── Structs ───

struct WedgeVertex {
    float3 position     [[attribute(0)]];
    float3 normal       [[attribute(1)]];
    float  metallic     [[attribute(2)]];
    float  roughness    [[attribute(3)]];
    float  display      [[attribute(4)]];
    float  thickness    [[attribute(5)]];
    uint   triangleId   [[attribute(6)]];
};

struct ScanGuidanceUniforms {
    float4x4 viewProjectionMatrix;
    float4x4 modelMatrix;
    float3   cameraPosition;
    float3   primaryLightDirection;
    float    primaryLightIntensity;
    float3   shCoeffs[9];
    uint     qualityTier;
    float    time;
};

// v7.0.1 FIX: Use float3 instead of uint8_t×3 to avoid Metal alignment issues
struct PerTriangleData {
    float  flipAngle;
    float  rippleAmplitude;
    float  borderWidth;
    float3 flipAxisOrigin;
    float3 flipAxisDirection;
    float3 grayscaleColor;  // v7.0.1: was uint8_t×3, now float3 [0,1]
};

// ─── BRDF Helpers (~25 ALU/fragment total) ───

inline float D_GGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (3.14159265 * denom * denom);
}

inline float3 F_Schlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

inline float V_SmithGGXFast(float NdotV, float NdotL, float roughness) {
    float a = roughness;
    float GGXV = NdotL * (NdotV * (1.0 - a) + a);
    float GGXL = NdotV * (NdotL * (1.0 - a) + a);
    return 0.5 / (GGXV + GGXL + 1e-5);
}

inline float3 evaluateSH(float3 normal, constant float3 *shCoeffs) {
    float3 result = shCoeffs[0];
    result += shCoeffs[1] * normal.y;
    result += shCoeffs[2] * normal.z;
    result += shCoeffs[3] * normal.x;
    result += shCoeffs[4] * (normal.x * normal.y);
    result += shCoeffs[5] * (normal.y * normal.z);
    result += shCoeffs[6] * (3.0 * normal.z * normal.z - 1.0);
    result += shCoeffs[7] * (normal.x * normal.z);
    result += shCoeffs[8] * (normal.x * normal.x - normal.y * normal.y);
    return max(result, float3(0.0));
}

inline float sdTriangle2D(float2 p, float2 a, float2 b, float2 c) {
    float2 ba = b - a, cb = c - b, ac = a - c;
    float2 pa = p - a, pb = p - b, pc = p - c;
    float2 nor = float2(ba.y, -ba.x);
    float s = sign(dot(nor, pa));
    float2 d1 = pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    float2 d2 = pb - cb * clamp(dot(pb, cb) / dot(cb, cb), 0.0, 1.0);
    float2 d3 = pc - ac * clamp(dot(pc, ac) / dot(ac, ac), 0.0, 1.0);
    float md = min(min(dot(d1,d1), dot(d2,d2)), dot(d3,d3));
    return sqrt(md) * s;
}

inline float sdRoundedTriangle(float2 p, float2 a, float2 b, float2 c, float r) {
    return sdTriangle2D(p, a, b, c) - r;
}

// v7.0.1 FIX: Complete translate-rotate-untranslate transform
inline float4x4 makeTranslation(float3 t) {
    return float4x4(
        float4(1, 0, 0, 0),
        float4(0, 1, 0, 0),
        float4(0, 0, 1, 0),
        float4(t.x, t.y, t.z, 1)
    );
}

inline float4x4 flipRotationMatrix(float3 axisOrigin, float3 axisDir, float angle) {
    float c = cos(angle), s = sin(angle);
    float t = 1.0 - c;
    float3 a = axisDir;
    float4x4 rot = float4x4(
        float4(t*a.x*a.x + c,     t*a.x*a.y - s*a.z, t*a.x*a.z + s*a.y, 0),
        float4(t*a.x*a.y + s*a.z, t*a.y*a.y + c,     t*a.y*a.z - s*a.x, 0),
        float4(t*a.x*a.z - s*a.y, t*a.y*a.z + s*a.x, t*a.z*a.z + c,     0),
        float4(0, 0, 0, 1)
    );
    // Translate to origin, rotate, translate back
    float4x4 T = makeTranslation(-axisOrigin);
    float4x4 Tinv = makeTranslation(axisOrigin);
    return Tinv * rot * T;
}

// ─── Vertex/Fragment Shaders ───

struct VertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPosition;
    float  metallic;
    float  roughness;
    float  display;
    float  rippleAmplitude;
    float3 grayscaleColor;
    float  borderWidth;
};

vertex VertexOut wedgeFillVertex(
    WedgeVertex in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]],
    constant PerTriangleData *triData [[buffer(2)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    uint triId = in.triangleId;
    float4 pos = float4(in.position, 1.0);
    float angle = triData[triId].flipAngle;
    if (angle > 0.001) {
        float4x4 rot = flipRotationMatrix(
            triData[triId].flipAxisOrigin,
            triData[triId].flipAxisDirection,
            angle
        );
        pos = rot * pos;
    }
    out.position = uniforms.viewProjectionMatrix * uniforms.modelMatrix * pos;
    out.worldNormal = (uniforms.modelMatrix * float4(in.normal, 0.0)).xyz;
    out.worldPosition = (uniforms.modelMatrix * pos).xyz;
    out.metallic = in.metallic;
    out.roughness = in.roughness;
    out.display = in.display;
    out.rippleAmplitude = triData[triId].rippleAmplitude;
    out.grayscaleColor = triData[triId].grayscaleColor;
    out.borderWidth = triData[triId].borderWidth;
    return out;
}

fragment float4 wedgeFillFragment(VertexOut in [[stage_in]]) {
    return float4(in.grayscaleColor, 1.0);
}

fragment float4 metallicLightingFragment(
    VertexOut in [[stage_in]],
    constant ScanGuidanceUniforms &uniforms [[buffer(1)]]
) {
    if (uniforms.qualityTier >= 2) {
        return float4(in.grayscaleColor, 1.0);
    }
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);
    float3 L = normalize(uniforms.primaryLightDirection);
    float3 H = normalize(V + L);
    float NdotV = max(dot(N, V), 0.001);
    float NdotL = max(dot(N, L), 0.001);
    float NdotH = max(dot(N, H), 0.0);
    float VdotH = max(dot(V, H), 0.0);
    float D = D_GGX(NdotH, in.roughness);
    float3 F0 = mix(float3(0.04), in.grayscaleColor, in.metallic);
    float3 F = F_Schlick(VdotH, F0);
    float Vis = V_SmithGGXFast(NdotV, NdotL, in.roughness);
    float3 specular = D * F * Vis;
    float3 kD = (1.0 - F) * (1.0 - in.metallic);
    float3 diffuse = kD * in.grayscaleColor / 3.14159265;
    float3 ambient = evaluateSH(N, uniforms.shCoeffs) * in.grayscaleColor;
    float rippleHighlight = in.rippleAmplitude * 0.15;
    float3 color = ambient + (diffuse + specular) * NdotL * uniforms.primaryLightIntensity;
    color += rippleHighlight;
    return float4(color, 1.0);
}
```

### C.4 WedgeGeometryGenerator.swift (Layer 3) — `Core/Quality/Geometry/`

```swift
// Core/Quality/Geometry/WedgeGeometryGenerator.swift
// Pure algorithm — Foundation + simd only, NO Metal import

import Foundation
#if canImport(simd)
import simd
#endif

public struct WedgeVertexData {
    public let vertices: [WedgeVertexCPU]
    public let indices: [UInt32]
    public let triangleCount: Int
}

public struct WedgeVertexCPU {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var metallic: Float
    public var roughness: Float
    public var display: Float
    public var thickness: Float
    public var triangleId: UInt32
}

// v7.0.2 NOTE: SIMD3<Float> is part of Swift standard library, available on Linux.
// This matches existing Core/ pattern: DuplicateDetector.swift uses SIMD3<Float>
// unguarded in struct definitions with #if canImport(simd) only for the import.

public final class WedgeGeometryGenerator {

    public enum LODLevel: Int, CaseIterable {
        case full = 0    // 44 tri/prism (2-segment bevel)
        case medium = 1  // 26 tri/prism (1-segment bevel)
        case low = 2     // 8 tri/prism (sharp edges)
        case flat = 3    // 2 tri/prism (no extrusion)
    }

    public func generate(
        triangles: [ScanTriangle],
        displayValues: [String: Double],
        lod: LODLevel
    ) -> WedgeVertexData {
        fatalError("Implementation in Phase 2")
    }

    public func thickness(
        display: Double,
        areaSqM: Float,
        medianArea: Float
    ) -> Float {
        let base = Float(ScanGuidanceConstants.wedgeBaseThicknessM)
        let minT = Float(ScanGuidanceConstants.wedgeMinThicknessM)
        let exponent = Float(ScanGuidanceConstants.thicknessDecayExponent)
        let decayFactor = pow(1.0 - Float(display), exponent)
        let areaFactor = sqrt(areaSqM / max(medianArea, 1e-6))
        let clampedAreaFactor = min(max(areaFactor, 0.5), 2.0)
        return max(minT, base * decayFactor * clampedAreaFactor)
    }

    public func bevelNormals(
        topFaceNormal: SIMD3<Float>,
        sideFaceNormal: SIMD3<Float>,
        segments: Int
    ) -> [SIMD3<Float>] {
        var normals: [SIMD3<Float>] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments)
            let mixed = topFaceNormal * (1.0 - t) + sideFaceNormal * t
            let len = (mixed.x * mixed.x + mixed.y * mixed.y + mixed.z * mixed.z).squareRoot()
            normals.append(len > 0 ? mixed / len : mixed)
        }
        return normals
    }
}
```

### C.5 ThermalQualityAdapter.swift (Layer 7) — `Core/Quality/Performance/`

```swift
// Core/Quality/Performance/ThermalQualityAdapter.swift
// Pure algorithm — Foundation only, NO QuartzCore/Metal
// v7.0.1: Renamed QualityTier→RenderTier to avoid clash with existing QualityTier
// v7.0.1: Uses ProcessInfo.processInfo.systemUptime instead of CACurrentMediaTime()
// v7.0.2: ProcessInfo.ThermalState wrapped in #if os(iOS) || os(macOS)

import Foundation

public final class ThermalQualityAdapter {

    /// Render quality tiers (v7.0.1: renamed from QualityTier to avoid clash)
    public enum RenderTier: Int, CaseIterable, Sendable {
        case nominal = 0
        case fair = 1
        case serious = 2
        case critical = 3

        public var lodLevel: WedgeGeometryGenerator.LODLevel {
            switch self {
            case .nominal:  return .full
            case .fair:     return .medium
            case .serious:  return .low
            case .critical: return .flat
            }
        }

        public var maxTriangles: Int {
            switch self {
            case .nominal:  return ScanGuidanceConstants.thermalNominalMaxTriangles
            case .fair:     return ScanGuidanceConstants.thermalFairMaxTriangles
            case .serious:  return ScanGuidanceConstants.thermalSeriousMaxTriangles
            case .critical: return ScanGuidanceConstants.thermalCriticalMaxTriangles
            }
        }

        public var targetFPS: Int {
            switch self {
            case .nominal:  return 60
            case .fair:     return 60
            case .serious:  return 30
            case .critical: return 24
            }
        }

        public var enableFlipAnimation: Bool { self.rawValue <= 1 }
        public var enableRipple: Bool { self.rawValue <= 1 }
        public var enableMetallicBRDF: Bool { self.rawValue <= 1 }
        public var enableHaptics: Bool { self.rawValue <= 2 }
    }

    public private(set) var currentTier: RenderTier = .nominal

    private var lastTierChangeTime: TimeInterval = 0
    private var frameTimeSamples: [Double] = []

    /// v7.0.1: Cross-platform time source
    private func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// v7.0.2: ProcessInfo.ThermalState is Darwin-only.
    /// On Linux, this method is unavailable — caller uses updateFrameTiming() only.
    /// Pattern matches existing MobileThermalStateHandler.swift (#if os(iOS))
    #if os(iOS) || os(macOS)
    public func updateThermalState(_ state: ProcessInfo.ThermalState) {
        let targetTier: RenderTier
        switch state {
        case .nominal:  targetTier = .nominal
        case .fair:     targetTier = .fair
        case .serious:  targetTier = .serious
        case .critical: targetTier = .critical
        @unknown default: targetTier = .fair
        }
        let now = currentTime()
        if targetTier != currentTier && (now - lastTierChangeTime) > ScanGuidanceConstants.thermalHysteresisS {
            currentTier = targetTier
            lastTierChangeTime = now
        }
    }
    #endif

    public func updateFrameTiming(gpuDurationMs: Double) {
        frameTimeSamples.append(gpuDurationMs)
        if frameTimeSamples.count > ScanGuidanceConstants.frameBudgetWindowFrames {
            frameTimeSamples.removeFirst()
        }
        let targetMs = 1000.0 / Double(currentTier.targetFPS)
        let threshold = targetMs * ScanGuidanceConstants.frameBudgetOvershootRatio
        let sorted = frameTimeSamples.sorted()
        let p95Index = Int(Double(sorted.count) * 0.95)
        let p95 = sorted[min(p95Index, sorted.count - 1)]
        if p95 > threshold {
            let nextTier = RenderTier(rawValue: min(currentTier.rawValue + 1, 3))!
            let now = currentTime()
            if (now - lastTierChangeTime) > ScanGuidanceConstants.thermalHysteresisS {
                currentTier = nextTier
                lastTierChangeTime = now
            }
        }
    }

    public func forceRenderTier(_ tier: RenderTier) {
        currentTier = tier
        lastTierChangeTime = currentTime()
    }
}
```

### C.6 GuidanceHapticEngine.swift (Layer 6) — `App/ScanGuidance/`

```swift
// App/ScanGuidance/GuidanceHapticEngine.swift
// Apple-platform only

#if canImport(CoreHaptics)
import CoreHaptics
#endif
import Foundation

/// v7.0.1: Subscribes to QualityFeedbackUpdate which has 6 fields:
///   averageBlur, averageExposure, averageTexture, averageMotion,
///   qualityTier (.acceptable/.warning/.rejected), warnings: [String]
/// PR7 reads averageBlur/averageMotion/averageExposure for haptic triggers.
public final class GuidanceHapticEngine {

    public enum HapticPattern: String, CaseIterable {
        case motionTooFast
        case blurDetected
        case exposureAbnormal
        case scanComplete
    }

    private var lastFireTimes: [HapticPattern: TimeInterval] = [:]
    private var recentFireTimestamps: [TimeInterval] = []

    #if canImport(CoreHaptics)
    private var hapticEngine: CHHapticEngine?
    #endif

    public func fire(
        pattern: HapticPattern,
        timestamp: TimeInterval,
        toastPresenter: GuidanceToastPresenter?
    ) -> Bool {
        guard shouldFire(pattern: pattern, at: timestamp) else { return false }
        lastFireTimes[pattern] = timestamp
        recentFireTimestamps.append(timestamp)
        recentFireTimestamps.removeAll { timestamp - $0 > 60.0 }
        fireHapticPattern(pattern)
        toastPresenter?.show(message: toastMessage(for: pattern))
        return true
    }

    public func fireCompletion() {
        fireHapticPattern(.scanComplete)
    }

    internal func shouldFire(pattern: HapticPattern, at time: TimeInterval) -> Bool {
        if let lastTime = lastFireTimes[pattern],
           time - lastTime < ScanGuidanceConstants.hapticDebounceS {
            return false
        }
        let recentCount = recentFireTimestamps.filter { time - $0 < 60.0 }.count
        if recentCount >= ScanGuidanceConstants.hapticMaxPerMinute {
            return false
        }
        return true
    }

    private func toastMessage(for pattern: HapticPattern) -> String {
        switch pattern {
        case .motionTooFast:    return "请您放慢移动速度"
        case .blurDetected:     return "请您保持手机稳定"
        case .exposureAbnormal: return "请您调整光线环境"
        case .scanComplete:     return "扫描完成！"
        }
    }

    private func fireHapticPattern(_ pattern: HapticPattern) {
        #if canImport(CoreHaptics)
        // CHHapticPattern per type
        #endif
    }
}
```

### C.7 ScanCompletionBridge.swift — `App/ScanGuidance/`

```swift
// App/ScanGuidance/ScanCompletionBridge.swift
// v7.0.1 NEW: Bridges RecordingController stop → HapticEngine completion
// Uses NotificationCenter (same pattern as HealthMonitorWithStrategies)

import Foundation

extension Notification.Name {
    /// Posted by RecordingController when scan stops
    public static let scanDidComplete = Notification.Name("PR7ScanDidComplete")
}

/// Observes scan completion and fires haptic
public final class ScanCompletionBridge {
    private let hapticEngine: GuidanceHapticEngine
    private var observation: NSObjectProtocol?

    public init(hapticEngine: GuidanceHapticEngine) {
        self.hapticEngine = hapticEngine
        observation = NotificationCenter.default.addObserver(
            forName: .scanDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hapticEngine.fireCompletion()
        }
    }

    deinit {
        if let obs = observation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
```

### C.8 GrayscaleMapper.swift — `App/ScanGuidance/`

```swift
// App/ScanGuidance/GrayscaleMapper.swift
// v7.0.1 NEW: Continuous display→grayscale conversion
// Bypasses discrete ColorState (S1/S2 both map to .darkGray in EvidenceStateMachine)

import Foundation

/// Maps display [0, 1] → continuous grayscale RGB
///
/// This is necessary because EvidenceStateMachine maps both S1 and S2
/// to the same `.darkGray` ColorState. PR7 needs finer-grained grayscale.
///
/// Mapping:
///   display 0.00 → RGB(0, 0, 0)       black
///   display 0.10 → RGB(64, 64, 64)    dark gray
///   display 0.25 → RGB(128, 128, 128) medium gray
///   display 0.50 → RGB(200, 200, 200) light gray
///   display 0.75 → original color (alpha blend)
///   display 0.88 → transparent (S5)
public struct GrayscaleMapper {

    /// Convert display value to grayscale RGB [0, 1]
    public func grayscale(for display: Double) -> (r: Float, g: Float, b: Float) {
        let clamped = min(max(display, 0.0), 1.0)

        // S0→S3: interpolate grayscale
        if clamped < ScanGuidanceConstants.s3ToS4Threshold {
            // Map [0, 0.75) → [0, 200/255]
            let t = Float(clamped / ScanGuidanceConstants.s3ToS4Threshold)
            let gray = t * (200.0 / 255.0)
            return (gray, gray, gray)
        }

        // S4+: return white (original color blending handled by shader)
        return (1.0, 1.0, 1.0)
    }
}
```

### C.9 Other Core/ Files

**FlipAnimationController, RipplePropagationEngine, MeshAdjacencyGraph, AdaptiveBorderCalculator, ScanTriangle, RenderingPlatformProtocol** — interfaces identical to v7.0 (see original Part C.6-C.12), with these path changes:

| v7.0 Path | v7.0.1 Path |
|-----------|-------------|
| `Core/Rendering/Animation/FlipAnimationController.swift` | `Core/Quality/Animation/FlipAnimationController.swift` |
| `Core/Rendering/Animation/RipplePropagationEngine.swift` | `Core/Quality/Animation/RipplePropagationEngine.swift` |
| `Core/Rendering/Geometry/MeshAdjacencyGraph.swift` | `Core/Quality/Geometry/MeshAdjacencyGraph.swift` |
| `Core/Rendering/Geometry/ScanTriangle.swift` | `Core/Quality/Geometry/ScanTriangle.swift` |
| `Core/Rendering/Border/AdaptiveBorderCalculator.swift` | `Core/Quality/Visualization/AdaptiveBorderCalculator.swift` |
| `Core/Rendering/Platform/RenderingPlatformProtocol.swift` | `Core/Quality/Platform/RenderingPlatformProtocol.swift` |

All use `import Foundation` (and `#if canImport(simd)` where needed). No Metal/ARKit imports. `CACurrentMediaTime()` replaced with `ProcessInfo.processInfo.systemUptime` where applicable.

---

## Part D: Data Flow Diagrams

### D.1 Per-Frame Update Sequence (60fps target)

```
Frame N begins
│
├─ [CPU 0.2ms] PatchDisplayMap.snapshotSorted()
│    └─ Returns [DisplayEntry] — monotonic display values
│    └─ v7.0.2: Convert to [String: Double] via .map { ($0.patchId, $0.display) }
│
├─ [CPU 0.05ms] GrayscaleMapper.grayscale(for:) per triangle
│    └─ Returns continuous RGB — NOT discrete ColorState
│
├─ [CPU 0.3ms] FlipAnimationController.checkThresholdCrossings()
│    ├─ Compare previous vs current display snapshot
│    └─ Returns [Int] — triangle indices that crossed S-thresholds
│
├─ [CPU 0.1ms] FlipAnimationController.tick(deltaTime)
│    └─ Returns [Float] — per-triangle rotation angles [0, PI]
│
├─ [CPU 0.1ms] RipplePropagationEngine.tick(currentTime)
│    └─ Returns [Float] — per-triangle ripple amplitudes [0, 1]
│
├─ [CPU 0.2ms] AdaptiveBorderCalculator.calculate()
│    └─ Returns [Float] — per-triangle border widths in pixels
│
├─ [CPU 0.5ms] WedgeGeometryGenerator.generate(lod: currentTier.lodLevel)
│    └─ Returns WedgeVertexData (vertices + indices)
│
├─ [CPU 0.1ms] EnvironmentLightEstimator.update()
│    └─ Returns LightState (direction, intensity, SH coefficients, tier)
│
├─ [CPU 0.2ms] Upload to triple-buffered Metal buffers
│    ├─ vertexBuffers[currentIndex]
│    ├─ uniformBuffers[currentIndex]
│    └─ instanceBuffers[currentIndex]
│
├─ [GPU 2-5ms] ScanGuidanceRenderPipeline.encode()
│    ├─ Pass 1: Wedge fill (vertex: position + flip rotation, fragment: grayscale)
│    ├─ Pass 2: Border stroke (fragment: adaptive width SDF)
│    └─ Pass 3: Metallic lighting (Cook-Torrance BRDF + SH ambient + ripple)
│
└─ Frame N complete — total CPU < 2ms, GPU < 5ms @ nominal tier
```

### D.2 Haptic → Toast Flow

```
QualityFeedback.onQualityUpdate callback
│  (QualityFeedbackUpdate has 6 fields:
│   averageBlur, averageExposure, averageTexture,
│   averageMotion, qualityTier, warnings)
│
├─ Check: averageMotion > 0.7?
│    └─ Yes → GuidanceHapticEngine.fire(.motionTooFast)
│
├─ Check: averageBlur < 120.0?
│    └─ Yes → GuidanceHapticEngine.fire(.blurDetected)
│
├─ Check: averageExposure > 0.2?
│    └─ Yes → GuidanceHapticEngine.fire(.exposureAbnormal)
│
└─ GuidanceHapticEngine.fire() internals:
     ├─ shouldFire() → check 5s debounce + 4/min rate limit
     ├─ If suppressed → return false
     ├─ Fire CHHapticEngine pattern
     └─ GuidanceToastPresenter.show("请您...")
          ├─ Black background (alpha 0.85)
          ├─ White text, 15pt
          ├─ Duration: 2s (normal) / 5s (VoiceOver)
          └─ HC-10: Toast is SECONDARY (paired with haptic)

Scan Completion Flow:
  RecordingController.requestStop()
  → posts Notification.Name.scanDidComplete
  → ScanCompletionBridge observes
  → GuidanceHapticEngine.fireCompletion()
       ├─ CHHapticContinuous 0.3s, intensity 1.0
       └─ GuidanceToastPresenter.show("扫描完成！")
```

---

## Part E: Phased Delivery Plan

### Phase 1: Foundation — MVP Grayscale Wedge (Weeks 1-3)

**Files:**
- `Core/Constants/ScanGuidanceConstants.swift` (all 65+ constants)
- `Core/Constants/SSOTRegistry.swift` (modify: add ScanGuidanceConstants registration)
- `Core/Quality/Geometry/ScanTriangle.swift` (data type)
- `Core/Quality/Geometry/WedgeGeometryGenerator.swift` (LOD3 flat only)
- `Core/Quality/Visualization/AdaptiveBorderCalculator.swift`
- `App/ScanGuidance/GrayscaleMapper.swift` (uncompiled until Xcode project — protocol stub in Core/)
- `App/ScanGuidance/EvidenceRenderer.swift` (uncompiled until Xcode project)
- `Package.swift` (add ScanGuidanceTests target + add exclude entry)

**v7.0.3: GuidanceRenderer.swift is NOT modified in Phase 1.** Placeholder views remain. Real views will be wired when Xcode project is created.

**Acceptance Criteria:**
1. `swift build` succeeds on macOS AND Linux
2. All 63 Double/Int constants registered in `allSpecs` (2 Bool constants excluded — HC-09)
3. `ScanGuidanceConstants.validateRelationships()` returns empty array
4. `SSOTRegistry.selfCheck()` returns empty array (includes PR7 specs)
5. WedgeGeometryGenerator produces correct vertex count for LOD3 (2 tri × N)
6. AdaptiveBorderCalculator output clamped to [1.0, 12.0] for all inputs
7. Monotonicity stress test: 10k random updates never decrease display
8. `ban_apple_only_imports.sh` passes — no Metal/ARKit imports in Core/
9. Package.swift: `Aether3DCoreTests` exclude list contains `"ScanGuidanceTests"`
10. `swift test` passes on macOS (7 Core tests) and Linux (7 Core tests)

### Phase 2: Metal Pipeline — GPU Rendering (Weeks 4-7)

**Files:**
- `App/ScanGuidance/ScanGuidanceRenderPipeline.swift`
- `App/ScanGuidance/Shaders/ScanGuidance.metal` (wedge fill + border passes only)
- `Core/Quality/Geometry/WedgeGeometryGenerator.swift` (upgrade to LOD0-LOD3)

**Acceptance Criteria:**
1. Metal shader compiles without warnings on iOS 16+ / macOS 13+
2. Triple-buffered semaphore never deadlocks (10-minute soak test)
3. LOD0: 44 triangles per prism (verified by vertex count)
4. LOD3: 2 triangles per prism (flat, no extrusion)
5. Frame time < 8ms at LOD0 with 3000 triangles on A15 (iPhone 13)
6. Bevel normals produce visible edge highlight under directional light
7. Border width varies visually between S0 (thick) and S4 (thin)

### Phase 3: Lighting + Animation (Weeks 8-11)

**Files:**
- `App/ScanGuidance/EnvironmentLightEstimator.swift`
- `Core/Quality/Animation/FlipAnimationController.swift`
- `Core/Quality/Animation/RipplePropagationEngine.swift`
- `Core/Quality/Geometry/MeshAdjacencyGraph.swift`
- `App/ScanGuidance/Shaders/ScanGuidance.metal` (add metallic lighting pass)

**Acceptance Criteria:**
1. Tier fallback: ARKit unavailable → vision → fallback (verified by unit test)
2. SH coefficients: exactly 9 × RGB (27 floats) passed to shader
3. Fallback light direction matches EnvironmentLightEstimator.fallbackDirection
4. Flip animation duration = 0.5s ± 0.01s (measured)
5. Flip easing overshoots to ~1.1 at t≈0.6 (curve test)
6. BFS distances correct for known graph topologies (chain, ring, grid)
7. Ripple amplitude at hop 8 = 1.0 × 0.85^8 ≈ 0.272 ± 0.01
8. Cook-Torrance BRDF produces visible specular highlight on S3+ triangles

### Phase 4: Haptics + Toast + Controls (Weeks 12-14)

**Files:**
- `App/ScanGuidance/GuidanceHapticEngine.swift`
- `App/ScanGuidance/GuidanceToastPresenter.swift`
- `App/ScanGuidance/ScanCaptureControls.swift`
- `App/ScanGuidance/GuidanceHints.swift`
- `App/ScanGuidance/ScanCompletionBridge.swift`

**Acceptance Criteria:**
1. Debounce: same pattern within 5s → suppressed (unit test)
2. Rate limit: 5th haptic within 60s → suppressed (unit test)
3. Toast contrast ratio >= 17.4:1 (white on 85% black)
4. Toast duration: 2s normal, 5s with VoiceOver active
5. Stop button triggers `.scanComplete` haptic via NotificationCenter bridge
6. Toast messages use polite "请您..." form
7. ScanCaptureControls: white-border black-fill circle visible on all backgrounds

### Phase 5: Thermal Safety + Performance (Weeks 15-16)

**Files:**
- `Core/Quality/Performance/ThermalQualityAdapter.swift`
- Integration with ScanGuidanceRenderPipeline

**Acceptance Criteria:**
1. On iOS/macOS: ProcessInfo.ThermalState.critical → LOD3, 500 max triangles, 24fps
2. On Linux: `updateThermalState` not available; frame-budget-only tier adaptation works
3. Hysteresis: tier change within 10s of previous → blocked
4. Frame budget: P95 > 1.2× target for 30 frames → step up tier
5. LOD transitions are visually smooth (no pop-in)
6. At critical tier: no flip, no ripple, no BRDF (only flat grayscale)
7. 5-minute soak test at .serious thermal state: no crashes, steady 30fps

### Phase 6: Cross-Platform Ports + Polish (Weeks 17-18)

**Files:**
- `Core/Quality/Platform/RenderingPlatformProtocol.swift`
- All test files (10)
- Final integration test suite

**Acceptance Criteria:**
1. Protocol compiles on both macOS and Linux (SwiftPM)
2. All 10 test files pass on macOS
3. Linux: Core/ tests compile and pass (skip Metal/CoreHaptics tests)
4. No force-unwraps in production code
5. No retain cycles (verified by Instruments Leaks)
6. Reduce Motion: flip and ripple disabled when system setting is on
7. Full CI pipeline green (macOS + Linux)
8. `pr1_audit.sh` and `ban_apple_only_imports.sh` both pass

---

## Part F: Invariant Assertions (13)

| # | Assertion | Test Method |
|---|-----------|-------------|
| INV-01 | display(for: patchId) never decreases across frames | MonotonicityStressTests |
| INV-02 | ColorState order: black < darkGray < lightGray < white < original; unknown=-1 | ScanGuidanceConstantsTests |
| INV-03 | S-thresholds strictly increasing: 0.10 < 0.25 < 0.50 < 0.75 < 0.88 | ScanGuidanceConstantsTests |
| INV-04 | hapticBlurThreshold == QualityThresholds.laplacianBlurThreshold | validateRelationships() |
| INV-05 | Border width in [1.0, 12.0] pixels for any input | AdaptiveBorderTests |
| INV-06 | Wedge thickness in [0.0005, 0.008] meters | WedgeGeometryTests |
| INV-07 | Flip angle in [0, PI] radians | FlipAnimationTests |
| INV-08 | Ripple amplitude in [0, 1] after clamping | RipplePropagationTests |
| INV-09 | BFS hop count <= maxHops (8) | RipplePropagationTests |
| INV-10 | Haptic events <= 4 per minute | GuidanceHapticTests |
| INV-11 | SH coefficient count == 9 | EnvironmentLightTests |
| INV-12 | RenderTier transitions respect 10s hysteresis | ThermalQualityTests |
| INV-13 | Triple buffer index cycles 0→1→2→0 | RenderPipelineTests |

---

## Part G: Novel Algorithms (4 Aether3D Originals)

### G.1 Thickness-as-Evidence Encoding

```
thickness(display, area) = baseThickness × (1 - display)^0.7 × sqrt(area / medianArea)
```

### G.2 Dual-Factor Adaptive Border with Perceptual Gamma

```
width = base × (0.6 × (1-display) + 0.4 × sqrt(area/median))^1.4
```

### G.3 BFS Ripple with Damped Wave Propagation

```
amplitude(triangle, t) = Sigma_waves [ damping^hop × wave(t - hop × delay) ]
```

### G.4 Bevel-Edge Fresnel Highlight on Flip

Emergent property: bevel edge normals sweep through Fresnel peak during flip animation.

---

## Appendix: GuidanceRenderer Integration Strategy (v7.0.3)

**v7.0.3 CRITICAL FINDING:** `#if canImport(Metal)` = TRUE on macOS SwiftPM (empirically verified). Therefore `canImport(Metal)` CANNOT distinguish SwiftPM vs Xcode builds. The v7.0.2 approach of guarding EvidenceRenderer/GuidanceHints with `canImport(Metal)` is **WRONG** and would cause compile errors.

**v7.0.3 Solution: GuidanceRenderer stays UNMODIFIED. Protocol injection pattern instead.**

```swift
// GuidanceRenderer.swift — NO CHANGES. Stays exactly as shipped in v2.3b.
// HeatCoolCoverageView(), DirectionalAffordanceView() remain EmptyView() placeholders.
// StaticOverlayView remains EmptyView() — HC-05.
```

**Why no modification is needed:**
1. No `.xcodeproj` exists — project builds entirely via SwiftPM
2. `App/` is not in any SwiftPM target — App/ files are uncompiled
3. `canImport(Metal)` = true on macOS SwiftPM — cannot be used as guard
4. GuidanceRenderer is in `Aether3DCore` module — cannot see App/ types

**Future integration (when Xcode project is created):**
The App-layer `EvidenceRenderer` and `GuidanceHints` views will be wired via the Xcode project's target membership, NOT via compile-time guards in Core/. The Xcode project will:
1. Create an App target that includes both Core/ and App/ source files
2. Or use a protocol-injection pattern where App/ registers view factories at launch time

This is a **deferred architecture decision** — PR7 delivers all the rendering algorithms (Core/) and the view implementations (App/) as separate, testable units. Wiring them together requires an Xcode project which is outside PR7's scope.

---

## Appendix: CI Script Gaps (v7.0.2 Advisory)

**Known gaps (not blocking build, but should be addressed in Phase 6):**

1. **`ban_apple_only_imports.sh`**: FORBIDDEN_IMPORTS list does NOT include Metal/MetalKit/ARKit/CoreHaptics. Currently only checks CryptoKit, UIKit, AppKit, WatchKit, TVUIKit. PR7 files in Core/ are safe (no such imports), but the CI guardrail is incomplete. **Recommend:** Add Metal/MetalKit/ARKit/CoreHaptics to FORBIDDEN_IMPORTS in Phase 6.

2. **`pr1_audit.sh`**: Only greps `Core/Models/`, `Core/SSOT/`, `Core/Constants/ObservationConstants.swift` — does NOT scan `Core/Quality/` or `Core/Constants/ScanGuidanceConstants.swift`. PR7 files are safe, but the audit scope is too narrow. **Recommend:** Expand grep scope to all of `Core/` in Phase 6.

These are documentation-only advisories. The actual code will pass CI because:
- `ban_apple_only_imports.sh` DOES scan all of `Core/` (via `find "$dir" -name "*.swift"`) for the imports it knows about (UIKit, AppKit, etc.)
- PR7 Core/ files only import Foundation + simd, which are both allowed
- The gap is that if someone accidentally adds `import Metal` to Core/, these scripts won't catch it — but PR7 won't make that mistake

---

## Appendix: v7.0.1 + v7.0.2 + v7.0.3 Changelog

All patches from v7.0.1, v7.0.2, and v7.0.3 have been **inlined** into the document above.

### v7.0.1 Changes (from v7.0):

| ID | Change | Severity |
|----|--------|----------|
| BUG-01 | Metal/ARKit files moved from `Core/Rendering/` to `App/ScanGuidance/`; pure algorithms to `Core/Quality/` | Critical |
| BUG-02 | Documented full `QualityFeedbackUpdate` struct (6 fields); renamed `QualityTier→RenderTier` | Critical |
| BUG-03 | Replaced `CACurrentMediaTime()` with `ProcessInfo.processInfo.systemUptime` in Core/ | Critical |
| MED-01 | Branch corrected to `pr7/scan-guidance-ui` | Medium |
| MED-02 | `#else` (Linux) branch documented as staying `fatalError` | Medium |
| MED-03 | Package.swift `ScanGuidanceTests` target added | Medium |
| MED-04 | HC-10 added: Toast is secondary feedback | Medium |
| MED-05 | Added `GrayscaleMapper.swift` for continuous display→RGB (bypasses S1=S2 issue) | Medium |
| MED-06 | HC-11 added: Swift 5.9 syntax constraint | Medium |
| MIN-01 | `QualityTier` renamed to `RenderTier` | Minor |
| MIN-02 | `PerTriangleData.grayscaleColor` changed to `float3` (was `uint8_t×3`) | Minor |
| MIN-03 | Phase 1 acceptance criteria includes Linux build | Minor |
| MIN-04 | `flipRotationMatrix` now does full translate-rotate-untranslate | Minor |
| MIN-05 | `ScanCompletionBridge.swift` added for NotificationCenter bridging | Minor |
| NEW | HC-12 added: Core/ must not import Metal/ARKit/CoreHaptics | Critical |
| NEW | `GrayscaleMapper.swift` (file #19) and `ScanCompletionBridge.swift` (file #18) added | Medium |

### v7.0.2 Changes (from v7.0.1):

| ID | Change | Severity |
|----|--------|----------|
| CRIT-1 | Package.swift: `"ScanGuidanceTests"` MUST be added to `Aether3DCoreTests.exclude` to avoid overlapping sources error | Critical |
| CRIT-2 | GuidanceRenderer.swift: Use `#if canImport(Metal)` guard for EvidenceRenderer/GuidanceHints; SwiftPM keeps placeholders | Critical |
| CRIT-3 | ThermalQualityAdapter: `updateThermalState()` wrapped in `#if os(iOS) \|\| os(macOS)` — ProcessInfo.ThermalState is Darwin-only | Critical |
| MED-1 | HC-01 corrected: actual ColorState cases are black/darkGray/lightGray/white/original/unknown (6 cases, not 5) | Medium |
| MED-2 | HC-09 updated: Bool constants excluded from `allSpecs` (no BoolConstantSpec in AnyConstantSpec); 63 specs not 65 | Medium |
| MED-3 | `snapshotSorted()` returns `[DisplayEntry]` not `[String: Double]` — conversion documented in A.2 and C.2 | Medium |
| MED-4 | HC-13 added: ProcessInfo.ThermalState Darwin-only constraint | Medium |
| MED-5 | Phase 5 acceptance criteria updated for Linux (no updateThermalState) | Medium |
| MIN-1 | INV-02 updated: ColorState includes `.unknown` (order = -1) | Minor |
| MIN-2 | CI script gaps documented as advisory (not blocking) | Minor |
| MIN-3 | simd on Linux clarified: SIMD3 is stdlib, matches DuplicateDetector.swift pattern | Minor |

### v7.0.3 Changes (from v7.0.2):

| ID | Change | Severity |
|----|--------|----------|
| BLOCK-1 | `#if canImport(Metal)` = TRUE on macOS SwiftPM (empirically verified). GuidanceRenderer.swift stays UNMODIFIED — no `canImport(Metal)` guard. Protocol injection pattern for future Xcode integration. | Blocker→Fixed |
| BLOCK-2 | No `.xcodeproj` exists. `App/` is NOT in any SwiftPM target. App/ files are uncompiled placeholders for future Xcode project. Plan updated to reflect this reality. | Blocker→Fixed |
| BLOCK-3 | 3 App-layer test files (EnvironmentLightTests, GuidanceHapticTests, RenderPipelineTests) reference App/ types unavailable in SwiftPM. Test bodies wrapped in `#if canImport(CoreHaptics)/#if canImport(Metal)` guards — compile as empty stubs in SwiftPM. | Blocker→Fixed |
| WARN-1 | `SSOTRegistry.swift` must add `ScanGuidanceConstants.allSpecs` and `validateRelationships()`. Added to B.2 Modified Files. | Warning→Fixed |
| WARN-2 | `borderColorR: UInt8` changed to `Int` for `SystemConstantSpec` registration. allSpecs count stays 63 (65 - 2 Bool). | Warning→Fixed |

---

**End of PR#7 Engineering Blueprint v7.0.3**
