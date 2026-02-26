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
    private struct StablePatchAnchorRecord: Sendable {
        var sample: PatchIdentitySample
        var patchId: String
        var lastSeenFrame: Int
    }

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
    private var stablePatchAnchors: [UInt64: StablePatchAnchorRecord] = [:]
    private var patchKeyToPatchId: [UInt64: String] = [:]
    private var patchIdAliases: [String: String] = [:]
    private var patchAliasLastSeenFrame: [String: Int] = [:]
    private var poseStabilizer: OpaquePointer?
    private var lastPoseQuality: Float = 0.0

    private static let identityLockDisplayThreshold: Float = 0.18
    private static let identitySnapDistanceM: Float = 0.12
    private static let identityDisplayDeltaThreshold: Float = 0.01
    private static let identityAnchorRetentionFrames: Int = 60 * 45
    private static let identityAliasRetentionFrames: Int = 60 * 60
    private static let identityAnchorMaxCount: Int = 4096
    private static let identityAliasMaxCount: Int = 50_000
    private static let posePredictionLeadNs: UInt64 = 12_000_000
    private static let poseMinimumAcceptedQuality: Float = 0.35

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
        poseStabilizer = NativePoseStabilizerBridge.create()
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
        timestamp: TimeInterval,
        cameraTransform: simd_float4x4,
        lightEstimate: LightEstimateSnapshot?,
        meshAnchors: [ARMeshAnchor],
        viewMatrix: simd_float4x4? = nil,
        projectionMatrix: simd_float4x4? = nil
    ) {
        guard scanState.isActive else { return }
        let stabilizedCameraTransform = stabilizedCameraTransform(
            rawCameraTransform: cameraTransform,
            timestamp: timestamp
        )

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
        // Backend review target (distance/exposure/motion) drives display/style progression.
        let velocity = extractMotionMagnitude(from: stabilizedCameraTransform, timestamp: timestamp)
        previousPatchDisplaySnapshot = currentPatchDisplaySnapshot
        updatePatchDisplayMap(
            cameraTransform: stabilizedCameraTransform,
            lightEstimate: lightEstimate,
            motionSpeed: velocity
        )
        currentPatchDisplaySnapshot = makeDisplaySnapshot()

        // Step 3: Thermal-aware quality control
        let tier = thermalAdapter.currentTier
        let maxTriangles = tier.maxTriangles
        let analysisTriangles = Array(meshTriangles.prefix(maxTriangles))
        let renderTriangles = selectStableRenderTriangles(
            meshTriangles,
            maxTriangles: maxTriangles,
            cameraTransform: stabilizedCameraTransform
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
        let feedbackTimestamp = ProcessInfo.processInfo.systemUptime

        // Motion too fast check
        let motionThresholdScale: Double = tier == .critical ? 1.5 : 1.0
        if tier.enableHaptics && velocity > ScanGuidanceConstants.hapticMotionThreshold * motionThresholdScale {
            _ = hapticEngine.fire(
                pattern: .motionTooFast,
                timestamp: feedbackTimestamp,
                toastPresenter: toastPresenter
            )
        }

        // Exposure check
        if let lightEstimate {
            let ambientIntensity = lightEstimate.ambientIntensity
            // Normal range: 250-2000 lux
            if tier.enableHaptics && (ambientIntensity < 250.0 || ambientIntensity > 5000.0) {
                _ = hapticEngine.fire(
                    pattern: .exposureAbnormal,
                    timestamp: feedbackTimestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        // Step 7: Update render pipeline (if Metal is available)
        let resolvedViewMatrix: simd_float4x4
        if lastPoseQuality >= Self.poseMinimumAcceptedQuality {
            resolvedViewMatrix = simd_inverse(stabilizedCameraTransform)
        } else {
            resolvedViewMatrix = viewMatrix ?? simd_inverse(cameraTransform)
        }
        renderPipeline?.update(
            displaySnapshot: currentPatchDisplaySnapshot,
            colorStates: [:],
            meshTriangles: renderTriangles,
            lightEstimate: lightEstimate,
            cameraTransform: stabilizedCameraTransform,
            viewMatrix: resolvedViewMatrix,
            projectionMatrix: projectionMatrix,
            frameDeltaTime: 1.0 / 60.0,
            gpuDurationMs: nil
        )
    }

    // MARK: - Private Helpers

    /// Stabilizes patch identities using core matcher so covered regions don't remap backwards.
    private func stabilizePatchIdentities(_ triangles: [ScanTriangle]) -> [ScanTriangle] {
        let currentFrame = frameCounter
        guard !triangles.isEmpty else {
            pruneStablePatchState(currentFrame: currentFrame)
            return []
        }

        var observations: [PatchIdentitySample] = []
        var canonicalInputPatchIds: [String] = []
        observations.reserveCapacity(triangles.count)
        canonicalInputPatchIds.reserveCapacity(triangles.count)

        for triangle in triangles {
            let canonicalPatchId = resolveAlias(for: triangle.patchId, currentFrame: currentFrame)
            canonicalInputPatchIds.append(canonicalPatchId)

            let patchKey = stablePatchKey(canonicalPatchId)
            patchKeyToPatchId[patchKey] = canonicalPatchId
            let display = Float(
                currentPatchDisplaySnapshot[canonicalPatchId]
                    ?? patchDisplayMap.display(for: canonicalPatchId)
            )
            observations.append(
                PatchIdentitySample(
                    patchKey: patchKey,
                    centroid: triangleCentroid(triangle),
                    display: min(max(display, 0.0), 1.0)
                )
            )
        }

        let anchors = preferredAnchorSamplesForMatching(currentFrame: currentFrame)
        let resolvedKeys = renderStabilityBridge.matchPatchIdentities(
            observations: observations,
            anchors: anchors,
            lockDisplayThreshold: Self.identityLockDisplayThreshold,
            snapDistanceM: Self.identitySnapDistanceM,
            cellSizeM: Self.identityDisplayDeltaThreshold
        ) ?? observations.map(\.patchKey)

        var stabilized: [ScanTriangle] = []
        stabilized.reserveCapacity(triangles.count)

        for index in triangles.indices {
            let resolvedKey = index < resolvedKeys.count ? resolvedKeys[index] : observations[index].patchKey
            let incomingPatchId = canonicalInputPatchIds[index]
            let resolvedPatchId =
                patchKeyToPatchId[resolvedKey]
                ?? stablePatchAnchors[resolvedKey]?.patchId
                ?? incomingPatchId

            patchKeyToPatchId[resolvedKey] = resolvedPatchId
            patchKeyToPatchId[observations[index].patchKey] = resolvedPatchId

            patchIdAliases[triangles[index].patchId] = resolvedPatchId
            patchAliasLastSeenFrame[triangles[index].patchId] = currentFrame
            if incomingPatchId != triangles[index].patchId {
                patchIdAliases[incomingPatchId] = resolvedPatchId
                patchAliasLastSeenFrame[incomingPatchId] = currentFrame
            }

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
            let clampedDisplay = min(max(display, 0.0), 1.0)
            if clampedDisplay >= Self.identityLockDisplayThreshold || stablePatchAnchors[resolvedKey] != nil {
                let candidateSample = PatchIdentitySample(
                    patchKey: resolvedKey,
                    centroid: observations[index].centroid,
                    display: clampedDisplay
                )
                let blended = blendedAnchorSample(
                    previous: stablePatchAnchors[resolvedKey]?.sample,
                    fallback: candidateSample
                )
                stablePatchAnchors[resolvedKey] = StablePatchAnchorRecord(
                    sample: blended,
                    patchId: resolvedPatchId,
                    lastSeenFrame: currentFrame
                )
            }
        }

        pruneStablePatchState(currentFrame: currentFrame)
        return stabilized
    }

    private func resolveAlias(for patchId: String, currentFrame: Int) -> String {
        guard let canonical = patchIdAliases[patchId] else {
            return patchId
        }
        patchAliasLastSeenFrame[patchId] = currentFrame
        return canonical
    }

    private func preferredAnchorSamplesForMatching(currentFrame: Int) -> [PatchIdentitySample] {
        let freshnessFloor = currentFrame - Self.identityAnchorRetentionFrames
        let eligible = stablePatchAnchors.values.filter { $0.lastSeenFrame >= freshnessFloor }
        if eligible.isEmpty {
            return []
        }

        let ranked = eligible.sorted { lhs, rhs in
            if lhs.sample.display != rhs.sample.display {
                return lhs.sample.display > rhs.sample.display
            }
            return lhs.lastSeenFrame > rhs.lastSeenFrame
        }
        let capped = ranked.count > Self.identityAnchorMaxCount
            ? Array(ranked.prefix(Self.identityAnchorMaxCount))
            : ranked
        return capped.map(\.sample)
    }

    private func blendedAnchorSample(
        previous: PatchIdentitySample?,
        fallback: PatchIdentitySample
    ) -> PatchIdentitySample {
        guard let previous else {
            return fallback
        }

        let blend: Float = 0.35
        let blendedCentroid = previous.centroid * (1.0 - blend) + fallback.centroid * blend
        let blendedDisplay = max(previous.display * 0.95, fallback.display)
        return PatchIdentitySample(
            patchKey: fallback.patchKey,
            centroid: blendedCentroid,
            display: min(max(blendedDisplay, 0.0), 1.0)
        )
    }

    private func pruneStablePatchState(currentFrame: Int) {
        let anchorFloor = currentFrame - Self.identityAnchorRetentionFrames
        stablePatchAnchors = stablePatchAnchors.filter { $0.value.lastSeenFrame >= anchorFloor }

        if stablePatchAnchors.count > Self.identityAnchorMaxCount {
            let ranked = stablePatchAnchors.values.sorted { lhs, rhs in
                if lhs.sample.display != rhs.sample.display {
                    return lhs.sample.display > rhs.sample.display
                }
                return lhs.lastSeenFrame > rhs.lastSeenFrame
            }
            let keepKeys = Set(ranked.prefix(Self.identityAnchorMaxCount).map { $0.sample.patchKey })
            stablePatchAnchors = stablePatchAnchors.filter { keepKeys.contains($0.key) }
            patchKeyToPatchId = patchKeyToPatchId.filter { keepKeys.contains($0.key) }
        }

        let aliasFloor = currentFrame - Self.identityAliasRetentionFrames
        for (alias, lastSeen) in patchAliasLastSeenFrame where lastSeen < aliasFloor {
            patchAliasLastSeenFrame.removeValue(forKey: alias)
            patchIdAliases.removeValue(forKey: alias)
        }

        if patchIdAliases.count > Self.identityAliasMaxCount {
            let rankedAliases = patchAliasLastSeenFrame.sorted { $0.value > $1.value }
            let keepAliases = Set(rankedAliases.prefix(Self.identityAliasMaxCount).map(\.key))
            patchAliasLastSeenFrame = patchAliasLastSeenFrame.filter { keepAliases.contains($0.key) }
            patchIdAliases = patchIdAliases.filter { keepAliases.contains($0.key) }
        }
    }

    /// Update display values for visible patches through backend review target.
    private func updatePatchDisplayMap(
        cameraTransform: simd_float4x4,
        lightEstimate: LightEstimateSnapshot?,
        motionSpeed: Double
    ) {
        guard !meshTriangles.isEmpty else { return }

        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let medianAreaSqM = medianTriangleArea(meshTriangles)
        let ambientIntensity = lightEstimate.map { Double($0.ambientIntensity) }

        for triangle in meshTriangles {
            let current = patchDisplayMap.display(for: triangle.patchId)
            let target = backendReviewTargetDisplay(
                triangle: triangle,
                cameraPosition: cameraPosition,
                medianAreaSqM: medianAreaSqM,
                ambientIntensity: ambientIntensity,
                motionSpeed: motionSpeed
            )
            let isLocked = current >= ScanGuidanceConstants.s3ToS4Threshold
            _ = patchDisplayMap.updateWithBackendReview(
                patchId: triangle.patchId,
                reviewTarget: target,
                timestampMs: timestampMs,
                isLocked: isLocked
            )
        }
    }

    private func backendReviewTargetDisplay(
        triangle: ScanTriangle,
        cameraPosition: SIMD3<Float>,
        medianAreaSqM: Float,
        ambientIntensity: Double?,
        motionSpeed: Double
    ) -> Double {
        let centroid = triangleCentroid(triangle)
        let distance = Double(simd_length(centroid - cameraPosition))

        let distanceQuality: Double
        if distance < 0.18 {
            distanceQuality = clamp01(distance / 0.18)
        } else if distance <= 1.35 {
            distanceQuality = 1.0
        } else {
            distanceQuality = clamp01(1.0 - (distance - 1.35) / 1.45)
        }

        let normalizedArea = Double(
            sqrt(max(triangle.areaSqM, 1e-8) / max(medianAreaSqM, 1e-8))
        )
        let areaQuality = clamp01((normalizedArea - 0.35) / 0.85)

        let lightQuality: Double
        if let ambientIntensity {
            if ambientIntensity < 250.0 {
                lightQuality = clamp01(ambientIntensity / 250.0)
            } else if ambientIntensity <= 2200.0 {
                lightQuality = 1.0
            } else {
                lightQuality = clamp01(1.0 - (ambientIntensity - 2200.0) / 3800.0)
            }
        } else {
            lightQuality = 0.75
        }

        let motionBudget = max(ScanGuidanceConstants.hapticMotionThreshold, 0.1)
        let motionQuality = clamp01(1.0 - motionSpeed / (motionBudget * 2.0))

        // Review target blends geometry, distance, illumination, and motion stability.
        let reviewTarget =
            0.45 * distanceQuality
            + 0.20 * areaQuality
            + 0.20 * lightQuality
            + 0.15 * motionQuality
        return clamp01(reviewTarget)
    }

    private func medianTriangleArea(_ triangles: [ScanTriangle]) -> Float {
        guard !triangles.isEmpty else { return 1e-6 }
        let sorted = triangles.map { max($0.areaSqM, 1e-8) }.sorted()
        return max(sorted[sorted.count / 2], 1e-8)
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    /// Convert PatchDisplayMap entries to render/animation snapshot.
    private func makeDisplaySnapshot() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: patchDisplayMap.snapshotSorted().map { ($0.patchId, $0.display) })
    }

    private func stabilizedCameraTransform(
        rawCameraTransform: simd_float4x4,
        timestamp: TimeInterval
    ) -> simd_float4x4 {
        guard let stabilizer = poseStabilizer else {
            return rawCameraTransform
        }

        let rawPose = matrixToColumnMajorArray(rawCameraTransform)
        let timestampNs = UInt64(max(timestamp, 0.0) * 1_000_000_000.0)
        let imuZero: [Float] = [0.0, 0.0, 0.0]
        var stabilizedResult: ([Float], Float)?
        rawPose.withUnsafeBufferPointer { rawPtr in
            imuZero.withUnsafeBufferPointer { gyroPtr in
                imuZero.withUnsafeBufferPointer { accelPtr in
                    guard let rawBase = rawPtr.baseAddress,
                          let gyroBase = gyroPtr.baseAddress,
                          let accelBase = accelPtr.baseAddress else {
                        stabilizedResult = nil
                        return
                    }
                    stabilizedResult = NativePoseStabilizerBridge.update(
                        stabilizer,
                        rawPose: rawBase,
                        gyro: gyroBase,
                        accel: accelBase,
                        timestampNs: timestampNs
                    )
                }
            }
        }
        guard let (stabilizedPose, quality) = stabilizedResult else {
            return rawCameraTransform
        }

        lastPoseQuality = quality
        if quality < Self.poseMinimumAcceptedQuality {
            return rawCameraTransform
        }

        let predictTimestampNs = timestampNs > UInt64.max - Self.posePredictionLeadNs
            ? UInt64.max
            : timestampNs + Self.posePredictionLeadNs
        let predictedPose = NativePoseStabilizerBridge.predict(
            stabilizer,
            targetTimestampNs: predictTimestampNs
        ) ?? stabilizedPose

        return matrixFromColumnMajorArray(predictedPose)
            ?? matrixFromColumnMajorArray(stabilizedPose)
            ?? rawCameraTransform
    }

    private func matrixToColumnMajorArray(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    private func matrixFromColumnMajorArray(_ values: [Float]) -> simd_float4x4? {
        guard values.count >= 16 else {
            return nil
        }
        return simd_float4x4(columns: (
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        ))
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

        let currentFrame = Int32(clamping: frameCounter)
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let completionThreshold = Float(ScanGuidanceConstants.s3ToS4Threshold)

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
        let completedCount = candidates.reduce(into: 0) { partial, candidate in
            if candidate.display >= completionThreshold {
                partial += 1
            }
        }
        let selectionBudget = min(triangles.count, max(maxTriangles, completedCount))
        guard triangles.count > selectionBudget else {
            return triangles
        }

        guard let selectedIndices = renderStabilityBridge.selectStableRenderTriangles(
            candidates: candidates,
            config: RenderSelectionConfig(
                currentFrame: currentFrame,
                maxTriangles: Int32(clamping: selectionBudget),
                cameraPosition: cameraPosition,
                completionThreshold: completionThreshold,
                distanceBias: 0.03,
                displayWeight: 2.0,
                residencyBoost: 1.6,
                completionBoost: BridgeInteropConstants.renderSelectionCompletionBoost,
                stabilityWeight: 0.7
            )
        ), !selectedIndices.isEmpty else {
            return Array(triangles.prefix(selectionBudget))
        }

        var selected: [ScanTriangle] = []
        selected.reserveCapacity(min(selectionBudget, selectedIndices.count))
        for index in selectedIndices {
            guard index >= 0, index < triangles.count else { continue }
            let triangle = triangles[index]
            selected.append(triangle)
            if selected.count >= selectionBudget {
                break
            }
        }

        return selected.isEmpty ? Array(triangles.prefix(selectionBudget)) : selected
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
        stablePatchAnchors.removeAll()
        patchKeyToPatchId.removeAll()
        patchIdAliases.removeAll()
        patchAliasLastSeenFrame.removeAll()
        renderStabilityBridge.resetRenderSelectionRuntime()
        if let stabilizer = poseStabilizer {
            NativePoseStabilizerBridge.reset(stabilizer)
        }
        lastPoseQuality = 0.0
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
