# Capture Pipeline — Architecture + Extension Guide

**Status (as of 2026-04-23 feat/firebase-auth branch):** partially migrated. Infrastructure is live and `QualityAnalysisObserver` is actually driving dome sharpness gating. `VideoWriterObserver` and `ObjectModeV2DomeUpdateObserver` are implemented but dormant (the pre-refactor `ObjectModeV2ARCaptureCoordinator` writer and `ObjectModeV2ARDomeCoordinator.coverage.ingest` paths still handle those responsibilities). See "Next Steps" below for the plan to retire them.

---

## The Flow Today

```
ARSession (ARKit)
  │
  │  30 Hz ARFrame
  ▼
ObjectModeV2ARDomeCoordinator
  │   (ARSessionDelegate, @MainActor)
  │
  ├─► Old Path (still active, legacy):
  │     ├─ onARFrame? closure → ObjectModeV2ARCaptureCoordinator.handle
  │     │   └─ AVAssetWriter appends every frame
  │     └─ Task{@MainActor} handleFrame() async
  │         ├─ updates snapshot.currentAzimuth/Elevation/trackingOK
  │         └─ @ 6Hz, coverage.ingest(CapturedFrameSample(...))
  │             with sharpness read from ↓
  │
  └─► New Path (live, feeding sharpness):
        CaptureSession (actor)
          └─► QualityAnalysisObserver (10 Hz, analysisQueue)
                └─ FrameAnalyzer.analyze(pixelBuffer) → FrameQualityReport
                    └─ session.snapshot.lastQualityReport = report
                    
        domeCoordinator.handleFrame() reads the latest report before
        ingest() → real Laplacian variance replaces hardcoded 1000.
```

## Components

### `Core/Capture/` (target: Aether3DCore)

| File | Role |
|------|------|
| `CaptureFrame.swift` | Immutable per-frame snapshot (pose, intrinsics, trackingOK, pixelBuffer). Does NOT retain ARFrame. |
| `FrameQualityReport.swift` | Output of the analyzer — Laplacian variance, brightness, contrast. Contains `FrameQualityGate` with adaptive dark-scene threshold. |
| `CaptureFrameObserver.swift` | Protocol every downstream consumer implements. Requires `observerID`, `preferredInterval`, `receive(_:session:) async`. |
| `CaptureSessionSnapshot.swift` | Single source of truth for UI state — pose, coverage counts, quality report, recording status, hint text. |
| `CaptureSession.swift` | Actor. Owns observer registry (weak), does per-observer rate gating, serializes broadcast. |
| `ARSessionBridge.swift` | Nonisolated ARSessionDelegate glue. Copies pose+buffer out of ARFrame, dispatches into the actor. Currently unused by ObjectModeV2 because `ObjectModeV2ARDomeCoordinator` already is the ARSessionDelegate and pushes frames directly. Kept because any future capture path that does NOT have its own coordinator (e.g. a headless recording session for tests) can use the bridge as-is. |
| `FrameAnalyzer.swift` | Pure Swift. Laplacian variance on a 128×128 grayscale downsample of the Y plane. ~0.6–1 ms per call on A17. Reuses the algorithm that used to only live in Simulator's `ObjectModeV2CaptureRecorder.makeVisualFrameSample`. |
| `VideoWriterObserver.swift` | AVAssetWriter wrapped as an observer. Owns `writerQueue`. `startRecording()` / `stopRecording()` called externally. Not wired to ViewModel yet. |
| `QualityAnalysisObserver.swift` | Runs `FrameAnalyzer` @ 10 Hz on its own `analysisQueue`, publishes reports into `session.snapshot`. **Wired and active.** |

### `App/ObjectModeV2/`

| File | Role |
|------|------|
| `ObjectModeV2DomeUpdateObserver.swift` | Reads `session.snapshot.lastQualityReport` + camera pose; calls `DomeCoverageMap.ingest`; publishes coverage results back to snapshot. Not wired yet. |
| `ObjectModeV2ARDomeCoordinator.swift` | Still owns ARSession. Adds `captureSession` injection point so ARFrame push happens at `session(_:didUpdate:)`. `handleFrame()` reads `captureSession?.snapshot.lastQualityReport` for real sharpness instead of hardcode 1000. |
| `ObjectModeV2CaptureViewModel.swift` | Creates `captureSession`, registers `qualityObserver`, wires `domeCoordinator.captureSession = captureSession`. |
| `ObjectModeV2ARCaptureCoordinator.swift` | Still handles AVAssetWriter. To retire: remove its `handle(_:)` writer code, `register(VideoWriterObserver)` in the ViewModel, and in its place expose a thin wrapper that forwards `startRecording/stopRecording` to the observer. |
| `ObjectModeV2CaptureRecorder.swift` | Only used in Simulator (`#else` branch of the `#if canImport(ARKit)` guard in ViewModel). Contains the original `makeVisualFrameSample` algorithm that FrameAnalyzer now also uses — candidate for deletion once the Simulator path also adopts CaptureSession. |

---

## Adding a New Observer (the whole point)

Want a real-time renderer UI that shows the reconstructed mesh preview during capture? Or an audio-level meter that reacts to camera-facing sound? Both are one file:

```swift
// Core/Capture/MyRealtimeRendererObserver.swift
import Foundation

final class MyRealtimeRendererObserver: CaptureFrameObserver, @unchecked Sendable {
    let observerID = "RealtimeRenderer"
    let preferredInterval: TimeInterval = 1.0 / 20.0  // 20 Hz

    func receive(_ frame: CaptureFrame, session: CaptureSession) async {
        // 1) Hop off the actor fast — DO NOT block here.
        guard let pixelBuffer = frame.pixelBuffer else { return }
        let pose = frame.cameraTransform
        Task(priority: .userInitiated) { [pose, pixelBuffer] in
            // 2) Do your GPU/CPU work on your own queue/actor.
            await myRenderer.ingest(pose: pose, image: pixelBuffer)
        }
    }
}
```

Register it in `ObjectModeV2CaptureViewModel.init()`:

```swift
private let myRenderer = MyRealtimeRendererObserver()
...
Task { [captureSession, myRenderer] in
    await captureSession.register(myRenderer)
}
```

Done. No changes to ARDomeCoordinator, ARCaptureCoordinator, coverage map, or any existing file. The observer receives CaptureFrames at 20 Hz and your renderer decides what to do with them.

---

## Concurrency Model — Cheat Sheet

| Layer | Thread/Queue | Rule |
|------|--------------|------|
| ARSessionDelegate (`session(_:didUpdate:)`) | ARKit private delegate queue (nonisolated) | Copy out of ARFrame fast, then release. Never retain ARFrame across a suspension point. |
| `CaptureSession` | Own actor | All state access serialized. Observers are called FROM the actor — each observer is responsible for hopping off if work is heavy. |
| `VideoWriterObserver` | `writerQueue` (serial, `.userInitiated`) | All AVAssetWriter state guarded by the queue. `nonisolated(unsafe)` on mutable writer fields because the queue is the serialization point. |
| `QualityAnalysisObserver` | `analysisQueue` (serial, `.userInitiated`) | Drops incoming frames if an analysis is already in flight — prevents pile-up during thermal throttling. |
| `ObjectModeV2DomeUpdateObserver` | Runs on actor, fast work only | Reads `session.snapshot.lastQualityReport`, writes back coverage counts via `session.mutateSnapshot`. No heavy compute. |
| SwiftUI | Main actor | Reads published values derived from `captureSession.snapshot`. |

---

## Next Steps (not done in this branch, queued for follow-up commits)

1. **Wire `VideoWriterObserver`** — delete writer code in `ObjectModeV2ARCaptureCoordinator.handle()`, register the observer in VM.
2. **Wire `ObjectModeV2DomeUpdateObserver`** — remove `coverage.ingest` from `ObjectModeV2ARDomeCoordinator.handleFrame()`, let the observer own coverage state.
3. **Delete legacy Simulator path** — once VideoWriterObserver is live, `ObjectModeV2CaptureRecorder.swift` is pure duplicated code and can be removed.
4. **Delete `GuidanceEngine` from AR path** — the VM's init still wires `recorder.onVisualFrameSample = { ... guidanceEngine.processVisualSample(...) }`, but on AR that callback never fires. Safe to delete the wiring once the Simulator path is retired.
5. **Tune `DomeCoverageMap.thresholds.minSharpness`** — today defaults to 500 (a value picked for hardcode-1000). With real Laplacian variance, monitor on-device what values typical accepted frames produce, and adjust (400 is the recommended starting point in `FrameQualityGate`, which is not currently applied — see `FrameQualityReport.swift`).
6. **Publish `CaptureSessionSnapshot` to SwiftUI** — today the VM keeps its own `@Published acceptedFrames` etc. Once DomeUpdateObserver is live, forward snapshot fields through Combine.

Each of 1–4 is a focused ~50–150 line diff. Do them as separate commits, build-verify between each.

---

## Debug Tips

- **Dome stops turning green with real quality on** — verify `captureSession.snapshot.lastQualityReport?.laplacianVariance` is actually populating. Spark-plan iPhone recording a dim scene easily drops variance below 500; lower `DomeCoverageMap.thresholds.minSharpness` to 300 for testing.
- **Dome works but writer silently stops** — check `VideoWriterObserver.isActive` and `currentRecordingDuration`. The observer drops frames during `sessionWillStop` mid-capture; look at `sessionWillStop` invocations in logs.
- **CPU spikes during capture** — `QualityAnalysisObserver` has an `analysisInFlight` drop-if-busy guard, but if multiple observers end up fighting for the analysis queue, check their `preferredInterval`.
- **"未来的实时渲染 UI 卡" on old devices** — dial the new observer's `preferredInterval` up. The pipeline respects per-observer throttling, so you can have dome @6Hz while the renderer is @15Hz.
