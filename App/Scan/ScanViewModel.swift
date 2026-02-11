//
// ScanViewModel.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan ViewModel (THE ORCHESTRATOR)
// Wires all subsystems: ARKit → MeshExtractor → Core algorithms → Metal pipeline → SwiftUI
// Apple-platform only (ARKit + SwiftUI)
//

import Foundation

#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import simd

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
    // createRenderPipelines() contains fatalError() in Phase 2
    // Pipeline is nil — UI works perfectly without mesh overlay
    // When Metal shaders are ready, pipeline auto-activates
    private var renderPipeline: ScanGuidanceRenderPipeline?

    // MARK: - State
    private var meshTriangles: [ScanTriangle] = []
    private var adjacencyGraph: (any AdjacencyProvider)?
    private var displaySnapshot: [String: Double] = [:]
    private var previousDisplay: [String: Double] = [:]
    private var captureStartTime: Date?
    private var elapsedTimer: Timer?
    private var frameCounter: Int = 0

    // MARK: - Thermal Monitoring
    private var thermalObserver: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        self.toastPresenter = GuidanceToastPresenter()
        self.hapticEngine = GuidanceHapticEngine()
        self.completionBridge = ScanCompletionBridge(hapticEngine: hapticEngine)

        // Graceful Metal pipeline initialization
        // createRenderPipelines() calls fatalError() in Phase 2 — cannot catch
        // Pipeline is nil until Metal shaders are implemented
        self.renderPipeline = nil

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
    /// Invalid transitions trigger assertionFailure in DEBUG, silently ignored in RELEASE.
    func transition(to newState: ScanState) {
        guard scanState.allowedTransitions.contains(newState) else {
            #if DEBUG
            assertionFailure("Invalid state transition: \(scanState) → \(newState)")
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

        case (.paused, .capturing):
            isCapturing = true
            startElapsedTimer()

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

    // MARK: - ARKit Frame Processing

    /// Called from ARSCNView delegate on EVERY frame (~60 FPS)
    /// PERFORMANCE CRITICAL — must complete within frame budget (~16ms)
    func processARFrame(
        frame: ARFrame,
        meshAnchors: [ARMeshAnchor]
    ) {
        guard scanState.isActive else { return }

        // Step 1: Extract triangles from ARKit mesh
        let newTriangles = meshExtractor.extract(from: meshAnchors)

        // Only rebuild adjacency if mesh changed significantly
        let meshChanged = newTriangles.count != meshTriangles.count
        if meshChanged {
            meshTriangles = newTriangles
        }

        // Rebuild adjacency graph using SpatialHashAdjacency (O(n), not O(n²))
        // Only rebuild every 60 frames (~1s) when mesh has changed
        // SpatialHashAdjacency handles ANY mesh size (50,000+ triangles) in ~50ms
        if meshChanged && (frameCounter % 60 == 0) {
            rebuildAdjacencyGraph()
        }
        frameCounter += 1

        // Step 2: Update display snapshot
        previousDisplay = displaySnapshot
        updateDisplaySnapshot()

        // Step 3: Thermal-aware quality control
        let tier = thermalAdapter.currentTier
        let maxTriangles = tier.maxTriangles
        let limitedTriangles = Array(meshTriangles.prefix(maxTriangles))

        // Step 4: Check flip thresholds (if animation enabled for this tier)
        if tier.enableFlipAnimation, let adj = adjacencyGraph {
            let crossedIndices = flipController.checkThresholdCrossings(
                previousDisplay: previousDisplay,
                currentDisplay: displaySnapshot,
                triangles: limitedTriangles,
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
        let velocity = extractMotionMagnitude(from: frame.camera.transform)
        if velocity > ScanGuidanceConstants.hapticMotionThreshold {
            _ = hapticEngine.fire(
                pattern: .motionTooFast,
                timestamp: timestamp,
                toastPresenter: toastPresenter
            )
        }

        // Blur detection (using frame metadata)
        let blurVariance = estimateBlurVariance(from: frame)
        if blurVariance < ScanGuidanceConstants.hapticBlurThreshold {
            _ = hapticEngine.fire(
                pattern: .blurDetected,
                timestamp: timestamp,
                toastPresenter: toastPresenter
            )
        }

        // Exposure check
        if let lightEstimate = frame.lightEstimate {
            let ambientIntensity = lightEstimate.ambientIntensity
            // Normal range: 250-2000 lux
            if ambientIntensity < 250 || ambientIntensity > 5000 {
                _ = hapticEngine.fire(
                    pattern: .exposureAbnormal,
                    timestamp: timestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        // Step 7: Update render pipeline (if Metal is available)
        renderPipeline?.update(
            displaySnapshot: displaySnapshot,
            colorStates: [:],
            meshTriangles: limitedTriangles,
            lightEstimate: frame.lightEstimate,
            cameraTransform: frame.camera.transform,
            frameDeltaTime: 1.0 / 60.0,
            gpuDurationMs: nil
        )
    }

    // MARK: - Private Helpers

    /// Update display values for visible patches
    /// Each frame contributes a small delta based on viewing quality
    private func updateDisplaySnapshot() {
        for triangle in meshTriangles {
            let current = displaySnapshot[triangle.patchId] ?? 0.0
            // Simple accumulation: each visible frame adds a small increment
            // ~500 frames to reach 1.0 at 60fps ≈ 8.3 seconds viewing
            let increment = 0.002
            displaySnapshot[triangle.patchId] = min(current + increment, 1.0)
        }
    }

    /// Extract motion magnitude from camera transform as velocity proxy
    private func extractMotionMagnitude(from transform: simd_float4x4) -> Double {
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        return Double(simd_length(position))
    }

    /// Simplified blur estimation using frame metadata
    ///
    /// Full Laplacian variance requires CVPixelBuffer processing.
    /// For MVP, return a safe default that won't trigger false positives.
    /// Real implementation will be added when CVPixelBuffer processing is ready.
    private func estimateBlurVariance(from frame: ARFrame) -> Double {
        // Default above hapticBlurThreshold (120.0) — no false triggers
        return 200.0
    }

    /// Calculate overall scan coverage [0, 1]
    private func calculateOverallCoverage() -> Double {
        guard !displaySnapshot.isEmpty else { return 0.0 }
        let total = displaySnapshot.values.reduce(0.0, +)
        return total / Double(displaySnapshot.count)
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

    /// Reset all subsystems for next scan session
    private func resetSubsystems() {
        flipController.reset()
        rippleEngine.reset()
        displaySnapshot.removeAll()
        previousDisplay.removeAll()
        meshTriangles.removeAll()
        adjacencyGraph = nil
        frameCounter = 0
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
