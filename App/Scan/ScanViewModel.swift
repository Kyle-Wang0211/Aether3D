//
// ScanViewModel.swift
// Aether3D
//
// Scan ViewModel — THE ORCHESTRATOR
// Unified point cloud → 3DGS progressive pipeline.
// ARFrame → PipelineCoordinatorBridge (C++ 3-thread coordinator) → PointCloudOIRPipeline (Metal)
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
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// THE ORCHESTRATOR — @MainActor ViewModel
///
/// Architecture (unified point cloud → 3DGS):
///   ARFrame (60fps) → PipelineCoordinatorBridge.onFrame()
///     → C++ Thread A: depth→point cloud, frame selection
///     → C++ Thread B: evidence + quality (async)
///     → C++ Thread C: 3DGS training
///     → EvidenceSnapshot → Swift UI update
///     → PointCloudOIRPipeline (Metal overlay)
///
/// Compared to previous wedge-based orchestrator:
///   - Removed: MeshExtractor, WedgeGeometryGenerator, FlipAnimationController,
///              RipplePropagationEngine, SpatialHashAdjacency, PatchDisplayMap,
///              patch identity system, GrayscaleMapper, AdaptiveBorderCalculator
///   - Added:   PipelineCoordinatorBridge, PointCloudOIRPipeline
///   - Memory:  ~39MB (wedge) → ~10MB (point cloud + OIR)
@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published State (drives SwiftUI)
    @Published var scanState: ScanState = .initializing
    @Published var isCapturing: Bool = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var trainingActive: Bool = false
    @Published var trainingProgress: Float = 0.0
    @Published var coveragePercent: Float = 0.0
    @Published var isExporting: Bool = false
    @Published var coordinatorNotReady: Bool = false  // Set when stop attempted before coordinator loaded

    // MARK: - Existing Components (REUSE, DO NOT RECREATE)
    let toastPresenter: GuidanceToastPresenter
    let hapticEngine: GuidanceHapticEngine
    private let completionBridge: ScanCompletionBridge

    // MARK: - Thermal
    private let thermalAdapter = ThermalQualityAdapter()

    // MARK: - Pipeline (C++ coordinator + Metal renderer)
    private var coordinatorBridge: PipelineCoordinatorBridge?
    #if canImport(CAetherNativeBridge) && canImport(Metal)
    private var gpuDeviceHandle: OpaquePointer?      // aether_gpu_device_t* — must outlive coordinator
    private var splatEngineHandle: OpaquePointer?     // aether_splat_engine_t* — must outlive coordinator
    #endif
    #if canImport(Metal)
    private var renderPipeline: PointCloudOIRPipeline?
    #endif

    // DAv2 depth estimation now runs in C++ core layer (depth_inference_coreml.mm).
    // Swift no longer manages the DepthAnythingV2Bridge — C++ PipelineCoordinator
    // owns the DepthInferenceEngine and runs async inference on Neural Engine directly.

    // MARK: - Pixel Format Conversion (YCbCr → BGRA)
    // These are accessed exclusively from frameForwardQueue (serial), not MainActor.
    #if canImport(CoreImage) && canImport(CoreVideo)
    nonisolated(unsafe) private var pixelConvertContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated(unsafe) private var bgraBuffer: CVPixelBuffer?
    #endif

    // MARK: - Pose Stabilizer
    private var poseStabilizer: OpaquePointer?
    private var lastPoseQuality: Float = 0.0
    private static let posePredictionLeadNs: UInt64 = 12_000_000
    private static let poseMinimumAcceptedQuality: Float = 0.35

    // MARK: - Motion Tracking
    private var lastMotionSample: (position: SIMD3<Float>, timestamp: TimeInterval)?
    private var frameCounter: Int = 0
    private var isInitializingCoordinator: Bool = false

    // MARK: - Debug Overlay Stats (drives scan screen HUD)
    @Published var debugBridgeReady: Bool = false
    @Published var debugFrameCount: Int = 0
    @Published var debugPipelineFrameCount: Int = 0    // Frames forwarded to C++
    @Published var debugPointCloudCount: Int = 0
    @Published var debugOverlayCount: Int = 0
    @Published var debugSplatCount: Int = 0
    @Published var debugTrainingStep: Int = 0
    @Published var debugTotalSteps: Int = 0
    @Published var debugLoss: Float = 0.0
    @Published var debugCoordinatorInitTime: TimeInterval = 0  // Time since init started
    @Published var debugPointCloudAlpha: Float = -1.0  // Global PC alpha from C++ blend
    @Published var debugEncodeDrawCount: Int = 0       // encode() calls that drew something
    @Published var debugEncodeSkipCount: Int = 0       // encode() calls that had no data
    @Published var debugSelectedFrames: Int = 0        // Frames passing selection for training
    @Published var debugMinFramesNeeded: Int = 4       // min_frames_to_start_training from C++
    @Published var debugIsGPUTraining: Bool = false    // GPU vs CPU training path
    @Published var debugHasS6Quality: Bool = false     // S6+ quality reached (training gate open)

    // ── 区域化训练状态 (破镜重圆) ──
    @Published var debugRegionTotal: Int = 0           // Total training regions formed
    @Published var debugRegionCompleted: Int = 0       // Converged + revealed regions
    @Published var debugActiveRegionId: Int = -1       // Currently training region (-1 = none)
    @Published var debugActiveRegionProgress: Float = 0.0
    @Published var debugIsAnimating: Bool = false      // Any region doing fly-in animation
    @Published var debugStagedCount: Int = 0           // Regions waiting to fly in

    private var coordinatorInitStartTime: CFAbsoluteTime = 0

    // Quality milestone tracking removed — TSDF overlay heatmap replaces text toasts.

    // MARK: - Frame Forwarding Queue
    /// Serial queue for CIContext BGRA conversion + C++ frame submission.
    /// Moves GPU-wait + memcpy off main thread (~5-10ms saved per frame).
    private let frameForwardQueue = DispatchQueue(
        label: "com.aether3d.frame-forward", qos: .userInitiated)
    /// Guard to prevent frame forwarding queue buildup (at most 1 in-flight).
    nonisolated(unsafe) private var isForwardingFrame: Bool = false

    // MARK: - Frame Throttling
    /// Forward every Nth frame to C++ pipeline. ARKit runs at 60fps.
    /// 30fps (interval=2) is optimal: dense coverage + manageable CPU load.
    /// PocketGS captures 50 frames total in ~4min. We capture 30fps × scan_time →
    /// even 30sec = 900 frames (18× more than PocketGS). Dense coverage is our edge.
    /// C++ thermal management handles CPU throttling (drops to 15fps/10fps at thermal 2/3).
    private static let pipelineFrameInterval: Int = 2  // 60fps / 2 = 30fps to C++ — maximum density for S6+ quality

    // MARK: - Timer
    private var captureStartTime: Date?
    nonisolated(unsafe) private var elapsedTimer: Timer?

    // MARK: - Thermal Monitoring
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════

    init() {
        self.toastPresenter = GuidanceToastPresenter()
        self.hapticEngine = GuidanceHapticEngine()
        self.completionBridge = ScanCompletionBridge(hapticEngine: hapticEngine)

        // Metal pipeline: point cloud + OIR (replaces wedge 6-pass)
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            self.renderPipeline = try? PointCloudOIRPipeline(device: device)
        } else {
            self.renderPipeline = nil
        }
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

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - State Machine Transitions
    // ═══════════════════════════════════════════════════════════════════════

    func transition(to newState: ScanState) {
        if scanState == newState { return }
        guard scanState.allowedTransitions.contains(newState) else {
            #if DEBUG
            print("[Aether3D] Rejected state transition: \(scanState) → \(newState)")
            #endif
            return
        }

        let oldState = scanState
        scanState = newState

        switch (oldState, newState) {
        case (_, .ready):
            // Pre-load C++ coordinator (CoreML models) while user sees camera.
            // By the time user taps capture, models are loaded → instant TSDF.
            initializeCoordinatorIfNeeded()

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

    func executeScanActionPlan(_ plan: ScanActionPlan) {
        guard plan.actionMask.contains(.applyTransition),
              let targetState = plan.transitionTargetState else {
            return
        }
        transition(to: targetState)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - User Actions
    // ═══════════════════════════════════════════════════════════════════════

    func startCapture() {
        initializeCoordinatorIfNeeded()  // no-op if already started in .ready
        transition(to: .capturing)
    }

    func pauseCapture() {
        transition(to: .paused)
    }

    func resumeCapture() {
        transition(to: .capturing)
    }

    /// Signal pipeline to finish scanning (non-blocking, no export).
    /// Called from ScanView.handleStop() for immediate navigation.
    func finishScanningOnly() {
        _ = coordinatorBridge?.finishScanning()
    }

    /// Signal that user has entered the 3D viewer space.
    /// Triggers sequential fly-in animation for completed regions.
    func signalViewerEntered() {
        coordinatorBridge?.signalViewerEntered()
    }

    /// Stop capture and export. Heavy work runs on background thread via Task.detached.
    /// Caller awaits the result; UI stays responsive because MainActor is not blocked.
    func stopCapture() async -> ScanRecord? {
        NSLog("[Aether3D] stopCapture: state=%@ canFinish=%@",
              scanState.rawValue, scanState.canFinish ? "YES" : "NO")
        guard scanState.canFinish else {
            NSLog("[Aether3D] stopCapture: canFinish=false, returning nil")
            return nil
        }

        _ = coordinatorBridge?.finishScanning()
        transition(to: .finishing)

        let bridge = coordinatorBridge
        let coverage = coveragePercent
        let duration = elapsedTime

        // If coordinator never loaded (still initializing), skip export entirely.
        // No frames were processed → nothing to export → no 3D viewer possible.
        guard bridge != nil else {
            NSLog("[Aether3D] stopCapture: coordinator not ready — no data to export (is still initializing: %@)",
                  isInitializingCoordinator ? "YES" : "NO")
            coordinatorNotReady = true
            return ScanRecord(
                id: UUID(), name: nil, createdAt: Date(),
                thumbnailPath: nil, artifactPath: nil,
                coveragePercentage: 0, triangleCount: 0,
                durationSeconds: duration)
        }

        isExporting = true

        // Heavy work on background thread; await resumes on MainActor.
        let record: ScanRecord? = await Task.detached(priority: .userInitiated) {
            NSLog("[Aether3D] stopCapture: bridge=%@, starting waitForTraining",
                  bridge != nil ? "valid" : "nil")

            // Wait for training to converge (up to 4s).
            let stepsReached = bridge?.waitForTraining(
                minSteps: 300, timeoutSeconds: 4.0) ?? 0
            NSLog("[Aether3D] Training reached %d steps before export (isTraining=%@, isGPU=%@)",
                  stepsReached,
                  bridge?.isTraining == true ? "YES" : "NO",
                  bridge?.isGPUTraining == true ? "YES" : "NO")

            // Export PLY
            let recordId = UUID()
            var artifactPath: String?

            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
            let exportDir = documents
                .appendingPathComponent("Aether3D")
                .appendingPathComponent("exports")
            try? FileManager.default.createDirectory(
                at: exportDir, withIntermediateDirectories: true)

            let plyURL = exportDir.appendingPathComponent("\(recordId.uuidString).ply")
            NSLog("[Aether3D] Attempting exportPLY to: %@", plyURL.path)
            if bridge?.exportPLY(path: plyURL.path) == true {
                artifactPath = "exports/\(recordId.uuidString).ply"
                NSLog("[Aether3D] ✅ Exported trained PLY: %@", plyURL.path)
            } else {
                NSLog("[Aether3D] exportPLY failed, trying point cloud fallback")
                if bridge?.exportPointCloudPLY(path: plyURL.path) == true {
                    artifactPath = "exports/\(recordId.uuidString).ply"
                    NSLog("[Aether3D] ✅ Fallback: exported point cloud PLY: %@", plyURL.path)
                } else {
                    NSLog("[Aether3D] ❌ ERROR: Both trained and point cloud exports failed!")
                }
            }

            return ScanRecord(
                id: recordId, name: nil, createdAt: Date(),
                thumbnailPath: nil, artifactPath: artifactPath,
                coveragePercentage: Double(coverage), triangleCount: 0,
                durationSeconds: duration)
        }.value

        isExporting = false
        return record
    }

    /// Expose render pipeline for overlay draw delegation.
    #if canImport(Metal)
    func currentRenderPipelineForOverlay() -> PointCloudOIRPipeline? {
        renderPipeline
    }
    #endif

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - ARKit Frame Processing
    // ═══════════════════════════════════════════════════════════════════════

    /// Called from ARSCNView delegate on EVERY frame (~60 FPS).
    /// Heavy work (CIContext conversion + C++ forwarding) is throttled to ~15fps.
    /// Light work (snapshot reads + Metal overlay update) runs every frame for smooth UI.
    func processARFrame(
        timestamp: TimeInterval,
        cameraTransform: simd_float4x4,
        lightEstimate: LightEstimateSnapshot?,
        meshAnchors: [ARMeshAnchor],
        viewMatrix: simd_float4x4? = nil,
        projectionMatrix: simd_float4x4? = nil,
        pixelBuffer: CVPixelBuffer? = nil,
        cameraIntrinsics: simd_float3x3? = nil,
        lidarDepthBuffer: CVPixelBuffer? = nil,
        featureCloud: ARPointCloud? = nil
    ) {
        guard scanState.isActive else { return }
        frameCounter += 1
        debugFrameCount = frameCounter
        debugBridgeReady = (coordinatorBridge != nil)

        // Update coordinator init elapsed time while waiting
        if isInitializingCoordinator && coordinatorInitStartTime > 0 {
            debugCoordinatorInitTime = CFAbsoluteTimeGetCurrent() - coordinatorInitStartTime
        }

        let stabilizedTransform = stabilizedCameraTransform(
            rawCameraTransform: cameraTransform,
            timestamp: timestamp
        )

        // ─── Throttled: Only forward every Nth frame to C++ (expensive) ───
        let shouldForwardToPipeline = (frameCounter % Self.pipelineFrameInterval == 0)

        if shouldForwardToPipeline {
            // DAv2 depth inference now handled by C++ PipelineCoordinator internally.
            // Swift passes ne_depth=nil; C++ runs async Neural Engine inference itself.

            debugPipelineFrameCount += 1

            // Forward frame to C++ coordinator (includes CIContext conversion)
            forwardFrameToCoordinator(
                cameraTransform: stabilizedTransform,
                timestamp: timestamp,
                pixelBuffer: pixelBuffer,
                cameraIntrinsics: cameraIntrinsics,
                lidarDepthBuffer: lidarDepthBuffer,
                featureCloud: featureCloud
            )
        }

        // ─── Every frame: Read snapshot from C++ (lock-free, <1μs) ───
        #if canImport(CAetherNativeBridge)
        if let snapshot = coordinatorBridge?.getSnapshot() {
            coveragePercent = snapshot.coverage
            trainingProgress = snapshot.training_progress
            trainingActive = snapshot.training_active != 0
            debugSelectedFrames = Int(snapshot.selected_frames)
            debugMinFramesNeeded = Int(snapshot.min_frames_needed)
            debugIsGPUTraining = coordinatorBridge?.isGPUTraining ?? false
            debugHasS6Quality = snapshot.has_s6_quality != 0

            // 区域化训练状态 (破镜重圆)
            debugRegionTotal = Int(snapshot.training_region_total)
            debugRegionCompleted = Int(snapshot.training_region_completed)
            debugActiveRegionId = snapshot.active_region_id == 0xFFFF ? -1 : Int(snapshot.active_region_id)
            debugActiveRegionProgress = snapshot.active_region_progress
            debugIsAnimating = snapshot.is_animating != 0
            debugStagedCount = Int(snapshot.staged_count)
        }

        if let progress = coordinatorBridge?.trainingProgress() {
            if progress.total_steps > 0 {
                trainingProgress = Float(progress.step) / Float(progress.total_steps)
            }
            debugTrainingStep = Int(progress.step)
            debugTotalSteps = Int(progress.total_steps)
            debugLoss = progress.loss
        }
        #endif

        // Quality milestone toasts removed — TSDF overlay heatmap provides visual feedback.

        // ─── Every frame: Motion / exposure feedback ───
        let velocity = extractMotionMagnitude(from: stabilizedTransform, timestamp: timestamp)
        let feedbackTimestamp = ProcessInfo.processInfo.systemUptime
        let tier = thermalAdapter.currentTier

        // 0.7 m/s — inlined from former ScanGuidanceConstants.hapticMotionThreshold
        if tier.enableHaptics && velocity > 0.7 {
            _ = hapticEngine.fire(
                pattern: .motionTooFast,
                timestamp: feedbackTimestamp,
                toastPresenter: toastPresenter
            )
        }

        if let lightEstimate {
            let ambientIntensity = lightEstimate.ambientIntensity
            if tier.enableHaptics && (ambientIntensity < 250.0 || ambientIntensity > 5000.0) {
                _ = hapticEngine.fire(
                    pattern: .exposureAbnormal,
                    timestamp: feedbackTimestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        // ─── Every frame: Update Metal render pipeline (smooth 60fps overlay) ───
        #if canImport(Metal) && canImport(CAetherNativeBridge)
        if let pipeline = renderPipeline,
           let vm = viewMatrix,
           let pm = projectionMatrix {
            let intrinsics = cameraIntrinsics ?? simd_float3x3(1)
            let fx = intrinsics[0][0]
            let fy = intrinsics[1][1]
            let vpW: Float = pixelBuffer.map { Float(CVPixelBufferGetWidth($0)) } ?? 1920
            let vpH: Float = pixelBuffer.map { Float(CVPixelBufferGetHeight($0)) } ?? 1080

            if let renderData = coordinatorBridge?.getRenderData() {
                // ── Full pipeline: C++ → triple buffer → Metal ──
                pipeline.update(
                    pointCloudVertices: renderData.pointCloudVertices,
                    pointCloudCount: renderData.pointCloudCount,
                    splatData: renderData.packedSplats,
                    splatCount: renderData.splatCount,
                    overlayVertices: renderData.overlayVertices,
                    overlayCount: renderData.overlayCount,
                    viewMatrix: vm,
                    projectionMatrix: pm,
                    cameraTransform: stabilizedTransform,
                    globalPointCloudAlpha: renderData.pointCloudAlpha,
                    focal: SIMD2<Float>(fx, fy),
                    viewport: SIMD2<Float>(vpW, vpH)
                )
                // Debug stats from render data
                debugPointCloudCount = Int(renderData.tsdfBlockCount)
                debugOverlayCount = Int(renderData.overlayCount)
                debugSplatCount = Int(renderData.splatCount)
                debugPointCloudAlpha = renderData.pointCloudAlpha
            }
            // Read encode counters from Metal pipeline
            debugEncodeDrawCount = pipeline.debugEncodeDrawCount
            debugEncodeSkipCount = pipeline.debugEncodeSkipCount
            // Note: No fallback rendering while coordinator loads.
            // Camera feed is shown cleanly; C++ pipeline overlay appears once ready.
        }
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - GPU Frame Timing
    // ═══════════════════════════════════════════════════════════════════════

    /// Report GPU frame duration (called from ARCameraPreview's commandBuffer completion handler).
    func reportGPUFrameTiming(durationMs: Double) {
        thermalAdapter.updateFrameTiming(gpuDurationMs: durationMs)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - C++ Pipeline Coordinator
    // ═══════════════════════════════════════════════════════════════════════

    /// Result of background coordinator creation (Sendable for cross-isolation transfer).
    private struct CoordinatorHandles: @unchecked Sendable {
        let gpuDevice: OpaquePointer
        let splatEngine: OpaquePointer
        let bridge: PipelineCoordinatorBridge?
    }

    /// Create coordinator handles on any thread (no MainActor requirement).
    /// CoreML model loading (~10-30s) happens here — MUST be off-main.
    private nonisolated static func createCoordinatorHandles() -> CoordinatorHandles? {
        #if canImport(CAetherNativeBridge) && canImport(Metal)
        let t0 = CFAbsoluteTimeGetCurrent()
        NSLog("[Aether3D] Coordinator: starting creation...")

        // Step 1: Metal device
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            NSLog("[Aether3D] Coordinator FAILED at Step 1/4: MTLCreateSystemDefaultDevice returned nil")
            return nil
        }
        NSLog("[Aether3D] Coordinator Step 1/4: MTLDevice OK (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)

        // Step 2: GPU device wrapper
        let mtlDevicePtr = Unmanaged.passUnretained(mtlDevice).toOpaque()
        guard let gpuDevice = aether_gpu_device_create_metal(mtlDevicePtr) else {
            NSLog("[Aether3D] Coordinator FAILED at Step 2/4: aether_gpu_device_create_metal (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)
            return nil
        }
        NSLog("[Aether3D] Coordinator Step 2/4: GPU device OK (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)

        // Step 3: Splat engine (Metal PSO compilation)
        var splatConfig = aether_splat_config_t()
        _ = aether_splat_default_config(&splatConfig)

        var splatEnginePtr: OpaquePointer?
        let rc = aether_splat_engine_create(
            UnsafeMutableRawPointer(gpuDevice), &splatConfig, &splatEnginePtr)
        guard rc == 0, let engine = splatEnginePtr else {
            NSLog("[Aether3D] Coordinator FAILED at Step 3/4: aether_splat_engine_create rc=%d (%.1fs)", rc, CFAbsoluteTimeGetCurrent() - t0)
            aether_gpu_device_destroy(gpuDevice)
            return nil
        }
        NSLog("[Aether3D] Coordinator Step 3/4: Splat engine OK (%.1fs)", CFAbsoluteTimeGetCurrent() - t0)

        // Step 4: Pipeline coordinator bridge (CoreML model loading — slowest step)
        let bridge = PipelineCoordinatorBridge(
            gpuDevicePtr: UnsafeMutableRawPointer(gpuDevice),
            splatEnginePtr: UnsafeMutableRawPointer(engine)
        )
        NSLog("[Aether3D] Coordinator Step 4/4: Bridge=%@ (%.1fs total)", bridge != nil ? "OK" : "FAILED", CFAbsoluteTimeGetCurrent() - t0)

        return CoordinatorHandles(gpuDevice: gpuDevice, splatEngine: engine, bridge: bridge)
        #else
        return nil
        #endif
    }

    /// Lazily initialize the C++ PipelineCoordinator on first capture start.
    /// Heavy work (CoreML model loading: 10-30s) runs on background thread
    /// to avoid blocking the main thread (button/timer UI).
    /// Frames are dropped until coordinator is ready (camera feed still shows).
    private func initializeCoordinatorIfNeeded() {
        #if canImport(CAetherNativeBridge) && canImport(Metal)
        guard coordinatorBridge == nil, !isInitializingCoordinator else { return }
        isInitializingCoordinator = true
        let initStartTime = CFAbsoluteTimeGetCurrent()
        coordinatorInitStartTime = initStartTime
        NSLog("[Aether3D] initializeCoordinatorIfNeeded: launching background creation...")

        Task.detached(priority: .userInitiated) { [weak self] in
            let handles = Self.createCoordinatorHandles()
            await MainActor.run { [weak self] in
                let elapsed = CFAbsoluteTimeGetCurrent() - initStartTime
                guard let self else {
                    if let h = handles {
                        _ = h.bridge
                        aether_splat_engine_destroy(h.splatEngine)
                        aether_gpu_device_destroy(h.gpuDevice)
                    }
                    NSLog("[Aether3D] Coordinator: ViewModel deallocated during init (%.1fs)", elapsed)
                    return
                }
                self.isInitializingCoordinator = false
                self.debugCoordinatorInitTime = elapsed

                // ── Guard: Discard coordinator if scan was already stopped ──
                // If user tapped Stop while CoreML was loading, the scan has
                // transitioned to .completed/.failed. Installing a coordinator now
                // would leak GPU resources (teardownCoordinatorAsync already ran).
                guard self.scanState != .completed && self.scanState != .failed else {
                    if let h = handles {
                        NSLog("[Aether3D] Coordinator: scan already ended (state=%@), discarding (%.1fs)",
                              "\(self.scanState)", elapsed)
                        // Destroy on background to avoid blocking MainActor
                        let bridge = h.bridge
                        let engine = h.splatEngine
                        let device = h.gpuDevice
                        DispatchQueue.global(qos: .utility).async {
                            _ = bridge  // triggers deinit → thread joins
                            aether_splat_engine_destroy(engine)
                            aether_gpu_device_destroy(device)
                        }
                    }
                    return
                }

                guard let h = handles, let bridge = h.bridge else {
                    if let h = handles {
                        aether_splat_engine_destroy(h.splatEngine)
                        aether_gpu_device_destroy(h.gpuDevice)
                    }
                    NSLog("[Aether3D] Pipeline coordinator creation FAILED (%.1fs elapsed)", elapsed)
                    return
                }
                self.gpuDeviceHandle = h.gpuDevice
                self.splatEngineHandle = h.splatEngine
                self.coordinatorBridge = bridge
                self.debugBridgeReady = true
                NSLog("[Aether3D] Pipeline coordinator READY (%.1fs elapsed)", elapsed)
            }
        }
        #endif
    }

    // MARK: - Pixel Format Conversion

    /// Convert ARKit YCbCr BiPlanar pixel buffer to BGRA for C++ pipeline.
    /// Uses GPU-accelerated CIContext. Reuses a single CVPixelBuffer to avoid allocations.
    /// Returns the original buffer untouched if already in a 4-channel format.
    #if canImport(CoreImage) && canImport(CoreVideo)
    /// Convert YCbCr → BGRA. Called exclusively from frameForwardQueue (serial).
    /// Accesses only nonisolated(unsafe) properties (pixelConvertContext, bgraBuffer).
    nonisolated private func convertToBGRA(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // Already 4-channel — pass through
        if fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32RGBA {
            return pixelBuffer
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // Reuse existing buffer if size matches
        if let existing = bgraBuffer,
           CVPixelBufferGetWidth(existing) == w,
           CVPixelBufferGetHeight(existing) == h {
            // Render into existing buffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            pixelConvertContext.render(ciImage, to: existing)
            return existing
        }

        // Allocate new BGRA buffer
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var newBuf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &newBuf)
        guard status == kCVReturnSuccess, let outBuf = newBuf else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        pixelConvertContext.render(ciImage, to: outBuf)
        bgraBuffer = outBuf
        return outBuf
    }
    #endif

    /// Sendable wrapper for CVPixelBuffer (refcounted, safe to transfer across queues).
    private struct SendablePixelBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// Sendable wrapper for OpaquePointer (C handle, safe to transfer for teardown).
    private struct SendableHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    /// Captures all data needed for background frame forwarding.
    private struct FrameForwardPayload: @unchecked Sendable {
        let bridge: PipelineCoordinatorBridge
        let pixelBuffer: SendablePixelBuffer
        let lidarBuffer: SendablePixelBuffer?
        let cameraTransform: simd_float4x4
        let intrinsics: simd_float3x3
        let flatFeatures: [Float]
        let featureCount: UInt32
        let thermalState: Int
    }

    /// Forward frame data to PipelineCoordinator on background serial queue.
    /// CIContext BGRA conversion + memcpy runs off main thread (~5-10ms freed).
    /// At most 1 frame in-flight on the queue; excess frames are dropped.
    private func forwardFrameToCoordinator(
        cameraTransform: simd_float4x4,
        timestamp: TimeInterval,
        pixelBuffer: CVPixelBuffer?,
        cameraIntrinsics: simd_float3x3?,
        lidarDepthBuffer: CVPixelBuffer? = nil,
        featureCloud: ARPointCloud? = nil
    ) {
        #if canImport(CAetherNativeBridge) && canImport(CoreVideo) && canImport(CoreImage)
        guard let bridge = coordinatorBridge, let pixelBuffer = pixelBuffer else {
            // Log frame drops while coordinator is loading (throttled)
            if coordinatorBridge == nil, pixelBuffer != nil {
                if frameCounter <= 3 || frameCounter % 300 == 0 {
                    NSLog("[Aether3D] forwardFrame: bridge=nil, frame %d dropped", frameCounter)
                }
            }
            return
        }

        // Drop if previous frame still processing (prevent queue buildup)
        guard !isForwardingFrame else { return }
        isForwardingFrame = true

        // Flatten ARKit feature points on main thread (needs ARPointCloud access).
        var features: [Float] = []
        let featureCount: UInt32
        if let pts = featureCloud?.points, !pts.isEmpty {
            let maxPts = min(pts.count, 512)
            features.reserveCapacity(maxPts * 3)
            for i in 0..<maxPts {
                features.append(pts[i].x)
                features.append(pts[i].y)
                features.append(pts[i].z)
            }
            featureCount = UInt32(maxPts)
        } else {
            featureCount = 0
        }

        // Pack everything into Sendable payload for background dispatch.
        let payload = FrameForwardPayload(
            bridge: bridge,
            pixelBuffer: SendablePixelBuffer(buffer: pixelBuffer),
            lidarBuffer: lidarDepthBuffer.map { SendablePixelBuffer(buffer: $0) },
            cameraTransform: cameraTransform,
            intrinsics: cameraIntrinsics ?? simd_float3x3(1),
            flatFeatures: features,
            featureCount: featureCount,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue
        )

        // Dispatch heavy work (CIContext conversion + C++ enqueue) to serial queue.
        frameForwardQueue.async { [weak self] in
            guard let self else { return }
            defer { self.isForwardingFrame = false }

            // Convert YCbCr → BGRA (GPU-accelerated, now off main thread)
            guard let bgraPixelBuffer = self.convertToBGRA(payload.pixelBuffer.buffer) else { return }

            let width = UInt32(CVPixelBufferGetWidth(bgraPixelBuffer))
            let height = UInt32(CVPixelBufferGetHeight(bgraPixelBuffer))

            CVPixelBufferLockBaseAddress(bgraPixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(bgraPixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(bgraPixelBuffer) else { return }
            let rgbaPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

            // LiDAR depth
            var lidarPtr: UnsafePointer<Float>?
            var lidarW: UInt32 = 0
            var lidarH: UInt32 = 0

            if let lidarBuf = payload.lidarBuffer?.buffer {
                CVPixelBufferLockBaseAddress(lidarBuf, .readOnly)
            }
            defer {
                if let lidarBuf = payload.lidarBuffer?.buffer {
                    CVPixelBufferUnlockBaseAddress(lidarBuf, .readOnly)
                }
            }

            if let lidarBuf = payload.lidarBuffer?.buffer,
               let lidarBase = CVPixelBufferGetBaseAddress(lidarBuf) {
                lidarPtr = UnsafePointer<Float>(lidarBase.assumingMemoryBound(to: Float.self))
                lidarW = UInt32(CVPixelBufferGetWidth(lidarBuf))
                lidarH = UInt32(CVPixelBufferGetHeight(lidarBuf))
            }

            // C++ enqueue (lock-free, <0.3ms)
            payload.flatFeatures.withUnsafeBufferPointer { featureBuf in
                let fPtr = featureBuf.isEmpty ? nil : featureBuf.baseAddress

                _ = payload.bridge.onFrame(
                    rgba: rgbaPtr,
                    width: width, height: height,
                    transform: payload.cameraTransform,
                    intrinsics: payload.intrinsics,
                    featurePoints: fPtr, featureCount: payload.featureCount,
                    neDepth: nil, neDepthW: 0, neDepthH: 0,
                    lidarDepth: lidarPtr, lidarW: lidarW, lidarH: lidarH,
                    thermalState: payload.thermalState
                )
            }
        }
        #endif
    }

    /// Request quality enhancement (extra training iterations).
    func requestQualityEnhance(iterations: Int = 200) {
        _ = coordinatorBridge?.requestEnhance(iterations: iterations)
    }

    /// Export trained 3DGS to PLY file.
    func exportTrainedPLY(to path: String) -> Bool {
        return coordinatorBridge?.exportPLY(path: path) ?? false
    }

    /// Start background export (non-blocking — viewer navigates immediately).
    /// Training continues → exports PLY when ready → updates ScanRecord artifact path.
    func startBackgroundExport(recordId: UUID) {
        let bridge = coordinatorBridge
        let coverage = coveragePercent

        Task.detached(priority: .userInitiated) {
            NSLog("[Aether3D] Background export: waiting for training convergence...")

            // Wait for training (up to 60s — user is already in viewer)
            let stepsReached = bridge?.waitForTraining(
                minSteps: 500, timeoutSeconds: 60.0) ?? 0
            NSLog("[Aether3D] Background export: training reached %d steps", stepsReached)

            // Export PLY
            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
            let exportDir = documents
                .appendingPathComponent("Aether3D")
                .appendingPathComponent("exports")
            try? FileManager.default.createDirectory(
                at: exportDir, withIntermediateDirectories: true)

            let plyURL = exportDir.appendingPathComponent("\(recordId.uuidString).ply")
            var exported = false

            if bridge?.exportPLY(path: plyURL.path) == true {
                exported = true
                NSLog("[Aether3D] ✅ Background export: trained PLY → %@", plyURL.path)
            } else if bridge?.exportPointCloudPLY(path: plyURL.path) == true {
                exported = true
                NSLog("[Aether3D] ✅ Background export: point cloud fallback PLY → %@", plyURL.path)
            } else {
                NSLog("[Aether3D] ❌ Background export: both exports failed")
            }

            // Update record with artifact path
            if exported {
                let artifactPath = "exports/\(recordId.uuidString).ply"
                await MainActor.run {
                    var store = ScanRecordStore()
                    store.updateArtifactPath(recordId: recordId, artifactPath: artifactPath)
                    NSLog("[Aether3D] Background export: record updated with artifact=%@", artifactPath)
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pose Stabilization
    // ═══════════════════════════════════════════════════════════════════════

    private func stabilizedCameraTransform(
        rawCameraTransform: simd_float4x4,
        timestamp: TimeInterval
    ) -> simd_float4x4 {
        guard let stabilizer = poseStabilizer else {
            return rawCameraTransform
        }

        let rawPose = simdToColumnMajor(rawCameraTransform)
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

        return columnMajorToSimd(predictedPose)
            ?? columnMajorToSimd(stabilizedPose)
            ?? rawCameraTransform
    }

    private func simdToColumnMajor(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    private func columnMajorToSimd(_ values: [Float]) -> simd_float4x4? {
        guard values.count >= 16 else { return nil }
        return simd_float4x4(columns: (
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        ))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Motion & Feedback
    // ═══════════════════════════════════════════════════════════════════════

    private func extractMotionMagnitude(from transform: simd_float4x4, timestamp: TimeInterval) -> Double {
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        defer {
            lastMotionSample = (position: position, timestamp: timestamp)
        }

        guard let previous = lastMotionSample else { return 0 }
        let dt = max(timestamp - previous.timestamp, 1.0 / 240.0)
        let delta = position - previous.position
        return Double(simd_length(delta) / Float(dt))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Timer
    // ═══════════════════════════════════════════════════════════════════════

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.captureStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Thermal Monitoring
    // ═══════════════════════════════════════════════════════════════════════

    private func setupThermalMonitoring() {
        #if os(iOS)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let state = ProcessInfo.processInfo.thermalState
                self?.thermalAdapter.updateThermalState(state)
                self?.coordinatorBridge?.setThermalState(state.rawValue)
            }
        }
        thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reset
    // ═══════════════════════════════════════════════════════════════════════

    private func resetSubsystems() {
        // ── 1. Shut down Metal render pipeline (drain semaphore, prevent deadlock) ──
        // Must happen BEFORE coordinator teardown so the MTKView draw loop
        // doesn't block on a semaphore that will never be signaled.
        #if canImport(Metal)
        renderPipeline?.shutdown()
        #endif

        // ── 2. Move C++ coordinator + native handles to background for teardown ──
        // PipelineCoordinatorBridge.deinit → aether_pipeline_coordinator_destroy
        //   → stop_threads() → thread.join()
        // The training thread's train_step() can block for 1-5 seconds on GPU work.
        // Joining on the main thread freezes the entire UI.
        teardownCoordinatorAsync()

        // ── 3. Reset local state ──
        trainingActive = false
        trainingProgress = 0.0
        coveragePercent = 0.0
        if let stabilizer = poseStabilizer {
            NativePoseStabilizerBridge.reset(stabilizer)
        }
        lastPoseQuality = 0.0
        frameCounter = 0
        lastMotionSample = nil
        isInitializingCoordinator = false
    }

    /// Detach C++ coordinator + native handle destruction to a background queue.
    /// Destroy order: coordinator → splatEngine → gpuDevice (each references the next).
    private func teardownCoordinatorAsync() {
        let bridge = coordinatorBridge
        coordinatorBridge = nil

        #if canImport(CAetherNativeBridge) && canImport(Metal)
        let engine = splatEngineHandle.map { SendableHandle(pointer: $0) }
        let device = gpuDeviceHandle.map { SendableHandle(pointer: $0) }
        splatEngineHandle = nil
        gpuDeviceHandle = nil

        DispatchQueue.global(qos: .utility).async {
            // bridge deinit → aether_pipeline_coordinator_destroy → stop_threads → join
            // Releasing bridge forces deallocation at this exact point.
            _ = bridge  // triggers deinit + thread joins (safe on background queue)

            // Then destroy engine and device (must outlive coordinator)
            if let e = engine { aether_splat_engine_destroy(e.pointer) }
            if let d = device { aether_gpu_device_destroy(d.pointer) }
        }
        #else
        _ = bridge  // release on current thread (no C++ teardown needed)
        #endif
    }
}

#endif
