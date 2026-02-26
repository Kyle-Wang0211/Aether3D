//
// ScanViewModel.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan ViewModel (THE ORCHESTRATOR)
// Wires all subsystems: ARKit → MeshExtractor → Core algorithms → Metal pipeline → SwiftUI
// Apple-platform only (ARKit + SwiftUI)
//

import Foundation
import Aether3DCore

#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import simd
#if canImport(Metal)
import Metal
#endif

/// THE ORCHESTRATOR — @MainActor ViewModel that wires ALL subsystems together
///
/// Architecture:
///   ARFrame (60fps) → MeshExtractor → [ScanTriangle]
///     → SpatialHashAdjacency (O(n), rebuilt every ~1s when mesh changes)
///     → FlipAnimationController (threshold crossing detection)
///     → RipplePropagationEngine (BFS wave propagation)
///     → GuidanceHapticEngine + GuidanceToastPresenter (multimodal feedback)
///     → ScanGuidanceRenderPipeline (Metal overlay, graceful nil if unavailable)
///     → @Published state → SwiftUI rerender
///
/// Pattern: @MainActor + ObservableObject + @Published + Task
/// (consistent with PipelineDemoViewModel)
@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published State (drives SwiftUI)
    @Published var scanState: ScanState = .initializing
    @Published var isCapturing: Bool = false
    @Published var elapsedTime: TimeInterval = 0

    // MARK: - Existing Components (REUSE, DO NOT RECREATE)
    let toastPresenter: GuidanceToastPresenter
    let hapticEngine: GuidanceHapticEngine
    private let completionBridge: ScanCompletionBridge

    // MARK: - Core Algorithm Subsystems (from Core/)
    private let wedgeGenerator = WedgeGeometryGenerator()
    private let flipController = FlipAnimationController()
    private let rippleEngine = RipplePropagationEngine()
    private let borderCalculator = AdaptiveBorderCalculator()
    private let thermalAdapter = ThermalQualityAdapter()

    // MARK: - App Platform Components
    private let grayscaleMapper = GrayscaleMapper()
    private let lightEstimator = EnvironmentLightEstimator()
    private let meshExtractor = MeshExtractor()

    // MARK: - Metal Pipeline (graceful degradation)
    // Pipeline is created from ScanGuidance.metal shaders.
    // If Metal device or shader compilation fails, pipeline is nil — UI still works.
    private var renderPipeline: ScanGuidanceRenderPipeline?

    // MARK: - State
    private var meshTriangles: [ScanTriangle] = []
    private var adjacencyGraph: (any AdjacencyProvider)?
    private var patchDisplayMap = PatchDisplayMap()
    private var currentPatchDisplaySnapshot: [String: Double] = [:]
    private var previousPatchDisplaySnapshot: [String: Double] = [:]
    private var captureStartTime: Date?
    nonisolated(unsafe) private var elapsedTimer: Timer?
    private var frameCounter: Int = 0
    private var lastMotionSample: (position: SIMD3<Float>, timestamp: TimeInterval)?
    private let renderStabilityBridge = NativeRenderStabilityBridge()
    private var stableAnchorSamples: [PatchIdentitySample] = []
    private var patchKeyToPatchId: [UInt64: String] = [:]

    private static let identityLockDisplayThreshold: Float = 0.18
    private static let identitySnapDistanceM: Float = 0.12
    private static let identityDisplayDeltaThreshold: Float = 0.01

    // MARK: - Thermal Monitoring
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        self.toastPresenter = GuidanceToastPresenter()
        self.hapticEngine = GuidanceHapticEngine()
        self.completionBridge = ScanCompletionBridge(hapticEngine: hapticEngine)

        // Graceful Metal pipeline initialization
        // ScanGuidance.metal contains wedgeFillVertex/Fragment + borderStrokeFragment
        // Pipeline init uses `throws` — safe to try? here
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            self.renderPipeline = try? ScanGuidanceRenderPipeline(device: device)
        } else {
            self.renderPipeline = nil
        }
        #else
        self.renderPipeline = nil
        #endif

        setupThermalMonitoring()
    }

    deinit {
        elapsedTimer?.invalidate()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - State Machine Transitions

    /// VALIDATED state transition — rejects invalid transitions
    ///
    /// Every state change goes through this single gateway.
    /// Invalid transitions are logged and ignored to keep runtime resilient.
    func transition(to newState: ScanState) {
        if scanState == newState {
            return
        }
        guard scanState.allowedTransitions.contains(newState) else {
            #if DEBUG
            print("[Aether3D] ⚠️ Rejected state transition: \(scanState) → \(newState) — not in allowed set")
            #endif
            return
        }

        let oldState = scanState
        scanState = newState

        // Side effects
        switch (oldState, newState) {
        case (_, .capturing):
            isCapturing = true
            captureStartTime = captureStartTime ?? Date()
            startElapsedTimer()

        case (.capturing, .paused):
            isCapturing = false
            stopElapsedTimer()

        case (_, .finishing):
            isCapturing = false
            stopElapsedTimer()
            NotificationCenter.default.post(name: .scanDidComplete, object: nil)

        case (_, .completed):
            isCapturing = false
            resetSubsystems()

        case (_, .failed):
            isCapturing = false
            stopElapsedTimer()
            resetSubsystems()

        default:
            break
        }
    }

    /// Executes core-owned action masks. Swift only performs imperative side effects.
    func executeScanActionPlan(_ plan: ScanActionPlan) {
        guard plan.actionMask.contains(.applyTransition),
              let targetState = plan.transitionTargetState else {
            return
        }
        transition(to: targetState)
    }

    // MARK: - User Actions

    func startCapture() {
        transition(to: .capturing)
    }

    func pauseCapture() {
        transition(to: .paused)
    }

    func resumeCapture() {
        transition(to: .capturing)
    }

    /// Stop capture and produce a ScanRecord
    ///
    /// - Returns: ScanRecord with coverage/triangle/duration metadata, or nil if invalid state
    func stopCapture() -> ScanRecord? {
        guard scanState.canFinish else { return nil }

        transition(to: .finishing)

        let record = ScanRecord(
            coveragePercentage: calculateOverallCoverage(),
            triangleCount: meshTriangles.count,
            durationSeconds: elapsedTime
        )

        transition(to: .completed)
        return record
    }

    /// Exposes the render pipeline handle for overlay draw delegation.
    func currentRenderPipelineForOverlay() -> ScanGuidanceRenderPipeline? {
        renderPipeline
    }

    // MARK: - ARKit Frame Processing

    /// Called from ARSCNView delegate on EVERY frame (~60 FPS)
    /// PERFORMANCE CRITICAL — must complete within frame budget (~16ms)
    func processARFrame(
        frame: ARFrame,
        meshAnchors: [ARMeshAnchor],
        viewMatrix: simd_float4x4? = nil,
        projectionMatrix: simd_float4x4? = nil
    ) {
        guard scanState.isActive else { return }

        // Step 1: Extract triangles from ARKit mesh
        let extractedTriangles = meshExtractor.extract(from: meshAnchors)
        let newTriangles = stabilizePatchIdentities(extractedTriangles)

        // Always update mesh triangles for accurate world-space tracking.
        // ARKit refines mesh geometry every frame even when triangle count stays the same.
        // Stale meshTriangles → triangles don't follow objects properly.
        let meshChanged = newTriangles.count != meshTriangles.count
        meshTriangles = newTriangles

        // Rebuild adjacency graph using SpatialHashAdjacency (O(n), not O(n²))
        // Only rebuild every 60 frames (~1s) when mesh topology has changed
        // SpatialHashAdjacency handles ANY mesh size (50,000+ triangles) in ~50ms
        if meshChanged && (frameCounter % 60 == 0) {
            rebuildAdjacencyGraph()
        }
        frameCounter += 1

        // Step 2: Update patch display map and snapshots
        previousPatchDisplaySnapshot = currentPatchDisplaySnapshot
        updatePatchDisplayMap()
        currentPatchDisplaySnapshot = makeDisplaySnapshot()

        // Step 3: Thermal-aware quality control
        let tier = thermalAdapter.currentTier
        let maxTriangles = tier.maxTriangles
        let analysisTriangles = Array(meshTriangles.prefix(maxTriangles))
        let renderTriangles = selectStableRenderTriangles(
            meshTriangles,
            maxTriangles: maxTriangles,
            cameraTransform: frame.camera.transform
        )

        // Step 4: Check flip thresholds (if animation enabled for this tier)
        if tier.enableFlipAnimation, let adj = adjacencyGraph {
            let crossedIndices = flipController.checkThresholdCrossings(
                previousDisplay: previousPatchDisplaySnapshot,
                currentDisplay: currentPatchDisplaySnapshot,
                triangles: analysisTriangles,
                adjacencyGraph: adj
            )

            // Step 5: Spawn ripples for crossed triangles (if enabled)
            if tier.enableRipple {
                let now = ProcessInfo.processInfo.systemUptime
                for triIndex in crossedIndices {
                    rippleEngine.spawn(
                        sourceTriangle: triIndex,
                        adjacencyGraph: adj,
                        timestamp: now
                    )
                }
            }
        }

        // Step 6: Haptic/Toast triggers (condition-based)
        let timestamp = ProcessInfo.processInfo.systemUptime

        // Motion too fast check
        let velocity = extractMotionMagnitude(from: frame.camera.transform, timestamp: frame.timestamp)
        let motionThresholdScale: Double = tier == .critical ? 1.5 : 1.0
        if tier.enableHaptics && velocity > ScanGuidanceConstants.hapticMotionThreshold * motionThresholdScale {
            _ = hapticEngine.fire(
                pattern: .motionTooFast,
                timestamp: timestamp,
                toastPresenter: toastPresenter
            )
        }

        // Exposure check
        if let lightEstimate = frame.lightEstimate {
            let ambientIntensity = lightEstimate.ambientIntensity
            // Normal range: 250-2000 lux
            if tier.enableHaptics && (ambientIntensity < 250 || ambientIntensity > 5000) {
                _ = hapticEngine.fire(
                    pattern: .exposureAbnormal,
                    timestamp: timestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        // Step 7: Update render pipeline (if Metal is available)
        renderPipeline?.update(
            displaySnapshot: currentPatchDisplaySnapshot,
            colorStates: [:],
            meshTriangles: renderTriangles,
            lightEstimate: frame.lightEstimate,
            cameraTransform: frame.camera.transform,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            frameDeltaTime: 1.0 / 60.0,
            gpuDurationMs: nil
        )
    }

    // MARK: - Private Helpers

    /// Stabilizes patch identities using core matcher so covered regions don't remap backwards.
    private func stabilizePatchIdentities(_ triangles: [ScanTriangle]) -> [ScanTriangle] {
        guard !triangles.isEmpty else {
            stableAnchorSamples.removeAll()
            return []
        }

        var observations: [PatchIdentitySample] = []
        observations.reserveCapacity(triangles.count)

        for triangle in triangles {
            let patchKey = stablePatchKey(triangle.patchId)
            patchKeyToPatchId[patchKey] = triangle.patchId
            let display = Float(
                currentPatchDisplaySnapshot[triangle.patchId]
                    ?? patchDisplayMap.display(for: triangle.patchId)
            )
            observations.append(
                PatchIdentitySample(
                    patchKey: patchKey,
                    centroid: triangleCentroid(triangle),
                    display: min(max(display, 0.0), 1.0)
                )
            )
        }

        let resolvedKeys = renderStabilityBridge.matchPatchIdentities(
            observations: observations,
            anchors: stableAnchorSamples,
            lockDisplayThreshold: Self.identityLockDisplayThreshold,
            snapDistanceM: Self.identitySnapDistanceM,
            cellSizeM: Self.identityDisplayDeltaThreshold
        ) ?? observations.map(\.patchKey)

        var stabilized: [ScanTriangle] = []
        stabilized.reserveCapacity(triangles.count)
        var nextAnchors: [PatchIdentitySample] = []
        nextAnchors.reserveCapacity(triangles.count)

        for index in triangles.indices {
            let resolvedKey = index < resolvedKeys.count ? resolvedKeys[index] : observations[index].patchKey
            let resolvedPatchId = patchKeyToPatchId[resolvedKey] ?? triangles[index].patchId
            patchKeyToPatchId[resolvedKey] = resolvedPatchId

            let triangle = triangles[index]
            stabilized.append(
                ScanTriangle(
                    patchId: resolvedPatchId,
                    vertices: triangle.vertices,
                    normal: triangle.normal,
                    areaSqM: triangle.areaSqM,
                    blockIndex: triangle.blockIndex
                )
            )

            let display = Float(
                currentPatchDisplaySnapshot[resolvedPatchId]
                    ?? patchDisplayMap.display(for: resolvedPatchId)
            )
            if display >= Self.identityLockDisplayThreshold {
                nextAnchors.append(
                    PatchIdentitySample(
                        patchKey: resolvedKey,
                        centroid: observations[index].centroid,
                        display: display
                    )
                )
            }
        }

        if nextAnchors.isEmpty {
            nextAnchors = observations.filter { $0.display >= Self.identityLockDisplayThreshold }
        }
        if nextAnchors.count > 10_000 {
            nextAnchors.sort { $0.display > $1.display }
            nextAnchors = Array(nextAnchors.prefix(10_000))
        }
        stableAnchorSamples = nextAnchors

        return stabilized
    }

    /// Update display values for visible patches through PatchDisplayMap.
    private func updatePatchDisplayMap() {
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        for triangle in meshTriangles {
            let current = patchDisplayMap.display(for: triangle.patchId)
            // Simple accumulation: each visible frame adds a small increment
            // ~100 frames to reach 1.0 at 60fps ≈ 1.7 seconds viewing
            let increment = ScanGuidanceConstants.scanDisplayIncrementPerFrame
            let target = min(current + increment, 1.0)
            _ = patchDisplayMap.update(
                patchId: triangle.patchId,
                target: target,
                timestampMs: timestampMs,
                isLocked: false
            )
        }
    }

    /// Convert PatchDisplayMap entries to render/animation snapshot.
    private func makeDisplaySnapshot() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: patchDisplayMap.snapshotSorted().map { ($0.patchId, $0.display) })
    }

    /// Extract frame-to-frame camera translation speed in m/s.
    private func extractMotionMagnitude(from transform: simd_float4x4, timestamp: TimeInterval) -> Double {
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        defer {
            lastMotionSample = (position: position, timestamp: timestamp)
        }

        guard let previous = lastMotionSample else {
            return 0
        }

        let dt = max(timestamp - previous.timestamp, 1.0 / 240.0)
        let delta = position - previous.position
        return Double(simd_length(delta) / Float(dt))
    }

    /// Calculate overall scan coverage [0, 1]
    private func calculateOverallCoverage() -> Double {
        guard !currentPatchDisplaySnapshot.isEmpty else { return 0.0 }
        let total = currentPatchDisplaySnapshot.values.reduce(0.0, +)
        return total / Double(currentPatchDisplaySnapshot.count)
    }

    /// Start elapsed time timer (0.1s resolution)
    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.captureStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    /// Stop elapsed time timer
    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Rebuild adjacency graph using SpatialHashAdjacency — O(n) for ANY mesh size
    ///
    /// Unlike MeshAdjacencyGraph (O(n²)), SpatialHashAdjacency uses spatial hashing
    /// to build adjacency in O(n) time. Safe for 50,000+ triangle meshes.
    /// 20,000 triangles → ~20ms (vs MeshAdjacencyGraph's ~3 seconds)
    private func rebuildAdjacencyGraph() {
        adjacencyGraph = SpatialHashAdjacency(triangles: meshTriangles)
    }

    private func selectStableRenderTriangles(
        _ triangles: [ScanTriangle],
        maxTriangles: Int,
        cameraTransform: simd_float4x4
    ) -> [ScanTriangle] {
        guard maxTriangles > 0 else { return [] }
        guard triangles.count > maxTriangles else { return triangles }

        let currentFrame = Int32(clamping: frameCounter)
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        let candidates: [RenderTriangleCandidate] = triangles.map { triangle in
            let patchKey = stablePatchKey(triangle.patchId)
            let display = Float(
                currentPatchDisplaySnapshot[triangle.patchId]
                    ?? patchDisplayMap.display(for: triangle.patchId)
            )
            return RenderTriangleCandidate(
                patchKey: patchKey,
                centroid: triangleCentroid(triangle),
                display: min(max(display, 0.0), 1.0),
                stabilityFadeAlpha: 0.0,
                residencyUntilFrame: 0
            )
        }

        guard let selectedIndices = renderStabilityBridge.selectStableRenderTriangles(
            candidates: candidates,
            config: RenderSelectionConfig(
                currentFrame: currentFrame,
                maxTriangles: Int32(clamping: maxTriangles),
                cameraPosition: cameraPosition,
                completionThreshold: Float(ScanGuidanceConstants.s3ToS4Threshold),
                distanceBias: 0.03,
                displayWeight: 2.0,
                residencyBoost: 1.6,
                completionBoost: BridgeInteropConstants.renderSelectionCompletionBoost,
                stabilityWeight: 0.7
            )
        ), !selectedIndices.isEmpty else {
            return Array(triangles.prefix(maxTriangles))
        }

        var selected: [ScanTriangle] = []
        selected.reserveCapacity(min(maxTriangles, selectedIndices.count))
        for index in selectedIndices {
            guard index >= 0, index < triangles.count else { continue }
            let triangle = triangles[index]
            selected.append(triangle)
            if selected.count >= maxTriangles {
                break
            }
        }

        return selected.isEmpty ? Array(triangles.prefix(maxTriangles)) : selected
    }

    private func stablePatchKey(_ patchId: String) -> UInt64 {
        let bytes = Array(patchId.utf8)
        var hash = BridgeInteropConstants.fnv1a64OffsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= BridgeInteropConstants.fnv1a64Prime
        }
        return hash
    }

    private func triangleCentroid(_ triangle: ScanTriangle) -> SIMD3<Float> {
        let (v0, v1, v2) = triangle.vertices
        return (v0 + v1 + v2) / 3.0
    }

    /// Reset all subsystems for next scan session
    private func resetSubsystems() {
        flipController.reset()
        rippleEngine.reset()
        patchDisplayMap.reset()
        wedgeGenerator.resetPersistentVisualState()
        currentPatchDisplaySnapshot.removeAll()
        previousPatchDisplaySnapshot.removeAll()
        meshTriangles.removeAll()
        stableAnchorSamples.removeAll()
        patchKeyToPatchId.removeAll()
        renderStabilityBridge.resetRenderSelectionRuntime()
        adjacencyGraph = nil
        frameCounter = 0
        lastMotionSample = nil
    }

    /// Setup thermal state monitoring (iOS only)
    private func setupThermalMonitoring() {
        #if os(iOS)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
        // Set initial thermal state
        thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
        #endif
    }
}

#endif
